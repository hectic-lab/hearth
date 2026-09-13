{
  config,
  pkgs,
  ...
}: let
  dataDir = config.services.minecraft-servers.dataDir;
  createMods = pkgs.linkFarmFromDrvs "create-aeronautics-mods" (
    builtins.attrValues {
      Sable = pkgs.fetchurl {
        url = "https://cdn.modrinth.com/data/T9PomCSv/versions/g8CObHcP/sable-neoforge-1.21.1-1.1.3.jar";
        sha512 = "8180e214681c171c9e3b7fa307f7a92bd7de0b8125d671291425f04a4ba26b408758d8ea80a6386d8e73bb1e6b02caf3f20afb9b91ecedd48c37ed44363ac961";
      };
      Create = pkgs.fetchurl {
        url = "https://cdn.modrinth.com/data/LNytGWDc/versions/UjX6dr61/create-1.21.1-6.0.10.jar";
        sha512 = "11cc8fc049d2f67f6548c7abfada6b82a3adb5c7ca410a742de04bbca76e03862c518721b88d806f6e6d768a4d68531fdb903a85859b25d1484d550cc7bafd4b";
      };
      CreateAeronautics = pkgs.fetchurl {
        url = "https://cdn.modrinth.com/data/oWaK0Q19/versions/1sv6OtSz/create-aeronautics-bundled-1.21.1-1.1.3.jar";
        sha512 = "94831bc4702b3864524258fa0a73a50ab3cd37e9c157b5c6688a6845b866ec5838452804050b55e490549d91dad909fc37f0d619f354c5676e2e2651b9c15ec6";
      };
    }
  );
in {
  sops.secrets."minecraft/storage-box-key" = {
    sopsFile = ../../../sus/neuro.yaml;
    owner = "minecraft-map-import";
    group = "minecraft-map-import";
    mode = "0400";
  };

  users.groups.minecraft-map-import = { };
  users.users.minecraft-map-import = {
    description = "Minecraft map importer";
    isSystemUser = true;
    group = "minecraft-map-import";
    extraGroups = [ "minecraft" ];
  };

  programs.ssh.knownHosts."u664722.your-storagebox.de".publicKey =
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";

  systemd.services.minecraft-world-import-wowMineMap = {
    description = "Import WoW Mine custom Minecraft map";
    before = [ "minecraft-server-wowMineMap.service" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.coreutils pkgs.findutils pkgs.openssh pkgs.unar ];
    serviceConfig = {
      Type = "oneshot";
      User = "minecraft-map-import";
      Group = "minecraft-map-import";
      RemainAfterExit = true;
      StateDirectory = "minecraft-maps";
      TimeoutStartSec = "30min";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "" ];
      ReadWritePaths = [ "/var/lib/minecraft-maps" dataDir ];
      UMask = "0077";
    };
    script = ''
      set -eu
      umask 077

      cache_dir=/var/lib/minecraft-maps
      server_dir=${dataDir}/wowMineMap
      archive="$cache_dir/wow mine map.rar"
      temporary_archive="$cache_dir/.wow-mine-map.rar.$$"
      extraction_dir="$cache_dir/.wow-mine-map.$$"
      key=${config.sops.secrets."minecraft/storage-box-key".path}

      cleanup() {
        rm -f "$temporary_archive"
        rm -rf "$extraction_dir"
      }
      trap cleanup EXIT

      mkdir -p "$cache_dir" "$server_dir"
      chmod 0700 "$cache_dir"
      chgrp minecraft "$server_dir"
      chmod 0770 "$server_dir"

      if [ -d "$server_dir/world" ]; then
        if [ -f "$server_dir/world/level.dat" ]; then
          exit 0
        fi
        echo "Minecraft world directory exists but has no level.dat" >&2
        exit 1
      fi

      if [ ! -f "$archive" ]; then
        downloaded=false
        attempt=1
        while [ "$attempt" -le 3 ]; do
          if sftp \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts \
            -i "$key" \
            -b - \
            u664722@u664722.your-storagebox.de <<EOF
      get "wow mine map.rar" "$temporary_archive"
      EOF
          then
            downloaded=true
            break
          fi
          rm -f "$temporary_archive"
          sleep 10
          attempt=$((attempt + 1))
        done
        if [ "$downloaded" != true ]; then
          echo "Unable to download WoW Mine map from Storage Box" >&2
          exit 1
        fi
        mv "$temporary_archive" "$archive"
      fi

      if ! printf '%s  %s\n' \
          bc80084de10a06b0fc2cb1651c61936b9e2fd2288f3f0fe44c964d83a393aa30 \
          "$archive" | sha256sum -c -; then
        rm -f "$archive"
        echo "Cached WoW Mine map checksum mismatch" >&2
        exit 1
      fi

      mkdir -p "$extraction_dir"
      unar -quiet -output-directory "$extraction_dir" "$archive"

      find "$extraction_dir" \
        \( -type l -o -type b -o -type c -o -type p -o -type s \) \
        -delete

      world_level_dat=$(find "$extraction_dir" -type f -name level.dat -print -quit)
      if [ -z "$world_level_dat" ]; then
        echo "RAR archive contains no Minecraft level.dat" >&2
        exit 1
      fi

      mv "$(dirname "$world_level_dat")" "$server_dir/world"
      chgrp -R minecraft "$server_dir/world"
      chmod -R u+rwX,g+rwX,o-rwx "$server_dir/world"
    '';
  };

  systemd.services.minecraft-server-wowMineMap = {
    requires = [ "minecraft-world-import-wowMineMap.service" ];
    after = [ "minecraft-world-import-wowMineMap.service" ];
  };

  services.minecraft-servers = {
    enable = true;
    eula = true;
    openFirewall = true;

    servers = {
      vanilla = {
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

      createAeronautics = {
        enable = true;
        jvmOpts = "-Xmx8G -Xms2G";
        package = pkgs.minecraftServers.neoforge-1_21_1;

        symlinks = {
          mods = createMods;
        };

        serverProperties = {
          server-port = 25566;
          difficulty = "hard";
          online-mode = true;
          view-distance = 20;
          pause-when-empty-seconds = 0;
        };
      };

      wowMineMap = {
        enable = true;
        jvmOpts = "-Xmx8G -Xms2G";
        package = pkgs.minecraftServers.neoforge-1_21_1;

        symlinks.mods = createMods;

        serverProperties = {
          server-port = 25567;
          difficulty = "hard";
          online-mode = true;
          view-distance = 20;
          level-name = "world";
          pause-when-empty-seconds = 0;
        };
      };
    };
  };
}
