{ config, pkgs, ... }:

{
  sops.secrets."minecraft/storage-box-pack-key" = {
    sopsFile = ../../../../sus/neuro.yaml;
    owner = "mc-pack-worldOfSosal";
    group = "mc-pack-worldOfSosal";
    mode = "0400";
  };

  services.minecraft-modpack-imports.worldOfSosal = {
    enable = true;
    serverName = "worldOfSosal";
    remoteHost = "u664722.your-storagebox.de";
    remoteUser = "u664722";
    remotePath = "minecraft/pack/WorldOfSosal.mrpack";
    archiveName = "WorldOfSosal.mrpack";
    cacheDir = "/var/lib/minecraft-modpacks/worldOfSosal";
    archiveSha256 = "f8c18acb9208e4592725632ae50dab4f9c308483b34fd43a6507c74fdbf8169f";
    expectedDependencies = {
      minecraft = "1.21.1";
      neoforge = "21.1.250";
    };
    sshKeyFile = config.sops.secrets."minecraft/storage-box-pack-key".path;
    hostPublicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";
  };

  services.minecraft-servers.servers.worldOfSosal = {
    enable = true;
    jvmOpts = "-Xmx8G -Xms2G";
    package = pkgs.minecraftServers.neoforge-1_21_1;

    serverProperties = {
      server-port = 25568;
      difficulty = "hard";
      online-mode = true;
      view-distance = 20;
      pause-when-empty-seconds = 0;
    };
  };
}
