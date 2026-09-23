{
  inputs,
  flake,
  self,
  ...
}:
{
  config,
  pkgs,
  lib,
  ...
}:
with builtins;
with lib;
let
  domain = "hectic-lab.com";
  sshPort = 22;
  mailUserNames = [
    "security"
    "founders"
    "lvgkcfjl"
    "yukkop"
    "daniil-perlyk"
    "iana-perlyk"
    "snuff"
    "antoshka"
    "evgenii-kazakov"
  ];
  mkMailPasswordSecret = name: {
    name  = "mailserver/${name}/hashedPassword";
    value = {};
  };
  mkMailLoginAccount = name: {
    inherit name;
    value = {
      hashedPasswordFile = config.sops.secrets."mailserver/${name}/hashedPassword".path;
    };
  };
  mkEnteSecret = name: {
    name  = "ente/${name}";
    value = {
      owner = "ente";
      group = "ente";
    };
  };
  giteaRunnerInstance = "hectic-lab-local";
  giteaRunnerEscapedInstance = builtins.replaceStrings [ "-" ] [ "\\x2d" ] giteaRunnerInstance;
  giteaRunnerService = "gitea-runner-${giteaRunnerEscapedInstance}";
  giteaRunnerTokenEnvService = "${giteaRunnerService}-token-env";
  giteaRunnerTokenEnv = "/run/gitea-runner-${giteaRunnerInstance}/token.env";
  worldOfSosalRoot = "/var/www/store/world-of-sosal";
