{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.services.minecraft-world-imports;
  enabledImports = lib.filterAttrs (_: import: import.enable) cfg;
  dataDir = config.services.minecraft-servers.dataDir;
  minecraftServers = config.services.minecraft-servers.servers;
  targetPairs = lib.mapAttrsToList (_: import:
    "${import.serverName}:${import.worldName}") enabledImports;

  importerUser = name: let
    descriptiveName = "minecraft-map-import-${name}";
  in
    if builtins.stringLength descriptiveName <= 31
    then descriptiveName
    else "mc-import-${builtins.substring 0 12 (builtins.hashString "sha256" name)}";

  stateDirectory = cacheDir:
    if lib.hasPrefix "/var/lib/" cacheDir
    then lib.removePrefix "/var/lib/" cacheDir
    else null;

  stateDirectoryCompatible = cacheDir: let
    relative = stateDirectory cacheDir;
    components = lib.splitString "/" (if relative == null then "" else relative);
  in
    relative != null
    && relative != ""
    && lib.all (component: component != "" && component != "." && component != "..") components;

  escapeSftp = value:
    "\"${lib.replaceStrings ["\\" "\""] ["\\\\" "\\\""] value}\"";

  escapeTmpfiles = value:
    lib.replaceStrings ["%" " " "\t"] ["%%" "\\x20" "\\x09"] value;

  importerServices = lib.mkMerge (lib.mapAttrsToList (name: import: let
    user = importerUser name;
    unitName = "minecraft-world-import-${name}";
    serverUnit = "minecraft-server-${import.serverName}.service";
    cacheStateDirectory = stateDirectory import.cacheDir;
    serverDir = "${dataDir}/${import.serverName}";
    worldDir = "${serverDir}/${import.worldName}";
  in {
    ${unitName} = {
      description = "Import Minecraft world ${name}";
      before = [ serverUnit ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.coreutils pkgs.findutils pkgs.openssh pkgs.unar ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        RemainAfterExit = true;
        TimeoutStartSec = import.timeoutStartSec;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ReadWritePaths = [ import.cacheDir dataDir ];
        UMask = "0077";
      } // lib.optionalAttrs (stateDirectoryCompatible import.cacheDir) {
        StateDirectory = cacheStateDirectory;
      };
      script = ''
        set -eu
        umask 077

        cache_dir=${lib.escapeShellArg import.cacheDir}
        server_dir=${lib.escapeShellArg serverDir}
        world_dir=${lib.escapeShellArg worldDir}
        archive_name=${lib.escapeShellArg import.archiveName}
        world_name=${lib.escapeShellArg import.worldName}
        archive="$cache_dir/$archive_name"
        temporary_archive="$cache_dir/.$archive_name.$$"
        extraction_dir="$cache_dir/.minecraft-world-import-${name}.$$"
        staged_world="$server_dir/.$world_name.import.$$"
        key=${lib.escapeShellArg import.sshKeyFile}

        cleanup() {
          rm -f "$temporary_archive"
          rm -rf "$extraction_dir" "$staged_world"
        }
        trap cleanup EXIT

        mkdir -p "$cache_dir" "$server_dir"
        chmod 0700 "$cache_dir"
        chgrp minecraft "$server_dir"
        chmod 0770 "$server_dir"

        if [ -d "$world_dir" ]; then
          if [ -f "$world_dir/level.dat" ]; then
            exit 0
          fi
          echo "Minecraft world directory exists but has no level.dat" >&2
          exit 1
        fi

        if [ ! -f "$archive" ]; then
          downloaded=false
          attempt=1
          while [ "$attempt" -le ${toString import.downloadRetries} ]; do
            if sftp \
              -o BatchMode=yes \
              -o StrictHostKeyChecking=yes \
              -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts \
              -i "$key" \
              -b - \
              ${lib.escapeShellArg "${import.remoteUser}@${import.remoteHost}"} <<EOF
        get ${escapeSftp import.remotePath} "$temporary_archive"
        EOF
            then
              downloaded=true
              break
            fi
            rm -f "$temporary_archive"
            sleep ${toString import.retryDelaySeconds}
            attempt=$((attempt + 1))
          done
          if [ "$downloaded" != true ]; then
            echo "Unable to download Minecraft world ${name}" >&2
            exit 1
          fi
          mv "$temporary_archive" "$archive"
        fi

        if ! printf '%s  %s\n' \
            ${lib.escapeShellArg import.archiveSha256} \
            "$archive" | sha256sum -c -; then
          rm -f "$archive"
          echo "Cached Minecraft world ${name} checksum mismatch" >&2
          exit 1
        fi

        mkdir -p "$extraction_dir"
        unar -quiet -output-directory "$extraction_dir" "$archive"

        find "$extraction_dir" \
          \( -type l -o -type b -o -type c -o -type p -o -type s \) \
          -delete

        world_level_dat=$(find "$extraction_dir" -type f -name level.dat -print -quit)
        if [ -z "$world_level_dat" ]; then
          echo "Minecraft world archive contains no level.dat" >&2
          exit 1
        fi

        mv "$(dirname "$world_level_dat")" "$staged_world"
        chgrp -R minecraft "$staged_world"
        chmod -R u+rwX,g+rwX,o-rwx "$staged_world"
        mv "$staged_world" "$world_dir"
      '';
    };

    "minecraft-server-${import.serverName}" = {
      requires = [ "${unitName}.service" ];
      after = [ "${unitName}.service" ];
    };
  }) enabledImports);
