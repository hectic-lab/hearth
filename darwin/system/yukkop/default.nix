{
  flake,
  self,
  inputs,
  system ? "aarch64-darwin",
  ...
}: let
  name = builtins.baseNameOf ./.;
in inputs.nix-darwin.lib.darwinSystem {
  inherit system;
  specialArgs = { inherit flake self inputs; };
  modules = [
    inputs.home-manager.darwinModules.home-manager
    {
      networking.hostName = name;
      nixpkgs.hostPlatform = system;
      nixpkgs.overlays = [ self.overlays.default ];
    }
    ./${name}.nix
  ];
}
