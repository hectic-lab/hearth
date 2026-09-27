{
  self,
  pkgs,
  system
}: let
  rustToolchain =
    if builtins.pathExists ./rust-toolchain.toml
    then pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml
    else pkgs.pkgsBuildHost.rust-bin.stable."1.81.0".default;
in
  self.devShells.${system}.default
  // (pkgs.mkShell {
    nativeBuildInputs = [
      rustToolchain
      pkgs.pkg-config
      pkgs.gcc
      pkgs.gnumake
    ];
  })
