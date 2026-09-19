{ config, pkgs, ... }:

{
  sops.secrets."minecraft/storage-box-key" = {
    sopsFile = ../../../../sus/neuro-minecraft.yaml;
    owner = "minecraft-map-import-wowMineMap";
    group = "minecraft-map-import-wowMineMap";
    mode = "0400";
  };

  services.minecraft-world-imports.wowMineMap = {
    enable = true;
    serverName = "wowMineMap";
    remoteHost = "u664722.your-storagebox.de";
    remoteUser = "u664722";
    remotePath = "minecraft/map/wow mine map.rar";
    archiveName = "wow mine map.rar";
    cacheDir = "/var/lib/minecraft-maps";
    archiveSha256 = "bc80084de10a06b0fc2cb1651c61936b9e2fd2288f3f0fe44c964d83a393aa30";
    sshKeyFile = config.sops.secrets."minecraft/storage-box-key".path;
    worldName = "world";
    hostPublicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";
  };

  sops.secrets."minecraft/rcon-password" = {
    sopsFile = ../../../../sus/neuro-minecraft.yaml;
    owner = "minecraft";
    group = "minecraft";
    mode = "0400";
    restartUnits = [ "minecraft-server-wowMineMap.service" ];
  };

  # The module's automatic firewall would also expose RCON.
  networking.firewall.allowedTCPPorts = [ 25567 ];
  services.minecraft-servers.servers.wowMineMap = {
    openFirewall = false;
    extraStartPre = ''
      chmod 600 server.properties
      {
        printf '\nrcon.password='
        cat ${config.sops.secrets."minecraft/rcon-password".path}
        printf '\n'
      } >> server.properties
    '';
    enable = true;
    jvmOpts = "-Xmx8G -Xms2G";
    # WorldOfSosal client and server use the same pinned NeoForge.
    package = pkgs.minecraftServers.neoforge-1_21_1.override (
      builtins.fromJSON (builtins.readFile ./neoforge-21.1.250.json)
    );

    serverProperties = {
      server-port = 25567;
      difficulty = "hard";
      online-mode = false;
      enable-rcon = true;
      "rcon.port" = 25575;
      view-distance = 12;
      simulation-distance = 8;
      motd = "WorldOfSosal — World of Warcraft";
      level-name = "world";
      pause-when-empty-seconds = 0;
    };
  };
}
