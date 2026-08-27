{
  flake,
  self,
  inputs,
  system ? "x86_64-linux",
  ...
}: let
  # Use folder name as name of this system
  name = builtins.baseNameOf ./.;

in self.lib.nixpkgs-lib.nixosSystem {
  pkgs = import inputs.nixpkgs {
    inherit system;
    overlays = [ self.overlays.default ];
    config.allowUnfreePredicate = pkg:
      builtins.elem (inputs.nixpkgs.lib.getName pkg) [ "steamcmd" "steam-unwrapped" ];
  };
  modules = [
    { networking.hostName = name; }
    (import ./${name}.nix { inherit flake self inputs; })
  ];
}
