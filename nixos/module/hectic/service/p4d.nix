{ ... }:
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.services.p4d;

  boolString = value: if value then "1" else "0";

  serviceUser = cfg.user;
  serviceGroup = cfg.group;
  packageExe = if cfg.package != null then "${cfg.package}/bin/p4d" else "/run/current-system/sw/bin/false";
  clientExe = if cfg.clientPackage != null then "${cfg.clientPackage}/bin/p4" else "/run/current-system/sw/bin/false";

  journalFile = "${cfg.journalDir}/journal";
  logFile = "${cfg.dataDir}/logs/p4d.log";
  sslPort = if cfg.ssl.enable then "ssl:${cfg.listenAddress}:${toString cfg.port}" else "${cfg.listenAddress}:${toString cfg.port}";
  bootstrapPort = "${cfg.bootstrap.listenAddress}:${toString cfg.bootstrap.port}";

  typemapLines = [
    "binary+l //....uasset"
    "binary+l //....umap"
    "binary+l //....upk"
    "binary+l //....udk"
    "binary+l //....ubulk"
    "binary+l //....uexp"
    "binary+l //....utoc"
    "binary+l //....ucas"
    "binary+w //....exe"
    "binary+w //....dll"
    "binary+w //....lib"
    "binary+w //....app"
    "binary+w //....dylib"
    "binary+w //....stub"
    "binary+w //....ipa"
    "binary+w //....pdb"
  ] ++ cfg.typemap.extraLines;

  typemapSpec = pkgs.writeText "p4d-unreal-typemap.txt" (
    lib.concatStringsSep "\n" ([ "Typemap:" ] ++ map (line: "\t${line}") typemapLines) + "\n"
  );

  mainArgs = [
    "-r" cfg.dataDir
    "-p" sslPort
    "-J" journalFile
    "-L" logFile
  ] ++ lib.optional (!cfg.caseSensitive) "-C1";

  bootstrapArgs = [
    "-r" cfg.dataDir
    "-p" bootstrapPort
    "-J" journalFile
    "-L" "${cfg.dataDir}/logs/bootstrap.log"
  ] ++ lib.optional (!cfg.caseSensitive) "-C1";

  initScript = pkgs.writeShellScript "p4d-init" ''
    set -eu

    export P4ROOT=${lib.escapeShellArg cfg.dataDir}
    export P4JOURNAL=${lib.escapeShellArg journalFile}
    export P4SSLDIR=${lib.escapeShellArg cfg.ssl.dir}

    marker_file="$P4ROOT/.hectic-p4d-initialized"
    typemap_target="$P4ROOT/unreal-engine.typemap"
    server_id_file="$P4ROOT/server.id"

    ${pkgs.coreutils}/bin/install -d -m 0750 "$P4ROOT"
    ${pkgs.coreutils}/bin/install -d -m 0750 ${lib.escapeShellArg cfg.journalDir}
    ${pkgs.coreutils}/bin/install -d -m 0750 ${lib.escapeShellArg cfg.checkpointDir}
    ${pkgs.coreutils}/bin/install -d -m 0750 "$P4ROOT/logs"
    ${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg cfg.ssl.dir}

    if [ ! -f "$server_id_file" ]; then
      umask 077
      ${pkgs.coreutils}/bin/printf '%s\n' ${lib.escapeShellArg cfg.serverId} > "$server_id_file"
    fi

    if [ "${boolString cfg.typemap.enable}" = "1" ]; then
      ${pkgs.coreutils}/bin/install -m 0640 ${lib.escapeShellArg typemapSpec} "$typemap_target"
    fi

    if [ "${boolString cfg.ssl.enable}" = "1" ] && {
      [ ! -f "$P4SSLDIR/privatekey.txt" ] || [ ! -f "$P4SSLDIR/certificate.txt" ];
    }; then
      ${packageExe} -r "$P4ROOT" -Gc
    fi

    if [ ! -f "$marker_file" ] && [ "${boolString cfg.unicode}" = "1" ] && [ ! -e "$P4ROOT/db.counters" ]; then
      ${packageExe} ${lib.escapeShellArgs ([ "-r" cfg.dataDir ] ++ lib.optional (!cfg.caseSensitive) "-C1" ++ [ "-xi" ])}
    fi

    if [ ! -f "$marker_file" ] && [ "${boolString cfg.bootstrap.enable}" = "1" ]; then
      temp_pid_file="$P4ROOT/bootstrap.pid"

      cleanup() {
        if [ -f "$temp_pid_file" ]; then
          pid=$(cat "$temp_pid_file")
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          rm -f "$temp_pid_file"
        fi
      }

      trap cleanup EXIT INT TERM

      ${packageExe} ${lib.escapeShellArgs bootstrapArgs} &
      pid=$!
      ${pkgs.coreutils}/bin/printf '%s\n' "$pid" > "$temp_pid_file"

      ready=0
      tries=0
      while [ "$tries" -lt 30 ]; do
        if ${clientExe} -p ${lib.escapeShellArg bootstrapPort} info >/dev/null 2>&1; then
          ready=1
          break
        fi
        tries=$((tries + 1))
        sleep 1
      done

      if [ "$ready" -ne 1 ]; then
        printf 'p4d bootstrap server failed to become ready on %s\n' ${lib.escapeShellArg bootstrapPort} >&2
        exit 1
      fi

      ${lib.optionalString (cfg.securityLevel != null) ''
        ${clientExe} -p ${lib.escapeShellArg bootstrapPort} configure set security=${toString cfg.securityLevel}
      ''}

      if [ "${boolString cfg.typemap.enable}" = "1" ]; then
        ${clientExe} -p ${lib.escapeShellArg bootstrapPort} typemap -i < "$typemap_target"
      fi

      ${clientExe} -p ${lib.escapeShellArg bootstrapPort} admin stop || true
      wait "$pid" 2>/dev/null || true
      rm -f "$temp_pid_file"
      trap - EXIT INT TERM
    fi

    if [ ! -f "$marker_file" ]; then
      : > "$marker_file"
    fi
  '';
