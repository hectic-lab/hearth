{
  cargoToml,
  nativeBuildInputs,
  pkgs,
  ...
}: let
  src = ./.;
  cargo = cargoToml ./Cargo.toml;
in
  pkgs.rustPlatform.buildRustPackage {
    pname = cargo.package.name;
    version = cargo.package.version;

    inherit nativeBuildInputs src;

    cargoLock.lockFile = ./Cargo.lock;

    doCheck = true;
  }
