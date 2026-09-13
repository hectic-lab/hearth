{ pkgs, ... }:

{
  services.minecraft-servers.servers.createAeronautics = {
    enable = true;
    jvmOpts = "-Xmx8G -Xms2G";
    package = pkgs.minecraftServers.neoforge-1_21_1;

    symlinks = {
      mods = import ./mods.nix { inherit pkgs; };
    };

    serverProperties = {
      server-port = 25566;
      difficulty = "hard";
      online-mode = true;
      view-distance = 20;
      pause-when-empty-seconds = 0;
    };
  };
}
