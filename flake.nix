{
  description = "Instant Play - launch games from lazily-pulled zstd:chunked OCI images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    nerdctl-flake.url = "github:viluon/nerdctl-flake";
    nerdctl-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , treefmt-nix
    , nerdctl-flake
    ,
    }:
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          treefmt = treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";
            programs.nixpkgs-fmt.enable = true;
          };
        in
        {
          packages = {
            xonotic-image = pkgs.callPackage ./nix/image.nix { };
            publish = pkgs.callPackage ./nix/publish.nix {
              image = self.packages.${system}.xonotic-image;
              nerdctl = nerdctl-flake.packages.${system}.nerdctl;
            };
            default = self.packages.${system}.xonotic-image;
          };

          apps.publish = {
            type = "app";
            program = "${self.packages.${system}.publish}/bin/instant-play-publish";
          };

          formatter = treefmt.config.build.wrapper;

          devShells.default = pkgs.mkShell {
            packages = [
              nerdctl-flake.packages.${system}.nerdctl
              pkgs.skopeo
              treefmt.config.build.wrapper
            ];
          };

          checks = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            xonotic-image = self.packages.${system}.xonotic-image;
            formatting = treefmt.config.build.check self;
            integration = import ./nix/test.nix { inherit self nerdctl-flake; } { inherit pkgs; };
          };
        }
      )
    // {
      nixosModules.default = import ./nix/module.nix { inherit self nerdctl-flake; };
    };
}
