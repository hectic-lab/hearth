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
  modulesPath,
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
in {
  imports = [
    self.nixosModules.hectic
    self.nixosModules.matrix-cluster
    inputs.sops-nix.nixosModules.sops

    self.nixosModules."shadowsocks-rust" # NOTE(nrv): impl
    self.nixosModules."shadowsocks"      # NOTE(nrv): usage/instance

    inputs.hectic-landing.nixosModules.hectic-landing

    (import ./attic.nix              { inherit flake self inputs domain; })
    (import ./containers.nix          { inherit flake self inputs; })
    ./experimental-sshd.nix
    (import ./ente.nix               { inherit domain; })
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
      "wg-bfs/private-key" = {};
    } // builtins.listToAttrs (map mkEnteSecret [
      "key-encryption"
      "key-hash"
      "jwt-secret"
      "s3-access-key"
      "s3-secret-key"
    ]);
  };

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
  ];

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
      settings.service.DISABLE_REGISTRATION = true;
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
  };
}