in {
  imports = [
    self.nixosModules.hectic
    self.nixosModules.matrix-cluster
    inputs.sops-nix.nixosModules.sops

    self.nixosModules."shadowsocks-rust" # NOTE(nrv): impl
    self.nixosModules."shadowsocks"      # NOTE(nrv): usage/instance

    inputs.hectic-landing.nixosModules.hectic-landing
    inputs.iana-angl.nixosModules.iana-angl

    (import ./attic.nix              { inherit flake self inputs domain; })
    (import ./containers.nix          { inherit flake self inputs; })
    ./experimental-sshd.nix
    ./minecraft-wow-proxy.nix
    (import ./ente.nix               { inherit domain; })
    (import ./immich.nix             { inherit domain; })
    (import ./mechabellum.nix         { inherit flake self inputs domain; })
    (import (./. + "/sentinèlla.nix") { inherit flake self inputs domain; })
  ];

  services.hectic-landing = {
    enable  = true;
    package = inputs.hectic-landing.packages.${pkgs.stdenv.hostPlatform.system}.hectic-landing;
    domain  = domain;
    port    = 3000;
    host    = "127.0.0.1";
  };

  services.iana-angl = {
    enable  = true;
    package = inputs.iana-angl.packages.${pkgs.stdenv.hostPlatform.system}.iana-angl;
    domain  = "lessons.${domain}";
  };

  # NOTE(yukkop): both nixos-mailserver and hectic-landing module set
  # security.acme.defaults.email. Force the mailserver-aligned address.
  security.acme.defaults.email = lib.mkForce "security@${domain}";

  hectic = {
    archetype.dev.enable = true;
    hardware.hetzner-cloud = {
      enable                 = true;
      networkMatchConfigName = "enp1s0";
      ipv4                   = "128.140.75.58";
      floatingIpv4           = "78.47.243.0";
      ipv6                   = "2a01:4f8:c2c:d54a";
    };
    services.matrix = {
      enable = false;
    };
    services."project-zomboid" = {
      enable = true;
      memory = "3g";
      serverName = "servertest";
      serverPropertiesFile = /var/lib/project-zomboid/server-password.ini;
      rcon.enable = true;
      backup = {
        enable = true;
        onCalendar = "*:0/30";
        retentionDays = 14;
        s3 = {
          enable = true;
          bucket = "backup-hectic-lab";
          endpoint = "https://hel1.your-objectstorage.com";
          region = "hel1";
          credentialsFile = "/var/lib/project-zomboid/s3-credentials";
        };
      };
      serverProperties = {
        Map = "Muldraugh, KY";
        SaveWorldEveryMinutes = 15;
        DoLuaChecksum = false;
        Public = true;
        AntiCheatSafety = 4;
        AntiCheatMovement = 4;
        AntiCheatSpeed = 4;
        AntiCheatHit = 4;
        AntiCheatPacket = 4;
        AntiCheatPacketException = 4;
        AntiCheatPermission = 4;
        AntiCheatXP = 4;
        AntiCheatFire = 4;
        AntiCheatSafeHouse = 4;
        AntiCheatRecipe = 4;
        AntiCheatPlayer = 4;
        AntiCheatChecksum = 4;
        AntiCheatItem = 4;
        AntiCheatNoClip = 4;
        AntiCheatServerCustomization = 4;
      };
      workshopItems = [
        "3676456221" # Lua Digital Watch Framework
        "3600401184" # Realistic Temperature Mod
      ];
      mods = [
        "\\LuaDigitalWatchUI"
        "\\RC_RealisticColdMod"
      ];
    sandboxProperties = {
      StartMonth = 12;
      StartDay = 1;
      WaterShut = 3;
      WaterShutModifier = 150;
      ElecShut = 3;
      ElecShutModifier = 150;
      MinutesPerPage = 0.5;
      Zombies = 4;
      ZombieConfig = {
        PopulationMultiplier = 1.3;
        PopulationStartMultiplier = 1.0;
        PopulationPeakMultiplier = 1.0;
        RespawnHours = 0.0;
        RespawnUnseenHours = 0.0;
        RespawnMultiplier = 0.0;
        RedistributeHours = 0.0;
      };
      ZombieLore = {
        Transmission = 4;
        Mortality = 7;
        Speed = 2;
        SprinterPercentage = 0;
        Strength = 2;
        Cognition = 2;
        DoorOpeningPercentage = 10;
      };
    };
  };
    services.p4d = {
      enable = true;
      package = pkgs.p4d;
      clientPackage = pkgs.p4;
      openFirewall = true;
      bootstrap.enable = false;
    };
    services.gitea-runner-controller = {
      # NOTE(yukkop): ephemeral Hetzner VM runners (1 VM = 1 job).
      # Runbook: infra/gitea-runners/runbook.md "Ephemeral VM runner cutover".
      enable  = true;
      budgetEurMonthly = "30";
      imageId = "429747473"; # MicroOS x86 + persistent controller SSH key and writable Nix mount
      armImageId = "423979717"; # OpenSUSE MicroOS ARM K3S 2026-08-24 snapshot
      nixImageId = "161547269"; # Ubuntu 24.04 x86; Nix needs writable root
      armNixImageId = "161547270"; # Ubuntu 24.04 ARM; Nix needs writable root
      allowedRepos = [
        "hinterland/*"
        "yukkop/*"
        "hectic-lab/*"
      ];
      # FIXME(yukkop): debug key for bootstrap debugging; remove once E2E stable.
    debugSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSWIv80pyCMDQ6zH34P2qWizpOcO7X86BVhMGtbob9U gcr-controller@hectic-lab";
    hcloudSshKeyId = 118512401;
    };
  };

  zramSwap = {
    enable        = true;
    priority      = 100;
    algorithm     = lib.mkDefault "zstd";
    swapDevices   = 1;
    memoryPercent = lib.mkDefault 100;
  };

  # NOTE(yukkop): disk was provisioned by Hetzner rescue image, disko was never
  # run, so partition labels don't exist. Override fileSystems with actual UUIDs.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-uuid/48ba7286-d019-4cdc-9784-459767979b07";
    fsType = "ext4";
  };

  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-uuid/71F2-4E98";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  fileSystems."/nix" = lib.mkForce {
    device = "/dev/disk/by-id/scsi-0HC_Volume_106777875";
    fsType = "ext4";
    neededForBoot = true;
  };

  programs.zsh.enable = true;
  programs.zsh.interactiveShellInit = ''
    setopt vi
  '';

  environment.systemPackages = with pkgs; [
    tcpdump
    git
    rsync
    python311
    kitty
  ];

  # Secrets config
  sops = {
    gnupg.sshKeyPaths  = [ ];
    age.sshKeyPaths    = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile    = flake + "/sus/hectic-lab.yaml";
    secrets = builtins.listToAttrs (map mkMailPasswordSecret mailUserNames) // {
      "init-postgresql" = {
        key = "init-postgresql";
      };
      "atticd/environment" = {};
       "immich/storage-box" = {};
       "wg-bfs/private-key" = {};
      "gitea-runner/org-registration-token" = {
        sopsFile = flake + "/sus/gitea-runners.yaml";
        key      = "gitea/hectic-lab/org-runner-registration-token";
      };
    } // builtins.listToAttrs (map mkEnteSecret [
      "key-encryption"
      "key-hash"
      "jwt-secret"
      "s3-access-key"
      "s3-secret-key"
    ]) // {
      "project-zomboid/s3-access-key" = {
        key = "ente/s3-access-key";
        owner = "project-zomboid";
        group = "project-zomboid";
      };
      "project-zomboid/s3-secret-key" = {
        key = "ente/s3-secret-key";
        owner = "project-zomboid";
        group = "project-zomboid";
      };
    };
  };

  systemd.services.project-zomboid.preStart = lib.mkBefore ''
    password_file=${lib.escapeShellArg "/var/lib/project-zomboid/server-password"}
    properties_file=${lib.escapeShellArg "/var/lib/project-zomboid/server-password.ini"}
    s3_credentials_file=${lib.escapeShellArg "/var/lib/project-zomboid/s3-credentials"}
    s3_credentials_tmp="$(${pkgs.coreutils}/bin/mktemp "''${s3_credentials_file}.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$s3_credentials_tmp"' EXIT

    {
      ${pkgs.coreutils}/bin/printf 'AWS_ACCESS_KEY_ID='
      ${pkgs.coreutils}/bin/cat ${lib.escapeShellArg config.sops.secrets."project-zomboid/s3-access-key".path}
      ${pkgs.coreutils}/bin/printf '\n'
      ${pkgs.coreutils}/bin/printf 'AWS_SECRET_ACCESS_KEY='
      ${pkgs.coreutils}/bin/cat ${lib.escapeShellArg config.sops.secrets."project-zomboid/s3-secret-key".path}
      ${pkgs.coreutils}/bin/printf '\n'
    } > "$s3_credentials_tmp"
    ${pkgs.coreutils}/bin/chmod 0400 "$s3_credentials_tmp"
    ${pkgs.coreutils}/bin/mv -f "$s3_credentials_tmp" "$s3_credentials_file"

    if [ ! -s "$password_file" ] || ! ${pkgs.gnugrep}/bin/grep -Eq '^[0-9a-f]{48}$' "$password_file"; then
      umask 077
      ${pkgs.openssl}/bin/openssl rand -hex 24 > "$password_file"
    fi
    ${pkgs.coreutils}/bin/chmod 0600 "$password_file"

    properties_file_tmp="$(${pkgs.coreutils}/bin/mktemp "$(dirname "$properties_file")/.server-password.ini.XXXXXX")"
    ${pkgs.coreutils}/bin/printf 'Password=%s\n' "$(<"$password_file")" > "$properties_file_tmp"
    ${pkgs.coreutils}/bin/chmod 0600 "$properties_file_tmp"
    ${pkgs.coreutils}/bin/mv "$properties_file_tmp" "$properties_file"
  '';

  users.users.root.openssh.authorizedKeys.keys = [
    # neuro machine
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDfqSROY+rp7amPPiArY3sZM7jTjYBS02csWxF/NeIr/ root@neuro"
    # yukkop
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMuP5NSfEQmO6m77xBWZvZ3hk7cw1q2k2vbsFd37rybU u0_a327@localhost"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJBLxMo5icX2Xyng7mcWGnIi+c4ZbVygjPhuU8noCkfZ"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxgLlX/15Fk7PgIc9FSrA7oRtA8qK4GXfOhj7ZlNUaJ nix-on-droid@localhost"
    # snuff
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFouceNUxI3bGC24/hfA8J3VuBpvTcZh3KhixgrMiLte"
    # nrv
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/EhBI6sJb2yHbTkqhZiCzUrsLE6t+CZe7RhS22z7w5 nrv@adamantia"
    # github workflow
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKPEUArBxu7NUULT7Pi8ArtVxY1uVbIBSaeRKtqz1sz1"
    # gitea workflow
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAogEr5boewtUrOeOqI96y/7FWR03vdbGW93Nj01tiIS gitea-actions-hectic-lab-deploy"
  ];

  users.users.ds4d = { # NOTE(nrv): artishoque
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINcjBc57N6MxtMYAHEB/nwZ+OGsG3P1KWO1ZXvzQyhKn ds4d@ds4d"
    ];
  };

  users.users.sshuttle = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKd4iU2E5fiwPwBbeo1ZPo0YBFEj9qBPew/KitaO+OHU"
    ];
  };

  services.openssh.ports = [ sshPort ];

  services.mailserver = {
    enable = true;
    domain = domain;
    loginAccounts = builtins.listToAttrs (map mkMailLoginAccount mailUserNames);
  };

  mailserver.stateVersion = 3;

  services.redis.servers."vproxy-bot-test-state" = {
    enable = true;
    port   = 6379;
  };

  services.mysql = {
    enable  = true;
    package = pkgs.mariadb;
  };

  networking.firewall = {
    allowedTCPPorts = [
      sshPort # ssh
      80
      443
      3306  # mysql
      25565
      55228 # ss-bfs
    ];
    allowedUDPPorts = [
      51820 # wg-bfs
      55228 # ss-bfs
    ];
    # Postgres replication: only the PL standby peer may reach 5432.
    extraInputRules = ''
      ip saddr 91.198.166.181/32 tcp dport 5432 accept
    '';
  };

  virtualisation.docker.enable = true;

  systemd.tmpfiles.rules = [
    "d /var/www/store 0755 nginx nginx -"
    "d ${worldOfSosalRoot} 0750 root nginx -"
    "d ${worldOfSosalRoot}/releases 0750 root nginx -"
  ];

  systemd.services.${giteaRunnerTokenEnvService} = {
    description = "Prepare local Gitea Actions runner token environment";
    requiredBy  = [ "${giteaRunnerService}.service" ];
    before      = [ "${giteaRunnerService}.service" ];
    serviceConfig = {
      Type             = "oneshot";
      RemainAfterExit  = true;
      RuntimeDirectory = "gitea-runner-${giteaRunnerInstance}";
      RuntimeDirectoryMode = "0700";
    };
    script = ''
      set -eu
      umask 077
      token_file=${config.sops.secrets."gitea-runner/org-registration-token".path}
      env_file=${giteaRunnerTokenEnv}

      printf 'TOKEN=' > "$env_file"
      tr -d '\n' < "$token_file" >> "$env_file"
      printf '\n' >> "$env_file"
    '';
  };

  systemd.services.${giteaRunnerService} = {
    after = [
      "gitea.service"
      "${giteaRunnerTokenEnvService}.service"
    ];
    requires = [ "${giteaRunnerTokenEnvService}.service" ];
  };

  services.nginx = {
    enable = true;
    # NOTE(yukkop): virtualHosts.${domain} is owned by the hectic-landing module
    virtualHosts."store.${domain}" = {
      enableACME = true;
      forceSSL = true;
      root = "/var/www/store";
      locations."/" = {
        extraConfig = ''
          autoindex on;
        '';
      };
      locations."= /world-of-sosal/" = {
        extraConfig = ''
          return 302 /world-of-sosal/index.html;
        '';
      };
      locations."= /world-of-sosal/index.html" = {
        extraConfig = ''
          alias ${./static/world-of-sosal/index.html};
          default_type text/html;
          add_header Cache-Control "no-cache" always;
          limit_except GET {
            deny all;
          }
        '';
      };
      locations."= /world-of-sosal/latest.mrpack" = {
        extraConfig = ''
          root /var/www/store;
          default_type application/zip;
          add_header Content-Disposition "attachment" always;
          add_header Cache-Control "no-cache, no-store, must-revalidate" always;
          try_files $uri =404;
          if ($request_method != GET) { return 405; }
        '';
      };
      locations."= /world-of-sosal/SHA256SUMS" = {
        extraConfig = ''
          root /var/www/store;
          default_type text/plain;
          add_header Content-Disposition "attachment" always;
          add_header Cache-Control "no-cache, no-store, must-revalidate" always;
          try_files $uri =404;
          if ($request_method != GET) { return 405; }
        '';
      };
      locations."= /world-of-sosal/releases/" = {
        extraConfig = ''
          return 404;
        '';
      };
      locations."~ ^/world-of-sosal/releases/[A-Za-z0-9][A-Za-z0-9._-]*\\.mrpack$" = {
        extraConfig = ''
          root /var/www/store;
          default_type application/zip;
          add_header Content-Disposition "attachment" always;
          add_header Cache-Control "public, max-age=31536000, immutable" always;
          try_files $uri =404;
          if ($request_method != GET) { return 405; }
        '';
      };
      locations."/world-of-sosal/" = {
        extraConfig = ''
          autoindex off;
          limit_except GET {
            deny all;
          }
          return 404;
        '';
      };
    };
    virtualHosts."lessons.${domain}" = {
      enableACME = true;
      forceSSL = true;
    };
    virtualHosts."snuff.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        extraConfig = ''
          proxy_pass     http://188.32.215.29:3993/;
          proxy_redirect off;
        '';
      };
    };
    virtualHosts."nrv.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        extraConfig = ''
          proxy_pass     http://127.0.0.1:22842/;
          proxy_redirect off;
        '';
      };
    };
    virtualHosts."yukkop.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        extraConfig = ''
          proxy_pass     http://127.0.0.1:9855/;
          proxy_redirect off;
        '';
      };
    };
    virtualHosts."gitea.${domain}" = {
      enableACME = true;
      forceSSL = true;
      # NOTE(yukkop): allow large git pushes over HTTPS.
      extraConfig = "client_max_body_size 512m;";
      locations."/" = {
        extraConfig = ''
          proxy_pass     http://127.0.0.1:11011/;
          proxy_redirect off;
        '';
      };
    };
  };

  services = {
    gitea = {
      enable = true;
      package = pkgs.hectic.gitea-heatmap;
      settings.service.DISABLE_REGISTRATION = false;
      settings.actions.ENABLED = true;
      # Long CUDA builds must not hit Gitea's default three-hour task watchdog.
      settings.actions.ENDLESS_TASK_TIMEOUT = "8h";
      settings.server = {
        HTTP_PORT  = 11011;
        SSH_PORT   = sshPort;
        SSH_DOMAIN = "hectic-lab.com";
      };
      database = {
        createDatabase = true;
        type = "postgres";
        socket = "/run/postgresql";
        user = "gitea";
        name = "gitea";
      };
    };
    gitea-actions-runner.instances.${giteaRunnerInstance} = {
      enable    = false;
      name      = giteaRunnerInstance;
      url       = "https://gitea.${domain}";
      tokenFile = giteaRunnerTokenEnv;
      labels = [
        "nix:host"
        "native:host"
      ];
      hostPackages = with pkgs; [
        bash
        cacert
        coreutils
        curl
        git
        gnutar
        gzip
        nix
        nodejs
        xz
      ];
    };
  };
}
