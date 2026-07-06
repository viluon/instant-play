# Instant Play

Run games without downloading them first.

A game is packaged as an OCI container image in the **zstd:chunked** format and
served from a registry. The [stargz snapshotter][stargz] mounts the image
lazily over FUSE, so the engine and the assets needed to reach the menu are
fetched first and the bulk (maps, music, …) streams in on demand while you
play.

This repository is an MVP that packages [Xonotic][xonotic] (~1.2 GB) this way,
plus a NixOS module that wires up lazy pulling and GPU/Wayland passthrough so
the containerised game renders with hardware acceleration on the host.

It builds on [`nerdctl-flake`][nerdctl-flake], which provides `nerdctl` with
eStargz/zstd:chunked support and the stargz snapshotter.

## What's here

| Output | Description |
| --- | --- |
| `packages.xonotic-image` | Xonotic as a single-layer OCI image with a baked-in prefetch profile. |
| `packages.recorder` | FUSE passthrough that records a program's startup read ranges. |
| `apps.profile-xonotic` | Regenerates `profiles/xonotic.json` by running the game headlessly. |
| `nixosModules.default` | `services.instant-play`: lazy pulling + the `instant-play` launcher. |
| `checks.integration` | nixosTest: build → convert → push → lazy pull → launch the engine. |

## Usage

Add both flakes to your NixOS configuration and enable the module:

```nix
{
  inputs.instant-play.url = "github:viluon/instant-play";

  # in your NixOS system modules:
  imports = [ instant-play.nixosModules.default ];
  services.instant-play.enable = true;
}
```

Then, from a Wayland session on the host:

```console
$ instant-play ghcr.io/viluon/instant-play:xonotic
```

The launcher pulls the image lazily via the stargz snapshotter and runs it with
the host GPU (`/dev/dri`, any `/dev/nvidia*`) and the host GPU userspace
libraries (`/run/opengl-driver`) exposed to the container, and the current
Wayland socket bound in.

### Module options

| Option | Default | Description |
| --- | --- | --- |
| `services.instant-play.enable` | `false` | Enable lazy game pulling and the launcher. |
| `services.instant-play.nerdctl.package` | from `nerdctl-flake` | The nerdctl used to pull and run images. |
| `services.instant-play.insecureRegistry` | `false` | Allow plain-HTTP / self-signed registries (e.g. a local test registry). |

## How the GPU passthrough works

No drivers are baked into the image. The host exposes its GPU userspace under
`/run/opengl-driver` (populated by `hardware.graphics`); the launcher
bind-mounts that directory read-only and the in-image engine wrapper appends
`/run/opengl-driver/lib` to `LD_LIBRARY_PATH`. Device nodes and the Wayland
socket are passed through the same way. See [this write-up][wayland-docker] for
the general approach.

## How the prefetch profile works

zstd:chunked serves reads on demand at **chunk** granularity, so a large file is
only fetched in the pieces that are actually touched. The problem is latency:
without help, the first frames stall on many small on-demand fetches.

To fix that, the image is profiled before it ships. `apps.profile-xonotic` runs
the game headlessly — under `Xvfb` with Mesa's `llvmpipe` software renderer — with
its `/nix/store` bind-mounted through `packages.recorder`, a FUSE passthrough that
logs every served read as `(path, offset, length)`. Because `mmap` page faults are
serviced as FUSE reads, this captures shared-library loading and memory-mapped
assets that an `strace` read-trace misses. Reads are coalesced into ranges and
filtered to the game's runtime closure, dropping the software-GL stack that only
exists while profiling. For Xonotic the startup working set is ~59 MB out of
~1.2 GB — including only ~6.8 MB of the 317 MB `data.pk3` and ~3.5 MB of the
626 MB `maps.pk3`.

The resulting `profiles/xonotic.json` is committed and baked into the image. On
launch the entrypoint replays those ranges against the FUSE mount, warming exactly
those chunks, then executes the game: the startup working set is prefetched while
bulk assets stream in during play.

Profiling needs `/dev/fuse` and user namespaces, so unlike a pure build it runs in
CI or the test VM rather than a Nix sandbox.

## Building and testing

```console
$ nix build .#xonotic-image        # the OCI image
$ nix flake check                  # runs the integration test (needs KVM)
```

The integration test needs plenty of disk and memory because it loads,
converts and pushes the full image inside a VM.

## Publishing

The `publish` workflow builds the image, converts it to zstd:chunked and pushes
it to `ghcr.io/<owner>/instant-play:xonotic`.

[stargz]: https://github.com/containerd/stargz-snapshotter
[xonotic]: https://xonotic.org/
[nerdctl-flake]: https://github.com/viluon/nerdctl-flake
[wayland-docker]: https://leimao.github.io/blog/Docker-Container-GUI-Display-Using-Wayland/
