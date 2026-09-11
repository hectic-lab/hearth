{
  cargoToml,
  nativeBuildInputs,
  pkgs,
  postgresql_15,
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

    buildInputs = [postgresql_15];

    doCheck = true;
  }
