{ rustPlatform
, pkg-config
, fuse3
}:

rustPlatform.buildRustPackage {
  pname = "instant-play-recorder";
  version = "0.1.0";

  src = ../recorder;
  cargoLock.lockFile = ../recorder/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ fuse3 ];
}
