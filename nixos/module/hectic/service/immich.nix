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

    storageBox = {
      enable = lib.mkEnableOption "Hetzner Storage Box media storage";

      host = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9.-]*";
        default = "u666713-sub1.your-storagebox.de";
        description = "Hetzner Storage Box SMB hostname.";
      };

      username = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";
        default = "u666713-sub1";
        description = "Storage Box SMB username.";
      };

      share = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";
        default = "u666713-sub1";
        description = "SMB share exported by Storage Box.";
      };

      subdirectory = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_./-]*");
        default = null;
        description = "Directory within the SMB share used by Immich.";
      };

      credentialsFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "/[^[:space:]]+");
        default = null;
        description = ''
          Runtime file containing the SMB password. Keep this in a SOPS
          secret, outside the Nix store.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.secretsFile == null || !lib.hasPrefix "/nix/store/" cfg.secretsFile;
        message = "hectic.services.immich.secretsFile must reference a runtime secret path, not /nix/store.";
      }
      {
        assertion = !cfg.storageBox.enable || cfg.storageBox.credentialsFile != null;
        message = "hectic.services.immich.storageBox.credentialsFile is required when Storage Box is enabled.";
      }
      {
        assertion =
          !cfg.storageBox.enable
          || cfg.storageBox.credentialsFile == null
          || !lib.hasPrefix "/nix/store/" cfg.storageBox.credentialsFile;
        message = "hectic.services.immich.storageBox.credentialsFile must reference a runtime secret path, not /nix/store.";
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

    fileSystems.${toString cfg.mediaLocation} = lib.mkIf cfg.storageBox.enable {
      device = "//${cfg.storageBox.host}/${cfg.storageBox.share}";
      fsType = "cifs";
      options = [
        "_netdev"
        "nofail"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "vers=3.1.1"
        "seal"
        "cache=none"
        "credentials=${cfg.storageBox.credentialsFile}"
        "username=${cfg.storageBox.username}"
        "uid=${config.services.immich.user}"
        "gid=${config.services.immich.group}"
        "file_mode=0660"
        "dir_mode=0770"
      ] ++ lib.optional (cfg.storageBox.subdirectory != null)
        "prefixpath=${cfg.storageBox.subdirectory}";
    };

    systemd.services.immich-server.unitConfig.RequiresMountsFor = lib.mkIf cfg.storageBox.enable [
      cfg.mediaLocation
    ];
  };
}