in {
  options.services.minecraft-world-imports = mkOption {
    default = { };
    type = types.attrsOf (types.submodule ({ name, ... }: {
      options = {
        enable = lib.mkEnableOption "Minecraft world import ${name}";

        serverName = mkOption {
          type = types.str;
          description = "minecraft-servers server receiving imported world";
        };

        remoteHost = mkOption {
          type = types.str;
          description = "SSH host serving world archive";
        };

        remoteUser = mkOption {
          type = types.str;
          description = "SSH user used to download world archive";
        };

        remotePath = mkOption {
          type = types.str;
          description = "Remote path to world archive";
        };

        archiveName = mkOption {
          type = types.str;
          description = "Archive file name inside cache directory";
        };

        cacheDir = mkOption {
          type = types.str;
          default = "/var/lib/minecraft-world-imports/${name}";
          description = "Persistent archive cache directory";
        };

        archiveSha256 = mkOption {
          type = types.strMatching "[0-9a-fA-F]{64}";
          description = "Expected SHA-256 digest of world archive";
        };

        sshKeyFile = mkOption {
          type = types.str;
          description = "Runtime path to private SSH key";
        };

        worldName = mkOption {
          type = types.str;
          default = "world";
          description = "World directory name beneath server directory";
        };

        hostPublicKey = mkOption {
          type = types.str;
          description = "Pinned SSH host public key";
        };

        downloadRetries = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "Maximum SFTP download attempts";
        };

        retryDelaySeconds = mkOption {
          type = types.ints.unsigned;
          default = 10;
          description = "Delay between SFTP download attempts";
        };

        timeoutStartSec = mkOption {
          type = types.str;
          default = "30min";
          description = "Importer service start timeout";
        };
      };
    }));
    description = "Minecraft worlds imported before selected servers start";
  };

  config = lib.mkIf (enabledImports != { }) {
    assertions = lib.flatten (lib.mapAttrsToList (name: import: [
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" name != null;
        message = "services.minecraft-world-imports.${name}: name must contain only letters, digits, underscores, or hyphens";
      }
      {
        assertion = builtins.stringLength name <= 24;
        message = "services.minecraft-world-imports.${name}: name must be at most 24 characters";
      }
      {
        assertion = builtins.match "/.*" import.cacheDir != null;
        message = "services.minecraft-world-imports.${name}.cacheDir must be absolute";
      }
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" import.serverName != null;
        message = "services.minecraft-world-imports.${name}.serverName must contain only letters, digits, underscores, or hyphens";
      }
      {
        assertion = !lib.hasInfix "\n" import.remotePath && !lib.hasInfix "\r" import.remotePath;
        message = "services.minecraft-world-imports.${name}.remotePath must not contain newlines";
      }
      {
        assertion = builtins.hasAttr import.serverName minecraftServers
          && (builtins.getAttr import.serverName minecraftServers).enable;
        message = "services.minecraft-world-imports.${name}.serverName must name an enabled Minecraft server";
      }
      {
        assertion = lib.length (lib.unique targetPairs) == lib.length targetPairs;
        message = "services.minecraft-world-imports: each server/world target must be unique";
      }
      {
        assertion = builtins.match "[^/]+" import.archiveName != null;
        message = "services.minecraft-world-imports.${name}.archiveName must be a file name";
      }
      {
        assertion = builtins.match "[^/]+" import.worldName != null;
        message = "services.minecraft-world-imports.${name}.worldName must be a directory name";
      }
    ]) enabledImports);

    users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (importerUser name) { }) enabledImports;
    users.users = lib.mapAttrs' (name: _: let
      user = importerUser name;
    in lib.nameValuePair user {
      description = "Minecraft world importer ${name}";
      isSystemUser = true;
      group = user;
      extraGroups = [ "minecraft" ];
    }) enabledImports;

    programs.ssh.knownHosts = lib.mapAttrs' (name: import:
      lib.nameValuePair "minecraft-world-import-${name}" {
        hostNames = [ import.remoteHost ];
        publicKey = import.hostPublicKey;
      }) enabledImports;

    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (name: import:
      lib.optional (!stateDirectoryCompatible import.cacheDir)
        "d ${escapeTmpfiles import.cacheDir} 0700 ${importerUser name} ${importerUser name} -") enabledImports);

    systemd.services = importerServices;
  };
}
