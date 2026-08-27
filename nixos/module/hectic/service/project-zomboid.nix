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
  startScript = pkgs.writeShellScript "project-zomboid-start" ''
    exec ${lib.escapeShellArg "${cfg.installDir}/start-server.sh"} \
      -servername ${lib.escapeShellArg cfg.serverName} \
      -cachedir ${lib.escapeShellArg cfg.dataDir}
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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the Project Zomboid UDP ports in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
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
    ];

    systemd.services.project-zomboid = {
      description = "Project Zomboid dedicated server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        ${pkgs.coreutils}/bin/install -d -m 0750 \
          ${lib.escapeShellArg cfg.installDir}
        ${pkgs.steamcmd}/bin/steamcmd \
          +force_install_dir ${lib.escapeShellArg cfg.installDir} \
          +login anonymous \
          +app_update 380870 ${lib.optionalString (cfg.branch != null) "-beta ${lib.escapeShellArg cfg.branch}"} validate \
          +quit
        ${pkgs.coreutils}/bin/install -d -m 0750 \
          ${lib.escapeShellArg "${cfg.dataDir}/Server"}
        {
          ${lib.concatMapStringsSep "\n  " (line:
            "${pkgs.coreutils}/bin/printf '%s\\n' ${lib.escapeShellArg line};"
          ) configLines}
          ${lib.optionalString (cfg.serverPropertiesFile != null)
            "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg cfg.serverPropertiesFile};"}
        } > ${lib.escapeShellArg "${cfg.dataDir}/Server/${cfg.serverName}.ini"}
      '';

      serviceConfig = {
        User = "project-zomboid";
        Group = "project-zomboid";
        WorkingDirectory = cfg.dataDir;
        Environment = [
          "HOME=${cfg.dataDir}"
          "SteamAppId=380870"
        ];
        ExecStart = startScript;
        ExecStop = "-${pkgs.coreutils}/bin/kill -INT $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        UMask = "0077";
      };
    };

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.udpPort
    ];
  };
}
