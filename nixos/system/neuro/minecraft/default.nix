{
  imports = [
    ./vanilla.nix
    ./create-aeronautics.nix
    ./wow-mine-map.nix
    ./world-import.nix
  ];

  services.minecraft-servers = {
    enable = true;
    eula = true;
    openFirewall = true;
  };
}
