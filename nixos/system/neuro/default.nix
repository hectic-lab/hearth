{
  flake,
  self,
  inputs,
  system,
  ...
}: let
  # Use folder name as name of this system
  name = builtins.baseNameOf ./.;

in self.lib.nixpkgs-lib.nixosSystem {
  pkgs = import inputs.nixpkgs { 
    inherit system;
    overlays = [
      self.overlays.default
      inputs.nix-minecraft.overlay
    ];
    config.allowUnfreePredicate = pkg:
      self.lib.cudaUnfreePredicate pkg || builtins.elem (self.lib.nixpkgs-lib.getName pkg) [
      "minecraft-server"
      "neoforge"

      "nvidia-x11"
    ];
    # jitsi-meet depends on libolm which is marked insecure (CVE-2024-4519x)
    config.permittedInsecurePackages = [
      "jitsi-meet-1.0.8792"
    ];
  };
  modules = [
    { networking.hostName = name; }
    (import ./${name}.nix { inherit flake self inputs; })
    inputs.nix-minecraft.nixosModules.minecraft-servers
  ];
}
