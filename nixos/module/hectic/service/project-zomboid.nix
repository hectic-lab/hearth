{ ... }:
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.services."project-zomboid";
  serverProperties = cfg.serverProperties // {
    DefaultPort = cfg.port;
    UDPPort = cfg.udpPort;
    WorkshopItems = lib.concatStringsSep ";" cfg.workshopItems;
    Mods = lib.concatStringsSep ";" cfg.mods;
  };
  configLines = lib.mapAttrsToList (
    name: value:
      "${name}=${if builtins.isBool value then lib.boolToString value else toString value}"
  ) serverProperties;
  sandboxValueType = lib.types.oneOf [
    lib.types.bool
    lib.types.int
    lib.types.float
    lib.types.str
    (lib.types.attrsOf sandboxValueType)
  ];
  luaValue = value:
    if builtins.isBool value then
      lib.boolToString value
    else if builtins.isInt value || builtins.isFloat value then
      toString value
    else if builtins.isAttrs value then
      "{ ${lib.concatStringsSep " " (lib.mapAttrsToList (name: child: "[${luaValue name}] = ${luaValue child},") value)} }"
    else
      "\"${lib.replaceStrings [ "\\" "\"" "\n" "\r" ] [ "\\\\" "\\\"" "\\n" "\\r" ] value}\"";
  sandboxConfigLines = lib.mapAttrsToList (
    name: value: "[${luaValue name}] = ${luaValue value},"
  ) cfg.sandboxProperties;
  zomboidDir = "${cfg.dataDir}/Zomboid";
  adminPasswordFile = "${cfg.dataDir}/admin-password";
  backupCfg = cfg.backup;
  s3CredentialsFile = if backupCfg.s3.credentialsFile == null then "" else backupCfg.s3.credentialsFile;
  s3Bucket = if backupCfg.s3.bucket == null then "" else backupCfg.s3.bucket;
  s3Endpoint = if backupCfg.s3.endpoint == null then "" else backupCfg.s3.endpoint;
  s3Region = if backupCfg.s3.region == null then "" else backupCfg.s3.region;
  saveDir = "${zomboidDir}/Saves/Multiplayer/${cfg.serverName}";
  serverConfigDir = "${zomboidDir}/Server";
  backupScript = pkgs.writeShellScript "project-zomboid-backup" ''
    set -eu

    staging_dir=${lib.escapeShellArg backupCfg.stagingDir}
    archive_dir=${lib.escapeShellArg backupCfg.archiveDir}
    lock_file="$archive_dir/.backup.lock"

    ${pkgs.coreutils}/bin/install -d -m 0700 \
      "$staging_dir/Zomboid/Saves/Multiplayer/${cfg.serverName}" \
      "$staging_dir/Zomboid/Server" \
      "$archive_dir"

    exec 9>"$lock_file"
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      ${pkgs.coreutils}/bin/printf '%s\n' 'Project Zomboid backup already running; skipping.' >&2
      exit 0
    fi

    sync_staging() {
      ${pkgs.rsync}/bin/rsync -a --delete \
        ${lib.escapeShellArg "${saveDir}/"} \
        "$staging_dir/Zomboid/Saves/Multiplayer/${cfg.serverName}/"
      ${pkgs.rsync}/bin/rsync -a --delete --delete-excluded \
        --include=${lib.escapeShellArg "/${cfg.serverName}_SandboxVars.lua"} \
        --include=${lib.escapeShellArg "/${cfg.serverName}_spawnpoints.lua"} \
        --include=${lib.escapeShellArg "/${cfg.serverName}_spawnregions.lua"} \
        --exclude='*' \
        ${lib.escapeShellArg "${serverConfigDir}/"} \
        "$staging_dir/Zomboid/Server/"
    }

    # Second pass narrows, but cannot eliminate, live-save inconsistency.
    sync_staging
    ${pkgs.coreutils}/bin/sleep 5
    sync_staging

    timestamp="$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
    archive_name="project-zomboid-${cfg.serverName}-$timestamp.tar.zst"
    archive_tmp="$archive_dir/.$archive_name.tmp"
    archive="$archive_dir/$archive_name"
    trap '${pkgs.coreutils}/bin/rm -f "$archive_tmp"' EXIT
    ${pkgs.gnutar}/bin/tar \
      --use-compress-program=${lib.escapeShellArg "${pkgs.zstd}/bin/zstd -T0"} \
      -C "$staging_dir" -cf "$archive_tmp" Zomboid
    ${pkgs.coreutils}/bin/chmod 0600 "$archive_tmp"
    ${pkgs.coreutils}/bin/mv "$archive_tmp" "$archive"
    trap - EXIT

    ${pkgs.findutils}/bin/find "$archive_dir" -maxdepth 1 -type f \
      -name ${lib.escapeShellArg "project-zomboid-${cfg.serverName}-*.tar.zst"} \
      -mmin +${toString (backupCfg.retentionDays * 1440)} -delete

    ${lib.optionalString backupCfg.s3.enable ''
      if [ -z "''${AWS_ACCESS_KEY_ID:-}" ] || [ -z "''${AWS_SECRET_ACCESS_KEY:-}" ]; then
        ${pkgs.coreutils}/bin/printf '%s\n' \
          'AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY missing from Project Zomboid S3 credentials file.' >&2
        exit 1
      fi
      s3_bucket=${lib.escapeShellArg s3Bucket}
      s3_prefix=${lib.escapeShellArg backupCfg.s3.prefix}
      s3_key="''${s3_prefix:+$s3_prefix/}$archive_name"
      ${pkgs.awscli2}/bin/aws s3 cp "$archive" \
        "s3://$s3_bucket/$s3_key" \
        --endpoint-url ${lib.escapeShellArg s3Endpoint} \
        --region ${lib.escapeShellArg s3Region} \
        --cli-connect-timeout 30 \
        --cli-read-timeout 300 \
        --only-show-errors

      remote_prefix="$s3_prefix"
      if [ -n "$remote_prefix" ]; then
        remote_prefix="$remote_prefix/"
      fi
      archive_prefix=${lib.escapeShellArg "project-zomboid-${cfg.serverName}-"}
      remote_list="$staging_dir/.remote-objects.json"
      remote_delete_dir="$staging_dir/.remote-delete"
      ${pkgs.awscli2}/bin/aws s3api list-objects-v2 \
        --bucket "$s3_bucket" \
        --prefix "$remote_prefix" \
        --endpoint-url ${lib.escapeShellArg s3Endpoint} \
        --region ${lib.escapeShellArg s3Region} \
        --output json > "$remote_list"
      ${pkgs.python3}/bin/python3 - "$remote_list" "$remote_delete_dir" \
        "$(( $(${pkgs.coreutils}/bin/date +%s) - ${toString (backupCfg.s3.remoteRetentionDays * 86400)} ))" \
        "$remote_prefix$archive_prefix" <<'PY'
import datetime
import json
import os
import re
import sys

objects_path, delete_dir, cutoff, key_prefix = sys.argv[1:]
cutoff = int(cutoff)
archive_pattern = re.compile(
    re.escape(key_prefix) + r"\d{8}T\d{6}Z\.tar\.zst\Z"
)
with open(objects_path, encoding="utf-8") as stream:
    objects = json.load(stream).get("Contents", [])

old_keys = []
for item in objects:
    key = item.get("Key", "")
    if not archive_pattern.fullmatch(key):
        continue
    modified = datetime.datetime.fromisoformat(
        item["LastModified"].replace("Z", "+00:00")
    )
    if int(modified.timestamp()) < cutoff:
        old_keys.append(key)

os.makedirs(delete_dir, exist_ok=True)
for batch_number in range(0, len(old_keys), 1000):
    batch = old_keys[batch_number:batch_number + 1000]
    manifest_path = os.path.join(
        delete_dir, f"batch-{batch_number // 1000:04d}.json"
    )
    with open(manifest_path, "w", encoding="utf-8") as stream:
        json.dump(
            {"Objects": [{"Key": key} for key in batch], "Quiet": True},
            stream,
        )
PY
      for remote_manifest in "$remote_delete_dir"/*.json; do
        [ -f "$remote_manifest" ] || continue
        ${pkgs.awscli2}/bin/aws s3api delete-objects \
          --bucket "$s3_bucket" \
          --delete "file://$remote_manifest" \
          --endpoint-url ${lib.escapeShellArg s3Endpoint} \
          --region ${lib.escapeShellArg s3Region} \
          --only-show-errors
      done
      ${pkgs.coreutils}/bin/rm -rf "$remote_list" "$remote_delete_dir"
    ''}
  '';
  startScript = pkgs.writeShellScript "project-zomboid-start" ''
    admin_password=$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg adminPasswordFile})
    exec ${pkgs.steam-run}/bin/steam-run \
      ${lib.escapeShellArg "${cfg.installDir}/start-server.sh"} \
      -servername ${lib.escapeShellArg cfg.serverName} \
      -adminpassword "$admin_password"
  '';
in {
  options.hectic.services."project-zomboid" = {
    enable = lib.mkEnableOption "Project Zomboid dedicated server";

    serverName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9._-]+";
      default = "servertest";
      description = "Name used for Project Zomboid server and save files.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/project-zomboid";
      description = "Writable state directory for the server.";
    };

    installDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/project-zomboid/server";
      description = "Directory where SteamCMD installs the dedicated server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 16261;
      description = "Project Zomboid UDP discovery port.";
    };

    udpPort = lib.mkOption {
      type = lib.types.port;
      default = 16262;
      description = "Project Zomboid UDP game port.";
    };

    branch = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Steam beta branch, for example legacy41.";
    };

    memory = lib.mkOption {
      type = lib.types.strMatching "[0-9]+[mMgG]";
      default = "3g";
      description = "Maximum Java heap for the server, for example 3g.";
    };

    workshopItems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Steam Workshop item IDs, downloaded and enabled by the server.";
    };

    mods = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Project Zomboid mod loading IDs from mod.info.";
    };

    serverProperties = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.str
        ]
      );
      default = { };
      description = "Additional or overriding values for the server INI file.";
    };

    serverPropertiesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Runtime file with additional INI values, suitable for secrets.";
    };

    sandboxProperties = lib.mkOption {
      type = lib.types.attrsOf sandboxValueType;
      default = { };
      description = "Values for the Project Zomboid SandboxVars.lua file.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the Project Zomboid UDP ports in the firewall.";
    };

    backup = {
      enable = lib.mkEnableOption "no-stop Project Zomboid backups";

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "systemd calendar expression controlling backup frequency.";
      };

      stagingDir = lib.mkOption {
        type = lib.types.path;
        default = "${cfg.dataDir}/backups/staging";
        description = "Local directory containing the two-pass rsync staging tree.";
      };

      archiveDir = lib.mkOption {
        type = lib.types.path;
        default = "${cfg.dataDir}/backups/archive";
        description = "Local directory containing timestamped tar.zst archives.";
      };

      retentionDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
        description = "Delete local archives older than this many days.";
      };

      s3 = {
        enable = lib.mkEnableOption "uploading Project Zomboid backups to S3-compatible storage";

        credentialsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Runtime env file containing AWS_ACCESS_KEY_ID and
            AWS_SECRET_ACCESS_KEY. Required when S3 upload is enabled.
          '';
        };

        bucket = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "S3 bucket receiving backup archives.";
        };

        endpoint = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "S3-compatible endpoint URL.";
        };

        region = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "S3 region passed to awscli2.";
        };

        prefix = lib.mkOption {
          type = lib.types.str;
          default = "project-zomboid";
          description = "Optional object key prefix within the S3 bucket.";
        };

        remoteRetentionDays = lib.mkOption {
          type = lib.types.ints.positive;
          default = 14;
          description = "Delete uploaded archives older than this many days.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !backupCfg.s3.enable || backupCfg.enable;
        message = "hectic.services.project-zomboid.backup must be enabled before S3 upload.";
      }
      {
        assertion = !backupCfg.s3.enable || backupCfg.s3.credentialsFile != null;
        message = "hectic.services.project-zomboid.backup.s3.credentialsFile is required when S3 upload is enabled.";
      }
      {
        assertion = !backupCfg.s3.enable || backupCfg.s3.bucket != null;
        message = "hectic.services.project-zomboid.backup.s3.bucket is required when S3 upload is enabled.";
      }
      {
        assertion = !backupCfg.s3.enable || backupCfg.s3.endpoint != null;
        message = "hectic.services.project-zomboid.backup.s3.endpoint is required when S3 upload is enabled.";
      }
      {
        assertion = !backupCfg.s3.enable || backupCfg.s3.region != null;
        message = "hectic.services.project-zomboid.backup.s3.region is required when S3 upload is enabled.";
      }
      {
        assertion =
          !backupCfg.s3.enable
          || backupCfg.s3.credentialsFile == null
          || (
            lib.hasPrefix "/" backupCfg.s3.credentialsFile
            && !lib.hasPrefix "/nix/store/" backupCfg.s3.credentialsFile
          );
        message = "hectic.services.project-zomboid.backup.s3.credentialsFile must be a runtime path outside /nix/store.";
      }
      {
        assertion =
          !backupCfg.s3.enable
          || backupCfg.s3.endpoint == null
          || lib.hasPrefix "https://" backupCfg.s3.endpoint;
        message = "hectic.services.project-zomboid.backup.s3.endpoint must use HTTPS.";
      }
    ];

    users.groups.project-zomboid = { };
    users.users.project-zomboid = {
      isSystemUser = true;
      group = "project-zomboid";
      home = cfg.dataDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 project-zomboid project-zomboid - -"
      "d ${cfg.installDir} 0750 project-zomboid project-zomboid - -"
    ] ++ lib.optionals backupCfg.enable [
      "d ${cfg.dataDir}/backups 0700 project-zomboid project-zomboid - -"
      "Z ${cfg.dataDir}/backups 0700 project-zomboid project-zomboid - -"
      "d ${backupCfg.stagingDir} 0700 project-zomboid project-zomboid - -"
      "d ${backupCfg.archiveDir} 0700 project-zomboid project-zomboid - -"
    ];

    systemd.services.project-zomboid = {
      description = "Project Zomboid dedicated server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        ${pkgs.coreutils}/bin/install -d -m 0750 \
          ${lib.escapeShellArg cfg.installDir}
        if [ ! -s ${lib.escapeShellArg adminPasswordFile} ]; then
          umask 077
          ${pkgs.openssl}/bin/openssl rand -base64 32 > ${lib.escapeShellArg adminPasswordFile}
        fi
        ${pkgs.steamcmd}/bin/steamcmd \
          +force_install_dir ${lib.escapeShellArg cfg.installDir} \
          +login anonymous \
          +app_update 380870 ${lib.optionalString (cfg.branch != null) "-beta ${lib.escapeShellArg cfg.branch}"} validate \
          +quit
        ${pkgs.gnused}/bin/sed -i -E \
          's/"-Xmx[0-9]+[mMgG]"/"-Xmx${cfg.memory}"/' \
          ${lib.escapeShellArg "${cfg.installDir}/ProjectZomboid64.json"}
        ${pkgs.coreutils}/bin/install -d -m 0750 \
          ${lib.escapeShellArg "${zomboidDir}/Server"}
        {
          ${lib.concatMapStringsSep "\n  " (line:
            "${pkgs.coreutils}/bin/printf '%s\\n' ${lib.escapeShellArg line};"
          ) configLines}
          ${lib.optionalString (cfg.serverPropertiesFile != null)
            "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg cfg.serverPropertiesFile};"}
        } > ${lib.escapeShellArg "${zomboidDir}/Server/${cfg.serverName}.ini"}
        ${lib.optionalString (cfg.sandboxProperties != { }) ''
          {
            ${pkgs.coreutils}/bin/printf '%s\n' 'SandboxVars = {';
            ${lib.concatMapStringsSep "\n  " (line:
              "${pkgs.coreutils}/bin/printf '%s\\n' ${lib.escapeShellArg line};"
            ) sandboxConfigLines}
            ${pkgs.coreutils}/bin/printf '%s\n' '};';
          } > ${lib.escapeShellArg "${zomboidDir}/Server/${cfg.serverName}_SandboxVars.lua"}
        ''}
        ${lib.optionalString (cfg.sandboxProperties == { }) ''
          ${pkgs.coreutils}/bin/rm -f \
            ${lib.escapeShellArg "${zomboidDir}/Server/${cfg.serverName}_SandboxVars.lua"}
        ''}
      '';

      serviceConfig = {
        User = "project-zomboid";
        Group = "project-zomboid";
        WorkingDirectory = cfg.dataDir;
        Environment = [
          "HOME=${cfg.dataDir}"
          "SteamAppId=108600"
        ];
        ExecStart = startScript;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = "15min";
        TimeoutStopSec = 30;
        UMask = "0077";
      };
    };

    systemd.services.project-zomboid-backup = lib.mkIf backupCfg.enable {
      description = "No-stop Project Zomboid backup";
      after = [ "project-zomboid.service" ];
      unitConfig.ConditionPathExists = [
        saveDir
        serverConfigDir
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "project-zomboid";
        Group = "project-zomboid";
        ExecStart = backupScript;
        TimeoutStartSec = "30min";
        UMask = "0077";
      } // lib.optionalAttrs backupCfg.s3.enable {
        EnvironmentFile = s3CredentialsFile;
      };
    };

    systemd.timers.project-zomboid-backup = lib.mkIf backupCfg.enable {
      description = "Run Project Zomboid backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = backupCfg.onCalendar;
        Persistent = true;
      };
    };

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.udpPort
    ];
  };
}
