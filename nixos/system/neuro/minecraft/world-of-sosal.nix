{ config, ... }:

{
  sops.secrets."minecraft/storage-box-pack-key" = {
    sopsFile = ../../../../sus/neuro-minecraft.yaml;
    owner = "mc-pack-worldOfSosal";
    group = "mc-pack-worldOfSosal";
    mode = "0400";
  };

  services.minecraft-modpack-imports.worldOfSosal = {
    enable = true;
    serverName = "wowMineMap";
    remoteHost = "u664722.your-storagebox.de";
    remoteUser = "u664722";
    remotePath = "minecraft/pack/WorldOfSosal-v3.mrpack";
    archiveName = "WorldOfSosal.mrpack";
    cacheDir = "/var/lib/minecraft-modpacks/worldOfSosal";
    archiveSha256 = "f97cf251b14f40590e97e7b39e8a8ec43dacfce6da1b02357d15e0eee10d3ade";
    expectedDependencies = {
      minecraft = "1.21.1";
      neoforge = "21.1.250";
    };
    sshKeyFile = config.sops.secrets."minecraft/storage-box-pack-key".path;
    hostPublicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";
  };

  # Import the map before writing modpack configuration into the same server.
  systemd.services.minecraft-modpack-import-worldOfSosal = {
    after = [ "minecraft-world-import-wowMineMap.service" ];
    requires = [ "minecraft-world-import-wowMineMap.service" ];
  };
}
