{ ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.hectic.services.immich;
in
{
  options.hectic.services.immich = {
    enable = lib.mkEnableOption "Immich self-hosted photo and video service";

    domain = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9.-]*";
      description = "Public hostname used to reach Immich.";
    };

    mediaLocation = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/immich";
      description = ''
        Local filesystem path used for Immich media. Upstream Immich does not
        support S3 as its media backend; use a local disk or block volume here.
      '';
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[KMG]?";
      default = "10G";
      description = "Maximum request body accepted by nginx in front of Immich.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/[^[:space:]]+");
      default = null;
      description = ''
        SOPS-backed environment file passed to Immich. Use this for secrets
        such as DB_PASSWORD; never put secret values in Nix configuration.
      '';
    };

    machineLearning = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable Immich machine-learning features.";
      };
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Device paths exposed to Immich for hardware acceleration.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.secretsFile == null || !lib.hasPrefix "/nix/store/" cfg.secretsFile;
        message = "hectic.services.immich.secretsFile must reference a runtime secret path, not /nix/store.";
      }
    ];

    services.immich = {
      enable = true;
      host = "127.0.0.1";
      mediaLocation = cfg.mediaLocation;
      secretsFile = cfg.secretsFile;
      accelerationDevices = cfg.accelerationDevices;
      machine-learning.enable = cfg.machineLearning.enable;
      settings.server.externalDomain = "https://${cfg.domain}";
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.domain} = {
        enableACME = true;
        forceSSL = true;
        extraConfig = lib.mkForce ''
          client_max_body_size ${cfg.maxUploadSize};
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.immich.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };
    };
  };
}
