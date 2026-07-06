{ self, nerdctl-flake }:
{ pkgs, ... }:

let
  publish = self.packages.${pkgs.stdenv.hostPlatform.system}.publish;

  registryConfig = pkgs.writeText "registry-config.yml" (builtins.toJSON {
    version = "0.1";
    storage.filesystem.rootdirectory = "/var/lib/registry";
    storage.delete.enabled = true;
    http.addr = ":5000";
  });
in
pkgs.testers.nixosTest {
  name = "instant-play-xonotic";

  nodes.machine =
    { ... }:
    {
      imports = [
        nerdctl-flake.nixosModules.default
        self.nixosModules.default
      ];

      services.instant-play.enable = true;
      services.instant-play.insecureRegistry = true;

      systemd.services.registry = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.distribution}/bin/registry serve ${registryConfig}";
          StateDirectory = "registry";
          Restart = "always";
        };
      };

      # convert holds whole layers in RAM and on disk; zstd:chunked is CPU-bound.
      virtualisation.memorySize = 8192;
      virtualisation.cores = 8;
      virtualisation.diskSize = 40960;
    };

  testScript = ''
    ref = "localhost:5000/xonotic:zstdchunked"

    machine.start()
    machine.wait_for_unit("containerd.service")
    machine.wait_for_unit("containerd-stargz-grpc.service")
    machine.wait_for_unit("registry.service")
    machine.wait_for_open_port(5000)
    machine.wait_until_succeeds("nerdctl info 2>&1 | grep -i stargz")

    machine.succeed(
        "INSTANT_PLAY_INSECURE=1 ${publish}/bin/instant-play-publish " + ref
    )
    # drop it locally so the pull below must be lazy
    machine.succeed("nerdctl rmi -f " + ref)

    machine.succeed(
        "nerdctl pull --snapshotter=stargz --insecure-registry " + ref
    )

    # A detached container keeps the lazy FUSE mount observable.
    machine.succeed(
        "nerdctl run -d --name game --snapshotter=stargz "
        + "--insecure-registry --entrypoint sleep " + ref + " 120"
    )
    machine.wait_until_succeeds(
        "mount | grep -E 'stargz|fuse.rawBridge'", timeout=60
    )

    # a few bytes of the 600MB maps.pk3 must come from the lazy mount, not a full pull
    machine.succeed(
        "nerdctl exec game sh -c "
        + "'head -c 4 \"$(ls /nix/store/*xonotic-0.8.6/data/*maps.pk3)\" | wc -c'"
    )

    out = machine.succeed(
        "nerdctl exec game sh -c "
        + "'/bin/xonotic-dedicated -noconfig +host_framerate 1 +sys_ticrate 0 "
        + "+quit 2>&1 | head -80 || true'"
    )
    assert "DarkPlaces" in out or "Xonotic" in out, (
        "engine banner not found in output: " + out
    )

    import json
    profile = json.loads(
        machine.succeed("nerdctl exec game cat /etc/instant-play/profile.json")
    )
    assert len(profile) > 50, "profile has too few ranges: %d" % len(profile)
    assert any("data.pk3" in r["path"] for r in profile), "profile missing menu assets"
    # block-level: only the touched slivers of maps.pk3, never the whole 626MB
    maps_bytes = sum(r["length"] for r in profile if r["path"].endswith("maps.pk3"))
    assert maps_bytes < 50_000_000, "profile over-prefetches maps.pk3: %d" % maps_bytes

    machine.succeed("nerdctl exec game test -x /bin/instant-play-entrypoint")

    machine.succeed("nerdctl rm -f game")
  '';
}
