{ ... }: {
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.services.stable-video-diffusion;
in {
  options.hectic.services.stable-video-diffusion = {
    enable = lib.mkEnableOption "local Stable Video Diffusion HTTP API";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Stable Video Diffusion API binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7861;
      description = "Port the Stable Video Diffusion API binds to.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hectic.stable-video-diffusion-api;
      defaultText = lib.literalExpression "pkgs.hectic.stable-video-diffusion-api";
      description = "Package providing the Stable Video Diffusion API executable.";
    };

    modelId = lib.mkOption {
      type = lib.types.str;
      default = "stabilityai/stable-video-diffusion-img2vid-xt";
      description = "Model identifier loaded by the Stable Video Diffusion API.";
    };

    device = lib.mkOption {
      type = with lib.types; nullOr (enum [ "cpu" "cuda" ]);
      default = null;
      description = ''
        Torch device requested from the Stable Video Diffusion API. When null,
        the package keeps its own auto-detection behavior.
      '';
    };

    libraryPath = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      description = ''
        Runtime library paths added to LD_LIBRARY_PATH. CUDA/NVIDIA deployments
        should include /run/opengl-driver/lib so libcuda.so is visible to torch.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/stable-video-diffusion-api";
      description = "Persistent state directory for the Stable Video Diffusion API.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/stable-video-diffusion-api";
      description = "Cache directory for downloaded model and runtime artifacts.";
    };

    outputDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/outputs";
      defaultText = lib.literalExpression ''"\${config.hectic.services.stable-video-diffusion.stateDir}/outputs"'';
      description = "Directory where generated video outputs are written.";
    };

    environmentFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        Optional environment file for secrets or runtime overrides. Values from
        the unit environment define SVD_API_HOST, SVD_API_PORT, SVD_MODEL_ID,
        SVD_STATE_DIR, SVD_CACHE_DIR, SVD_OUTPUT_DIR, and optionally SVD_DEVICE
        and LD_LIBRARY_PATH by default.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the API port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.device != "cuda" || cfg.libraryPath != [];
        message = "hectic.services.stable-video-diffusion.libraryPath must include the NVIDIA runtime library path when device is cuda.";
      }
    ];

    users.users.stable-video-diffusion = {
      isSystemUser = true;
      group = "stable-video-diffusion";
    };
    users.groups.stable-video-diffusion = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 stable-video-diffusion stable-video-diffusion -"
      "d ${cfg.cacheDir} 0750 stable-video-diffusion stable-video-diffusion -"
      "d ${cfg.outputDir} 0750 stable-video-diffusion stable-video-diffusion -"
    ];

    systemd.services.stable-video-diffusion-api = {
      description = "Stable Video Diffusion HTTP API";
      after       = [ "network.target" ];
      wantedBy    = [ "multi-user.target" ];
      environment = {
        SVD_API_HOST   = cfg.host;
        SVD_API_PORT   = toString cfg.port;
        SVD_MODEL_ID   = cfg.modelId;
        SVD_STATE_DIR  = cfg.stateDir;
        SVD_CACHE_DIR  = cfg.cacheDir;
        SVD_OUTPUT_DIR = cfg.outputDir;
      }
      // lib.optionalAttrs (cfg.device != null) {
        SVD_DEVICE = cfg.device;
      }
      // lib.optionalAttrs (cfg.libraryPath != []) {
        LD_LIBRARY_PATH = lib.concatStringsSep ":" cfg.libraryPath;
      };
      serviceConfig = lib.mkMerge [
        {
          Type            = "simple";
          User            = "stable-video-diffusion";
          Group           = "stable-video-diffusion";
          WorkingDirectory = cfg.stateDir;
          ExecStart       = lib.getExe' cfg.package "stable-video-diffusion-api";
          Restart         = "on-failure";
          RestartSec      = "5s";
          TimeoutStopSec  = "30s";
          KillSignal      = "SIGTERM";
          KillMode        = "mixed";
          StandardOutput  = "journal";
          StandardError   = "journal";
        }
        (lib.mkIf (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
        })
      ];
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
