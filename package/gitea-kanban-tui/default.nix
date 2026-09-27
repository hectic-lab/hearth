{
  cargoToml,
  lib,
  nativeBuildInputs,
  pkgs,
  ...
}: let
  cargo = cargoToml ./Cargo.toml;
in
  pkgs.rustPlatform.buildRustPackage {
    pname = cargo.package.name;
    version = cargo.package.version;
    src = ./.;

    inherit nativeBuildInputs;
    cargoLock.lockFile = ./Cargo.lock;

    doCheck = true;

    meta = {
      description = cargo.package.description;
      license = lib.licenses.mit;
      mainProgram = "gitea-kanban-tui";
    };
  }
