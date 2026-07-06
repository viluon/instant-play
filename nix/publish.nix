{ lib
, writeShellApplication
, containerd
, runc
, nerdctl
, go
, image
}:

writeShellApplication {
  name = "instant-play-publish";
  runtimeInputs = [ containerd runc nerdctl ];
  text = ''
    ref="''${1:-}"
    if [ -z "$ref" ]; then
      cat >&2 <<'USAGE'
    usage: instant-play-publish <image-ref>

    Authenticates via the ambient Docker config (DOCKER_CONFIG,
    ~/.docker/config.json). Set INSTANT_PLAY_INSECURE=1 for plain-HTTP registries.
    USAGE
      exit 2
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo "instant-play-publish must run as root to start containerd" >&2
      exit 1
    fi

    work="$(mktemp -d)"
    throwaway_containerd_sock="$work/containerd.sock"
    start_throwaway_containerd() {
      cat > "$work/config.toml" <<EOF
    version = 3
    root = "$work/root"
    state = "$work/state"
    [grpc]
      address = "$throwaway_containerd_sock"
    EOF
      containerd --config "$work/config.toml" > "$work/containerd.log" 2>&1 &
      containerd_pid=$!
      for _ in $(seq 1 30); do
        [ -S "$throwaway_containerd_sock" ] && return 0
        sleep 1
      done
      echo "containerd did not come up:" >&2
      cat "$work/containerd.log" >&2
      return 1
    }
    cleanup() {
      kill "''${containerd_pid:-}" 2>/dev/null || true
      rm -rf "$work"
    }
    trap cleanup EXIT

    start_throwaway_containerd

    nerdctl="nerdctl --address $throwaway_containerd_sock"
    insecure=""
    [ "''${INSTANT_PLAY_INSECURE:-}" = "1" ] && insecure="--insecure-registry"

    ctr --address "$throwaway_containerd_sock" --namespace default images import \
      --platform "linux/${go.GOARCH}" "${image}"

    $nerdctl image convert --oci --zstdchunked \
      instant-play/xonotic:latest "$ref"

    # shellcheck disable=SC2086
    $nerdctl push $insecure "$ref"
  '';
}
