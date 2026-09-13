{ pkgs, ... }:

{
  services.minecraft-servers.servers.vanilla = {
    enable = true;
    jvmOpts = "-Xmx6G -Xms2G";
    package = pkgs.minecraftServers.vanilla-1_21_11;

    serverProperties = {
      server-port = 25565;
      difficulty = "hard";
      online-mode = true;
      view-distance = 32;
      level-seed = "8306359138650378643";
      pause-when-empty-seconds = 0;
    };
  };
}