in {
  options.hectic.services.p4d = {
    enable = lib.mkEnableOption "Perforce Helix Core p4d server";

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      defaultText = lib.literalExpression "pkgs.p4d";
      description = ''
        Package providing the `p4d` executable. Left null by default because
        nixpkgs marks Perforce packages unfree.
      '';
    };

    clientPackage = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      defaultText = lib.literalExpression "pkgs.p4";
      description = ''
        Package providing the `p4` client executable used for optional local
        bootstrap tasks like typemap installation and security configuration.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "p4d";
      description = "System user running the p4d service.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "p4d";
      description = "System group running the p4d service.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/p4d";
      description = "Persistent P4ROOT directory for metadata and archives.";
    };

    journalDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/p4d/journal";
      description = "Directory storing the live journal file.";
    };

    checkpointDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/p4d/checkpoints";
      description = "Directory reserved for checkpoints and offline backups.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address p4d listens on for normal client traffic.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1666;
      description = "TCP port exposed by p4d.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the p4d TCP port in the firewall.";
    };

    serverId = lib.mkOption {
      type = lib.types.str;
      default = "master";
      description = "Perforce server identifier written to P4ROOT/server.id.";
    };

    unicode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Initialize Unicode mode on first boot. Irreversible after init.";
    };

    caseSensitive = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the server remains case-sensitive. Linux default stays true.
        Set false only when tooling requires case-insensitive behavior.
      '';
    };

    securityLevel = lib.mkOption {
      type = with lib.types; nullOr (ints.between 0 5);
      default = 4;
      description = ''
        Optional `p4 configure set security=<level>` value applied during local
        bootstrap. Set null to skip automatic security tuning.
      '';
    };

    ssl = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether p4d listens with SSL enabled.";
      };

      dir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/p4d/ssl";
        description = "Directory holding p4d SSL certificate and key material.";
      };
    };

    bootstrap = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run one-time local bootstrap tasks on first start: optional security
          level configuration and Unreal typemap installation.
        '';
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Loopback address used by the local temporary bootstrap server.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 1667;
        description = "Loopback-only port used by the temporary bootstrap server.";
      };
    };

    typemap = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Generate the Unreal-focused typemap spec and optionally install it
          during bootstrap.
        '';
      };

      extraLines = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Extra lines appended to the generated Perforce typemap spec.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "hectic.services.p4d.package must be set, for example pkgs.p4d.";
      }
      {
        assertion = !cfg.bootstrap.enable || cfg.clientPackage != null;
        message = "hectic.services.p4d.clientPackage must be set when bootstrap.enable is true.";
      }
    ];

    users.groups.${serviceGroup} = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      home = cfg.dataDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${serviceUser} ${serviceGroup} - -"
      "d ${cfg.journalDir} 0750 ${serviceUser} ${serviceGroup} - -"
      "d ${cfg.checkpointDir} 0750 ${serviceUser} ${serviceGroup} - -"
      "d ${cfg.dataDir}/logs 0750 ${serviceUser} ${serviceGroup} - -"
      "d ${cfg.ssl.dir} 0700 ${serviceUser} ${serviceGroup} - -"
    ];

    systemd.services.p4d = {
      description = "Perforce Helix Core p4d server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      preStart = builtins.readFile initScript;
      serviceConfig = {
        Type = "simple";
        User = serviceUser;
        Group = serviceGroup;
        WorkingDirectory = cfg.dataDir;
        Environment = lib.mkIf cfg.ssl.enable "P4SSLDIR=${cfg.ssl.dir}";
        ExecStart = "${packageExe} ${lib.escapeShellArgs mainArgs}";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
        KillSignal = "SIGTERM";
        KillMode = "mixed";
        UMask = "0077";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
