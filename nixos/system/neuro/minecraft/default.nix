{
  imports = [
    ./vanilla.nix
    ./create-aeronautics.nix
    ./wow-mine-map.nix
    ./world-of-sosal.nix
    ./public-tunnel.nix
    ./world-import.nix
    ./modpack-import.nix
  ];

  services.minecraft-servers = {
    enable = true;
    eula = true;
    openFirewall = true;
  };
}
