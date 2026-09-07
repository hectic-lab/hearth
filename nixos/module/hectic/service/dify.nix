{ ... }: {
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.hectic.services.dify;

  difySource = pkgs.fetchFromGitHub {
    owner = "langgenius";
    repo = "dify";
    rev = "00e578606715a9da34488608edee8c68d4ef4893";
    hash = "sha256-kLxMdmt1FtOl39C9SS7ZGY6C78e3hPiVI5Q3EdbkMPU=";
  };

  composeOverride = pkgs.writeText "dify-compose.override.yaml" ''
    services:
      nginx:
        ports: !override
          - "127.0.0.1:${toString cfg.port}:80"
      plugin_daemon:
        ports: !override
          - "127.0.0.1:${toString cfg.pluginPort}:5003"
  '';
in {
  options.hectic.services.dify = {
    enable = lib.mkEnableOption "Dify self-hosted AI platform";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dify";
      description = "Persistent directory for Dify compose state and volumes.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Environment file for Dify. Keep secrets here, including SECRET_KEY,
        DB_PASSWORD, REDIS_PASSWORD, and plugin daemon credentials.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Loopback HTTP port forwarded to Dify through SSH.";
    };

    pluginPort = lib.mkOption {
      type = lib.types.port;
      default = 5003;
      description = "Loopback plugin daemon port forwarded through SSH when needed.";
    };

    composeProfiles = lib.mkOption {
      type = lib.types.str;
      default = "weaviate,postgresql,collaboration";
      description = "Dify Docker Compose profiles to start.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    systemd.services.dify = {
      description = "Dify Docker Compose stack";
      wantedBy = [ "multi-user.target" ];
      wants = [ "docker.service" ];
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      restartIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = cfg.dataDir;
        ExecStartPre = pkgs.writeShellScript "dify-prepare" ''
          set -eu
          install -d -m 0750 ${lib.escapeShellArg cfg.dataDir}
          cp -R ${difySource}/docker/. ${lib.escapeShellArg cfg.dataDir}/
          install -m 0600 ${lib.escapeShellArg cfg.environmentFile} ${lib.escapeShellArg cfg.dataDir}/.env
        '';
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose --project-directory ${cfg.dataDir} --file ${cfg.dataDir}/docker-compose.yaml --file ${composeOverride} --env-file ${cfg.dataDir}/.env up --detach";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose --project-directory ${cfg.dataDir} --file ${cfg.dataDir}/docker-compose.yaml --file ${composeOverride} --env-file ${cfg.dataDir}/.env down";
      };
      environment = {
        COMPOSE_PROFILES = cfg.composeProfiles;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root -"
    ];
  };
}
