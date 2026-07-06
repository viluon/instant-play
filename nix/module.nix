{ self, nerdctl-flake }:
{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.services.instant-play;

  launcher = pkgs.writeShellApplication {
    name = "instant-play";
    runtimeInputs = [ cfg.nerdctl.package pkgs.coreutils ];
    text = ''
      if [ "$#" -lt 1 ]; then
        echo "usage: instant-play <image-ref> [extra nerdctl run args...]" >&2
        exit 2
      fi
      image="$1"; shift

      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      wayland_display="''${WAYLAND_DISPLAY:-wayland-1}"

      gpu_args=()
      if [ -d /dev/dri ]; then
        gpu_args+=(--device /dev/dri)
      fi
      for dev in /dev/nvidia*; do
        [ -e "$dev" ] && gpu_args+=(--device "$dev")
      done

      wayland_args=()
      if [ -S "$runtime_dir/$wayland_display" ]; then
        wayland_args+=(
          --volume "$runtime_dir/$wayland_display:/run/user/host/$wayland_display:ro"
          --env "WAYLAND_DISPLAY=$wayland_display"
        )
      else
        echo "warning: no Wayland socket at $runtime_dir/$wayland_display" >&2
      fi

      exec nerdctl run --rm -i \
        --snapshotter=stargz \
        ${lib.optionalString cfg.insecureRegistry "--insecure-registry"} \
        "''${gpu_args[@]}" \
        "''${wayland_args[@]}" \
        --volume /run/opengl-driver:/run/opengl-driver:ro \
        "$image" "$@"
    '';
  };
in
{
  options.services.instant-play = {
    enable = lib.mkEnableOption ''
      Instant Play: launch games from lazily-pulled zstd:chunked OCI images,
      with host GPU and Wayland passthrough'';

    nerdctl.package = lib.mkOption {
      type = lib.types.package;
      default = nerdctl-flake.packages.${pkgs.stdenv.hostPlatform.system}.nerdctl;
      defaultText = lib.literalExpression "nerdctl-flake.packages.\${system}.nerdctl";
      description = "The nerdctl package used to pull and run game images.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = launcher;
      internal = true;
      description = "The instant-play launcher command.";
    };

    insecureRegistry = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow pulling from plain-HTTP or self-signed registries. Useful for a
        local test registry; leave off for ghcr.io and other TLS registries.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nerdctl.enable = true;
    services.nerdctl.package = cfg.nerdctl.package;

    environment.systemPackages = [ cfg.package ];

    hardware.graphics.enable = lib.mkDefault true;
  };
}
