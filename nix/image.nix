{ lib
, dockerTools
, xonotic
, bashInteractive
, coreutils
, runtimeShell
, writeShellScriptBin
}:

let
  launcher = writeShellScriptBin "instant-play-xonotic" ''
    export HOME="''${HOME:-/tmp}"
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/run/opengl-driver/lib"
    exec ${xonotic}/bin/xonotic-sdl -userdir "$HOME/.xonotic" "$@"
  '';
in
dockerTools.buildLayeredImage {
  name = "instant-play/xonotic";
  tag = "latest";

  contents = [
    xonotic
    launcher
    bashInteractive
    coreutils
  ];

  config = {
    Entrypoint = [ "/bin/instant-play-xonotic" ];
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
