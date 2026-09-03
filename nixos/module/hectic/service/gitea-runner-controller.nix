{
  inputs,
  flake,
  self,
}:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  cfg = config.hectic.services.gitea-runner-controller;

  secretPrefix = "gitea-runner-controller";
  mkControllerSecret = name: {
    name = "${secretPrefix}/${name}";
    value = {
      sopsFile = flake + "/sus/gitea-runners.yaml";
      key      = "gitea/hectic-lab/controller/${name}";
    };
  };

  controllerSecrets = builtins.listToAttrs (map mkControllerSecret [
    "hcloud-token"
    "webhook-secret"
    "admin-token"
    "ssh-private-key"
  ]);

  # Registration token is shared with the existing K8s/local runner setup.
  registrationTokenPath = config.sops.secrets."gitea-runner/org-registration-token".path;

  commonEnvironment =
    [
      "GCR_STATE_DIR=/var/lib/gitea-runner-controller"
      "GCR_GITEA_URL=${cfg.giteaBaseUrl}"
      "GCR_ALLOWED_REPOS=${lib.concatStringsSep "," cfg.allowedRepos}"
      "GCR_CONCURRENCY_CAP=${toString cfg.concurrencyCap}"
      "GCR_PER_REPO_CAP=${toString cfg.perRepoCap}"
      "GCR_RECONCILE_INTERVAL_SEC=${toString cfg.reconcileIntervalSec}"
      "GCR_BUDGET_EUR_MONTHLY=${cfg.budgetEurMonthly}"
      "GCR_HETZNER_LOCATION=${cfg.hetznerLocation}"
      "HCLOUD_TOKEN_FILE=${config.sops.secrets."${secretPrefix}/hcloud-token".path}"
      "GITEA_WEBHOOK_SECRET_FILE=${config.sops.secrets."${secretPrefix}/webhook-secret".path}"
      "GITEA_REGISTRATION_TOKEN_FILE=${registrationTokenPath}"
      "GITEA_ADMIN_TOKEN_FILE=${config.sops.secrets."${secretPrefix}/admin-token".path}"
      "GCR_SSH_PRIVKEY_FILE=${config.sops.secrets."${secretPrefix}/ssh-private-key".path}"
      "GCR_NIX_VERSION=${cfg.nixVersion}"
      "GCR_NIX_TARBALL_SHA256=${cfg.nixTarballSha256}"
      "GCR_ARM_NIX_TARBALL_SHA256=${cfg.armNixTarballSha256}"
      "GCR_ACT_RUNNER_VERSION=${cfg.actRunnerVersion}"
      "GCR_ACT_RUNNER_SHA256=${cfg.actRunnerSha256}"
    ]
    ++ lib.optionals (cfg.imageId != null) [ "GCR_IMAGE_ID=${cfg.imageId}" ]
    ++ lib.optionals (cfg.armImageId != null) [ "GCR_ARM_IMAGE_ID=${cfg.armImageId}" ];
