{ lib
, writeShellApplication
, closureInfo
, recorder
, bubblewrap
, xorg
, mesa
, libglvnd
, coreutils
, util-linux
, app
, pname ? (app.pname or app.name)
, command
, runSeconds ? 20
, screenGeometry ? "640x480x24"
}:

let
  closure = closureInfo { rootPaths = [ app ]; };
in
writeShellApplication {
  name = "instant-play-profile-${pname}";
  runtimeInputs = [ recorder bubblewrap xorg.xorgserver mesa libglvnd coreutils util-linux ];
  passthru = { inherit app command runSeconds screenGeometry; };
  text = ''
    export PATH="/run/wrappers/bin:$PATH"

    work="$(mktemp -d)"
    trap 'fusermount3 -u "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT
    mkdir -p "$work/mnt" "$work/home"

    recorder mount /nix/store "$work/mnt" "$work/reads" &
    for _ in $(seq 1 40); do
      mountpoint -q "$work/mnt" && break
      sleep 0.25
    done
    mountpoint -q "$work/mnt" || { echo "recorder mount failed" >&2; exit 1; }

    mkdir -p /tmp/.X11-unix
    Xvfb :99 -screen 0 ${screenGeometry} -nolisten tcp > "$work/xvfb.log" 2>&1 &
    xvfb=$!
    for _ in $(seq 1 40); do
      [ -S /tmp/.X11-unix/X99 ] && break
      sleep 0.25
    done
    [ -S /tmp/.X11-unix/X99 ] || { echo "Xvfb did not start" >&2; cat "$work/xvfb.log" >&2; exit 1; }

    bwrap \
      --dev-bind / / \
      --bind "$work/mnt" /nix/store \
      --setenv HOME "$work/home" \
      --setenv DISPLAY :99 \
      --setenv LIBGL_ALWAYS_SOFTWARE 1 \
      --setenv GALLIUM_DRIVER llvmpipe \
      --setenv LIBGL_DRIVERS_PATH ${mesa}/lib/dri \
      --setenv LD_LIBRARY_PATH ${libglvnd}/lib:${mesa}/lib \
      -- ${lib.escapeShellArgs command} > "$work/run.log" 2>&1 &
    game=$!
    sleep ${toString runSeconds}
    kill -TERM $game 2>/dev/null || true
    sleep 2
    kill -KILL $game 2>/dev/null || true
    wait $game 2>/dev/null || true
    kill $xvfb 2>/dev/null || true

    if ! grep -qE 'GL_RENDERER' "$work/run.log"; then
      echo "profiling run never initialised a renderer:" >&2
      tail -40 "$work/run.log" >&2
      exit 1
    fi

    fusermount3 -u "$work/mnt"
    recorder coalesce "$work/reads" ${closure}/store-paths
  '';
}
