{
  inputs,
  flake,
  self,
}: {
  lib,
  pkgs,
  modulesPath,
  config,
  ...
}: let
  matrixHost = "accord.tube";
  jitsiHost = "meet.accord.tube";
  elementEntryDomain = "element.bfs.band";
  polandEntryDomain = "bfs.band";
  matrixClusterSopsFile = flake + "/sus/matrix-cluster.yaml";
in {
  imports = [
    self.nixosModules.xray-system
    self.nixosModules.matrix-cluster
    self.nixosModules.matrix-cluster-users
  ];

  hectic.generic.xray-system = {
    enable          = true;
    defaultSopsFile = ../../../sus/bfs.xray.yaml;
  };

  hectic.generic.matrix-cluster = {
    enable        = true;
    role          = "primary";
    matrixDomain  = "accord.tube";
    signingKeyFile = config.sops.secrets."matrix/signing-key".path;
    secretsFile    = config.sops.secrets."matrix/secrets".path;
    turnSecretFile = config.sops.secrets."matrix/turn-secret".path;
    publicIp       = "91.198.166.181";
    objectStorage.s3 = {
      bucket          = "matrix-hectic-lab";
      regionName      = "hel1";
      endpointUrl     = "https://hel1.your-objectstorage.com";
      credentialsFile = config.sops.secrets."matrix/object-storage/credentials".path;
    };
    replication = {
      passwordFile = config.sops.secrets."matrix/postgres-replication-password".path;
    };
    acme = {
      enable                  = false;
      porkbunApiKeyFile       = config.sops.secrets."matrix/porkbun-api-key".path;
      porkbunSecretApiKeyFile = config.sops.secrets."matrix/porkbun-secret-api-key".path;
    };
    jitsi.preferredDomain = jitsiHost;
  };

  hectic.services.media-browser = {
    enable = true;
    port = 3001;
    s3Bucket = "matrix-hectic-lab";
    s3Endpoint = "https://hel1.your-objectstorage.com";
    s3Region = "hel1";
    s3CredentialsFile = config.sops.secrets."matrix/object-storage/credentials".path;
  };

  hectic.services.jitsi = {
    enable = true;
    hostName = jitsiHost;
  };

  # NOTE(yukkop): disk was provisioned outside disko, so the expected partition
  # label does not exist. Pin root to the live filesystem UUID so stage 1 can
  # mount `/` reliably.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-uuid/06b48ef1-a1eb-428d-821c-90c96a624542";
    fsType = "ext4";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "security@bfs.band";
  };

  # NOTE(yukkop): this host gets an IPv6 route via RA, but object storage
  # fetches to hel1.your-objectstorage.com currently stall over IPv6 while
  # IPv4 works. Synapse's S3 media backend uses getaddrinfo ordering, so
  # prefer IPv4 here to keep Element media downloads responsive.
  environment.etc."gai.conf".text = ''
    precedence ::ffff:0:0/96  100
  '';

  systemd.services.matrix-synapse.restartTriggers = [
    config.environment.etc."gai.conf".source
  ];

  services.nginx = {
    enable = true;

    virtualHosts.${polandEntryDomain} = {
      enableACME = true;
      forceSSL = true;

      locations."/".return = "302 https://${elementEntryDomain}";

      locations."=/.well-known/matrix/client" = {
        extraConfig = ''
          default_type application/json;
          add_header Access-Control-Allow-Origin *;
          add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
          add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization";
        '';
        return = ''200 '{
          "m.homeserver": {
            "base_url": "https://${polandEntryDomain}"
          },
          "m.identity_server": {
            "base_url": "https://vector.im"
          },
          "org.matrix.msc3575.proxy": {
            "url": "https://${polandEntryDomain}"
          },
          "org.matrix.msc4143.rtc_foci": [
            {
              "type": "livekit",
              "livekit_service_url": "https://${polandEntryDomain}/livekit/jwt"
            }
          ]
        }' '';
      };

      locations."= /livekit/jwt" = {
        proxyPass = "http://[::1]:${toString config.services.lk-jwt-service.port}/";
      };

      locations."^~ /livekit/jwt/" = {
        proxyPass = "http://[::1]:${toString config.services.lk-jwt-service.port}/";
      };

      locations."= /livekit/sfu" = {
        proxyPass = "http://[::1]:${toString config.services.livekit.settings.port}/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_send_timeout 120;
          proxy_read_timeout 120;
          proxy_buffering off;
          proxy_set_header Accept-Encoding gzip;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        '';
      };

      locations."^~ /livekit/sfu/" = {
        proxyPass = "http://[::1]:${toString config.services.livekit.settings.port}/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_send_timeout 120;
          proxy_read_timeout 120;
          proxy_buffering off;
          proxy_set_header Accept-Encoding gzip;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        '';
      };

      locations."^~ /_matrix/" = {
        proxyPass = "http://127.0.0.1:8008";
        extraConfig = ''
          client_max_body_size ${config.hectic.generic.matrix-cluster.maxUploadSize};
        '';
      };

      locations."^~ /_synapse/client/" = {
        proxyPass = "http://127.0.0.1:8008";
      };
    };

    virtualHosts.${elementEntryDomain} = {
      enableACME = true;
      forceSSL = true;

      locations."= /config.${elementEntryDomain}.json".return = "302 /config.json";

      root = pkgs.hectic.element-web.override {
        conf = {
          default_server_config = {
            "m.homeserver".base_url = "https://${polandEntryDomain}";
            "m.homeserver".server_name = matrixHost;
            "m.identity_server".base_url = "https://vector.im";
          };

          jitsi = {
            preferred_domain = jitsiHost;
          };

          hectic.videoMessages.enabled = true;

          room_directory.servers = [ matrixHost ];

          default_theme = "dark";
          show_labs_settings = true;
        };
      };
    };
  };

  sops.secrets."matrix/signing-key" = {
    key      = "matrix/signing-key";
    owner    = "matrix-synapse";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/postgres-replication-password" = {
    key      = "matrix/postgres-replication-password";
    owner    = "postgres";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/object-storage/credentials" = {
    key      = "matrix/object-storage/credentials";
    owner    = "matrix-synapse";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/secrets" = {
    key      = "matrix/secrets";
    owner    = "matrix-synapse";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/turn-secret" = {
    key      = "matrix/turn-secret";
    owner    = "turnserver";
    group    = "turnserver";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/porkbun-api-key" = {
    key      = "matrix/porkbun-api-key";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
  sops.secrets."matrix/porkbun-secret-api-key" = {
    key      = "matrix/porkbun-secret-api-key";
    mode     = "0400";
    sopsFile = matrixClusterSopsFile;
  };
}
