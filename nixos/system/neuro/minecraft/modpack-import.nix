{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.services.minecraft-modpack-imports;
  enabledImports = lib.filterAttrs (_: import: import.enable) cfg;
  dataDir = config.services.minecraft-servers.dataDir;
  minecraftServers = config.services.minecraft-servers.servers;
  targetServers = lib.mapAttrsToList (_: import: import.serverName) enabledImports;

  importerUser = name: let
    descriptiveName = "mc-pack-${name}";
  in
    if builtins.stringLength descriptiveName <= 31
    then descriptiveName
    else "mc-pack-${builtins.substring 0 16 (builtins.hashString "sha256" name)}";

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
    unitName = "minecraft-modpack-import-${name}";
    serverUnit = "minecraft-server-${import.serverName}.service";
    cacheStateDirectory = stateDirectory import.cacheDir;
    serverDir = "${dataDir}/${import.serverName}";
  in {
    ${unitName} = {
      description = "Import Minecraft Modrinth pack ${name}";
      before = [ serverUnit ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.findutils
        pkgs.jq
        pkgs.openssh
        pkgs.unar
      ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        RemainAfterExit = true;
        TimeoutStartSec = import.timeout;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = [ "" ];
         ReadWritePaths = [ import.cacheDir serverDir ];
        UMask = "0007";
      } // lib.optionalAttrs (stateDirectoryCompatible import.cacheDir) {
        StateDirectory = cacheStateDirectory;
      };
      script = ''
        set -eu
        umask 007

        cache_dir=${lib.escapeShellArg import.cacheDir}
        server_dir=${lib.escapeShellArg serverDir}
        archive_name=${lib.escapeShellArg import.archiveName}
        archive="$cache_dir/$archive_name"
        temporary_archive="$cache_dir/.$archive_name.$$"
        extraction_dir="$cache_dir/.extract-${name}.$$"
        staging_dir="$cache_dir/.stage-${name}.$$"
        managed_paths="$cache_dir/managed-paths"
        new_managed_paths="$cache_dir/.managed-paths.$$"
        key=${lib.escapeShellArg import.sshKeyFile}

        cleanup() {
          rm -f "$temporary_archive" "$new_managed_paths"
          rm -rf "$extraction_dir" "$staging_dir"
        }
        trap cleanup EXIT

        safe_relative_path() {
          case "$1" in
            ""|/*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..)
              return 1
              ;;
          esac
          return 0
        }

        archive_valid() {
          [ -f "$archive" ] && printf '%s  %s\n' \
            ${lib.escapeShellArg import.archiveSha256} \
            "$archive" | sha256sum -c --status
        }

        archive_entries_valid() {
          lsar -json "$archive" | jq -e '
            (.entries | type == "array")
            and (.entries | all(.[];
                (.XADPath | type == "string")
                and (.XADPath | startswith("/") | not)
                and (.XADPath | contains("\\") | not)
                and (.XADPath | test("[[:cntrl:]]") | not)
                and ([.XADPath | split("/")[] | select(. == "" or . == "." or . == "..")] | length == 0)
                and ((.XADIsSymbolicLink // false) | not)
                and ((.XADIsHardLink // false) | not)
                and ((.XADIsDevice // false) | not)
                and ((.XADIsFIFO // false) | not)
                and ((.XADIsSocket // false) | not)
              )
            )
          ' >/dev/null
        }

        mkdir -p "$cache_dir" "$server_dir"
        chmod 0700 "$cache_dir"

        if ! archive_valid; then
          rm -f "$archive"
          downloaded=false
          attempt=1
          while [ "$attempt" -le ${toString import.retries} ]; do
            rm -f "$temporary_archive"
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
              if printf '%s  %s\n' \
                  ${lib.escapeShellArg import.archiveSha256} \
                  "$temporary_archive" | sha256sum -c --status; then
                mv "$temporary_archive" "$archive"
                downloaded=true
                break
              fi
            fi
            rm -f "$temporary_archive"
            attempt=$((attempt + 1))
          done
          if [ "$downloaded" != true ]; then
            echo "Unable to download verified Minecraft modpack ${name}" >&2
            exit 1
          fi
        fi

        if ! archive_entries_valid; then
          echo "Modpack archive contains unsafe entries" >&2
          exit 1
        fi

        mkdir -p "$extraction_dir" "$staging_dir"
        unar -quiet -output-directory "$extraction_dir" "$archive"

        find "$extraction_dir" \
          \( -type l -o -type b -o -type c -o -type p -o -type s \) \
          -delete

        manifest=$(find "$extraction_dir" -type f -name modrinth.index.json -print)
        if [ -z "$manifest" ] || [ "$(printf '%s\n' "$manifest" | wc -l)" -ne 1 ]; then
          echo "Modpack must contain exactly one modrinth.index.json" >&2
          exit 1
        fi
        pack_root=$(dirname "$manifest")

        if ! jq -e \
          --argjson expectedDependencies ${lib.escapeShellArg (builtins.toJSON import.expectedDependencies)} \
          '
          . as $manifest
          | .formatVersion == 1
          and ($expectedDependencies | to_entries | all(.[];
            $manifest.dependencies[.key] == .value
          ))
          and (.files | type == "array")
          and all(.files[];
            ((.env.server // "required") == "unsupported")
            or (
              (.path | type == "string")
              and (.path | length > 0)
              and (.path | startswith("mods/"))
              and (.path | startswith("/") | not)
              and (.path | contains("\\") | not)
              and (.path | test("[[:cntrl:]]") | not)
              and ([.path | split("/")[] | select(. == "" or . == "." or . == "..")] | length == 0)
              and (.hashes.sha512 | type == "string")
              and (.hashes.sha512 | test("^[0-9a-fA-F]{128}$"))
              and (.downloads | type == "array")
              and (.downloads | length > 0)
              and (.downloads[0] | type == "string")
              and (.downloads[0] | startswith("https://"))
              and (.downloads[0] | test("[[:cntrl:]]") | not)
            )
          )
        ' "$manifest" >/dev/null; then
          echo "Modpack manifest contains unsafe or invalid server files" >&2
          exit 1
        fi

        : > "$new_managed_paths"
        jq -r '
          .files[]
          | select((.env.server // "required") != "unsupported")
          | [.path, .hashes.sha512, .downloads[0]]
          | @tsv
        ' "$manifest" |
        while IFS="$(printf '\t')" read -r relative expected_hash url; do
          safe_relative_path "$relative" || exit 1
          destination="$staging_dir/$relative"
          mkdir -p "$(dirname "$destination")"
          curl --fail --location --silent --show-error \
            --retry ${toString import.retries} \
            --output "$destination" \
            "$url"
          if ! printf '%s  %s\n' "$expected_hash" "$destination" |
              sha512sum -c --status; then
            echo "SHA-512 mismatch for $relative" >&2
            exit 1
          fi
          printf '%s\n' "$relative" >> "$new_managed_paths"
        done

        overrides_dir="$pack_root/overrides"
        if [ -d "$overrides_dir" ]; then
          find "$overrides_dir" \
            \( -type l -o -type b -o -type c -o -type p -o -type s \) \
            -delete
          cp -R "$overrides_dir/." "$staging_dir/"
          find "$overrides_dir" -type f -printf '%P\n' |
          while IFS= read -r relative; do
            safe_relative_path "$relative" || exit 1
            printf '%s\n' "$relative"
          done >> "$new_managed_paths"
        fi

        existing_symlink=$(find "$server_dir" -type l -print -quit)
        if [ -n "$existing_symlink" ]; then
          echo "Minecraft server directory contains symlink: $existing_symlink" >&2
          exit 1
        fi

        while IFS= read -r relative; do
          safe_relative_path "$relative" || exit 1
          source_file="$staging_dir/$relative"
          target_file="$server_dir/$relative"
          install -d -m 0770 -g minecraft "$(dirname "$target_file")"
          install -m 0660 -g minecraft "$source_file" "$target_file"
        done < "$new_managed_paths"

        if [ -f "$managed_paths" ]; then
          while IFS= read -r old_relative; do
            safe_relative_path "$old_relative" || {
              echo "Unsafe path in previous managed-paths file" >&2
              exit 1
            }
            keep=false
            while IFS= read -r relative; do
              if [ "$old_relative" = "$relative" ]; then
                keep=true
                break
              fi
            done < "$new_managed_paths"
            if [ "$keep" != true ]; then
              rm -f "$server_dir/$old_relative"
            fi
          done < "$managed_paths"
        fi

        mv "$new_managed_paths" "$managed_paths"
      '';
    };

    "minecraft-server-${import.serverName}" = {
      requires = [ "${unitName}.service" ];
      after = [ "${unitName}.service" ];
    };
  }) enabledImports);
in {
  options.services.minecraft-modpack-imports = mkOption {
    default = { };
    type = types.attrsOf (types.submodule ({ name, ... }: {
      options = {
        enable = lib.mkEnableOption "Minecraft Modrinth pack import ${name}";

        serverName = mkOption {
          type = types.str;
          description = "minecraft-servers server receiving imported pack";
        };

        remoteHost = mkOption {
          type = types.str;
          description = "SSH host serving Modrinth pack archive";
        };

        remoteUser = mkOption {
          type = types.str;
          description = "SSH user used to download Modrinth pack archive";
        };

        remotePath = mkOption {
          type = types.str;
          description = "Remote path to Modrinth pack archive";
        };

        archiveName = mkOption {
          type = types.str;
          description = "Archive file name inside cache directory";
        };

        cacheDir = mkOption {
          type = types.str;
          default = "/var/lib/minecraft-modpacks/${name}";
          description = "Persistent Modrinth archive and importer state directory";
        };

        archiveSha256 = mkOption {
          type = types.strMatching "[0-9a-fA-F]{64}";
          description = "Expected SHA-256 digest of Modrinth pack archive";
        };

        expectedDependencies = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Required dependency versions in modrinth.index.json";
        };

        sshKeyFile = mkOption {
          type = types.str;
          description = "Runtime path to private SSH key";
        };

        hostPublicKey = mkOption {
          type = types.str;
          description = "Pinned SSH host public key";
        };

        retries = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "Maximum SFTP attempts and curl retry count";
        };

        timeout = mkOption {
          type = types.str;
          default = "30min";
          description = "Importer service start timeout";
        };
      };
    }));
    description = "Modrinth packs imported before selected Minecraft servers start";
  };

  config = lib.mkIf (enabledImports != { }) {
    assertions = lib.flatten (lib.mapAttrsToList (name: import: [
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" name != null;
        message = "services.minecraft-modpack-imports.${name}: name must contain only letters, digits, underscores, or hyphens";
      }
      {
        assertion = builtins.match "/.*" import.cacheDir != null;
        message = "services.minecraft-modpack-imports.${name}.cacheDir must be absolute";
      }
      {
        assertion = builtins.match "/var/lib(/[A-Za-z0-9][A-Za-z0-9._-]*)+" import.cacheDir != null;
        message = "services.minecraft-modpack-imports.${name}.cacheDir must be beneath /var/lib with safe path components";
      }
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" import.serverName != null;
        message = "services.minecraft-modpack-imports.${name}.serverName must contain only letters, digits, underscores, or hyphens";
      }
      {
        assertion = !lib.hasInfix "\n" import.remotePath && !lib.hasInfix "\r" import.remotePath;
        message = "services.minecraft-modpack-imports.${name}.remotePath must not contain newlines";
      }
      {
        assertion = builtins.hasAttr import.serverName minecraftServers
          && (builtins.getAttr import.serverName minecraftServers).enable;
        message = "services.minecraft-modpack-imports.${name}.serverName must name an enabled Minecraft server";
      }
      {
        assertion = builtins.match "[A-Za-z0-9._-]+" import.archiveName != null
          && import.archiveName != "."
          && import.archiveName != ".."
          && import.archiveName != "managed-paths";
        message = "services.minecraft-modpack-imports.${name}.archiveName must be a file name";
      }
      {
        assertion = lib.length (lib.unique targetServers) == lib.length targetServers;
        message = "services.minecraft-modpack-imports: each server target must be unique";
      }
    ]) enabledImports);

    users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (importerUser name) { }) enabledImports;
    users.users = lib.mapAttrs' (name: _: let
      user = importerUser name;
    in lib.nameValuePair user {
      description = "Minecraft modpack importer ${name}";
      isSystemUser = true;
      group = user;
      extraGroups = [ "minecraft" ];
    }) enabledImports;

    programs.ssh.knownHosts = lib.mapAttrs' (name: import:
      lib.nameValuePair "minecraft-modpack-import-${name}" {
        hostNames = [ import.remoteHost ];
        publicKey = import.hostPublicKey;
      }) enabledImports;

    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (name: import:
      lib.optional (!stateDirectoryCompatible import.cacheDir)
        "d ${escapeTmpfiles import.cacheDir} 0700 ${importerUser name} ${importerUser name} -") enabledImports);

    systemd.services = importerServices;
  };
}
