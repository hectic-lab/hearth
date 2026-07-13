{ lib, pkgs, ... }: let
  src = ./.;
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "which-country-rs";
    version = "1.0.0";

    inherit src;

    cargoLock.lockFile = ./Cargo.lock;

    # NOTE(yukkop): upstream uses edition 2024, so do not pass the repo's
    # Rust 1.81 commonArgs here.
    # NOTE(yukkop): keep the Nix package offline-by-default; upstream's
    # default geoip feature calls a plaintext HTTP endpoint.
    cargoBuildFlags = ["--no-default-features"];
    cargoTestFlags = ["--no-default-features"];

    meta = {
      description = "CLI tool that tells you which country contains coordinates";
      homepage = "https://github.com/krisfur/which-country-rs";
      license = lib.licenses.mit;
      mainProgram = "which-country-rs";
    };
  }
