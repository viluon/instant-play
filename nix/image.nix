{ dockerTools
, buildEnv
, runCommand
, xonotic
, bashInteractive
, coreutils
, jq
, writeShellScriptBin
, profile
}:

let
  game = writeShellScriptBin "instant-play-xonotic" ''
    export HOME="''${HOME:-/tmp}"
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/run/opengl-driver/lib"
    exec ${xonotic}/bin/xonotic-sdl -userdir "$HOME/.xonotic" "$@"
  '';

  entrypoint = writeShellScriptBin "instant-play-entrypoint" ''
    ${jq}/bin/jq -r '.[] | "\(.path)\t\(.offset)\t\(.length)"' /etc/instant-play/profile.json \
      | while IFS="$(printf '\t')" read -r path offset length; do
          [ -f "$path" ] || continue
          dd if="$path" of=/dev/null bs=1M iflag=skip_bytes,count_bytes \
            skip="$offset" count="$length" 2>/dev/null || true
        done
    exec ${game}/bin/instant-play-xonotic "$@"
  '';

  profileTree = runCommand "instant-play-profile-tree" { } ''
    mkdir -p $out/etc/instant-play
    cp ${profile} $out/etc/instant-play/profile.json
  '';
in
dockerTools.buildImage {
  name = "instant-play/xonotic";
  tag = "latest";

  copyToRoot = buildEnv {
    name = "instant-play-xonotic-root";
    paths = [
      xonotic
      game
      entrypoint
      bashInteractive
      coreutils
      profileTree
    ];
  };

  config = {
    Entrypoint = [ "/bin/instant-play-entrypoint" ];
    Env = [
      "HOME=/tmp"
      "XDG_RUNTIME_DIR=/run/user/host"
    ];
    WorkingDir = "/tmp";
    Labels = {
      "org.opencontainers.image.title" = "Xonotic (Instant Play)";
      "org.opencontainers.image.source" = "https://github.com/viluon/instant-play";
    };
  };
}