in
{
  options = {
    hectic.services.gitea-runner-controller = {
      enable = lib.mkEnableOption "gitea-runner-controller — ephemeral Hetzner VM runner controller";
      listenAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address the webhook listener binds to.";
      };
      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 8787;
        description = "Port the webhook listener binds to.";
      };
      webhookHost = lib.mkOption {
        type = lib.types.str;
        default = "runners.hectic-lab.com";
        description = "Public vhost Gitea delivers webhooks to. Requires a DNS A record to this host.";
      };
      giteaBaseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://gitea.hectic-lab.com";
        description = "Public Gitea URL runners register against.";
      };
      allowedRepos = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ "hectic-lab/util.nix" ];
        description = "Repos whose workflow_job events may trigger VM creation.";
      };
      concurrencyCap = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Maximum simultaneously running ephemeral VMs (global).";
      };
      perRepoCap = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Maximum concurrent ephemeral VMs per repo.";
      };
      reconcileIntervalSec = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Seconds between reconciliation ticks.";
      };
      budgetEurMonthly = lib.mkOption {
        type = lib.types.str;
        default = "15";
        description = "Soft monthly EUR ceiling for estimated VM spend.";
      };
      hetznerLocation = lib.mkOption {
        type = lib.types.str;
        default = "nbg1";
        description = "Hetzner location for ephemeral VMs.";
      };
      imageId = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "174108912";
        description = ''
          Hetzner image/snapshot id for ephemeral VMs (MicroOS base from
          gitea-runners-build-microos-snapshots). Controller refuses VM
          creation while null.
        '';
      };
      armImageId = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "423979717";
        description = ''
          Hetzner ARM image/snapshot id for ephemeral VMs. Required for labels
          whose fallback chain includes ARM server types.
        '';
      };
      actRunnerVersion = lib.mkOption {
        type = lib.types.str;
        default = "1.0.6";
        description = "gitea-runner release version downloaded at VM bootstrap.";
      };
      actRunnerSha256 = lib.mkOption {
        type = lib.types.str;
        default = "d78ac11deed6580a2d88c1ef72c522aa7e2986d2d22b0d80edbee577b8f79b20";
        description = "sha256 of the pinned gitea-runner linux-amd64 binary, verified at bootstrap.";
      };
      nixVersion = lib.mkOption {
        type = lib.types.str;
        default = "2.28.3";
        description = "Nix release installed from the official static tarball at bootstrap.";
      };
      nixTarballSha256 = lib.mkOption {
        type = lib.types.str;
        default = "85d1847d06d5d56167796d3f61cd992908de84584db3e700da031a782b59ea22";
        description = "sha256 of the pinned Nix x86_64-linux tarball, verified at bootstrap.";
      };
      armNixTarballSha256 = lib.mkOption {
        type = lib.types.str;
        default = "3dffb118772382e35526806fb97acc05df7ad6dc29dbe52b921b77e52e39f571";
        description = "sha256 of the pinned Nix aarch64-linux tarball, verified at bootstrap.";
      };
      debugSshPublicKey = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = ''
          Injected into every ephemeral VM (project ssh-key "yukkop@nixos"
          carries the matching public key; this value is informational and
          used by gcr_bootstrap_script documentation).
        '';
      };
      bootstrapSshPrivateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path (sops-rendered) to the SSH private key the controller uses to
          push bootstrap into ephemeral VMs. Public half must be registered
          as Hetzner project ssh-key "yukkop@nixos".
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.imageId != null;
        message = "gitea-runner-controller: imageId must be set to a MicroOS snapshot id before enabling";
      }
    ];

    sops.secrets = controllerSecrets;

    systemd.services.gitea-runner-controller = {
      description = "Gitea ephemeral runner controller — reconcile loop";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${self.packages.${system}.gitea-runner-controller}/bin/gitea-runner-controller";
        Restart = "always";
        RestartSec = "5s";
        StateDirectory = "gitea-runner-controller";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = commonEnvironment;
      };
    };

    systemd.services.gitea-runner-webhook = {
      description = "Gitea ephemeral runner webhook receiver";
      after = [
        "network.target"
        "gitea-runner-controller.service"
      ];
      wantedBy = [ "multi-user.target" ];
      partOf = [ "gitea-runner-controller.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${self.packages.${system}.gitea-runner-controller}/bin/gitea-runner-webhook";
        Restart = "always";
        RestartSec = "2s";
        StateDirectory = "gitea-runner-controller";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = commonEnvironment ++ [
          "GCR_LISTEN_ADDR=${cfg.listenAddr}"
          "GCR_LISTEN_PORT=${toString cfg.listenPort}"
        ];
      };
    };

    services.nginx.virtualHosts."${cfg.webhookHost}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        extraConfig = ''
          proxy_pass http://${cfg.listenAddr}:${toString cfg.listenPort};
          proxy_read_timeout 30s;
        '';
      };
    };
  };
}
