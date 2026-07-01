{
  inputs,
  flake,
  self,
}: {
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.generic.matrix-cluster;
  s3Cfg = cfg.objectStorage.s3;

  s3Plugin = pkgs.matrix-synapse-plugins.matrix-synapse-s3-storage-provider;
  s3ConfigDir = "/run/matrix-synapse";
  s3ConfigFile = "${s3ConfigDir}/s3-media-storage.yaml";

  pgDataDir = "/var/lib/postgresql/17";

  matrixUsers = builtins.attrNames cfg.users;

  mkUserRegistration = name: let
    user = cfg.users.${name};
    adminFlag = if user.admin then "--admin" else "--no-admin";
  in ''
    if [ ! -r "${user.passwordFile}" ]; then
      printf 'Missing Matrix password file for %s: %s\n' '${name}' '${user.passwordFile}' >&2
      exit 1
    fi

    ${pkgs.matrix-synapse}/bin/register_new_matrix_user \
      -u '${name}' \
      -p "$(tr -d '\n' < "${user.passwordFile}")" \
      -k "$REGISTRATION_SHARED_SECRET" \
      ${adminFlag} \
      http://127.0.0.1:8008 || true
  '';

  synapseEnabled =
    if cfg.overrideEnableSynapse != null
    then cfg.overrideEnableSynapse
    else cfg.role == "primary";

  mkS3Config = ''
    if [ ! -r "${s3Cfg.credentialsFile}" ]; then
      printf 'Missing Matrix object storage credentials file: %s\n' '${s3Cfg.credentialsFile}' >&2
      exit 1
    fi

    . "${s3Cfg.credentialsFile}"

    if [ -z "$ACCESS_KEY_ID" ] || [ -z "$SECRET_ACCESS_KEY" ]; then
      printf 'ACCESS_KEY_ID or SECRET_ACCESS_KEY missing in %s\n' '${s3Cfg.credentialsFile}' >&2
      exit 1
    fi

    mkdir -p "${s3ConfigDir}"

    cat > "${s3ConfigFile}" <<EOF
    media_storage_providers:
      - module: s3_storage_provider.S3StorageProviderBackend
        store_local: ${lib.boolToString s3Cfg.storeLocal}
        store_remote: ${lib.boolToString s3Cfg.storeRemote}
        store_synchronous: ${lib.boolToString s3Cfg.storeSynchronous}
        config:
          bucket: ${s3Cfg.bucket}
          endpoint_url: ${s3Cfg.endpointUrl}
          region_name: ${s3Cfg.regionName}
          prefix: "${s3Cfg.prefix}"
          storage_class: "${s3Cfg.storageClass}"
          threadpool_size: ${toString s3Cfg.threadpoolSize}
          access_key_id: $ACCESS_KEY_ID
          secret_access_key: $SECRET_ACCESS_KEY
    EOF

    chown matrix-synapse:matrix-synapse "${s3ConfigFile}"
    chmod 0400 "${s3ConfigFile}"
  '';
in {
  options.hectic.generic.matrix-cluster = {
    enable = lib.mkEnableOption "Matrix Synapse active/passive cluster node";

    role = lib.mkOption {
      type = lib.types.enum [ "primary" "standby" ];
      description = ''
        Cluster role of this node. The primary runs Synapse and accepts WAL
        streaming connections; the standby runs a hot-standby Postgres replica
        only and keeps Synapse disabled until failover.
      '';
    };

    matrixDomain = lib.mkOption {
      type = lib.types.str;
      description = "Matrix server_name (also nginx vhost / ACME cert name).";
    };

    signingKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the Synapse homeserver signing key. Mounted into place at
        /var/lib/matrix-synapse/homeserver.signing.key on activation.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Extra Synapse YAML config (registration_shared_secret, macaroon_secret_key,
        form_secret). Loaded via matrix-synapse extraConfigFiles. Required when
        Synapse is enabled on this node (primary, or standby after failover).
      '';
    };

    turnSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Shared secret file used by coturn for Matrix voice/video calls.
        When set together with `publicIp`, the active Synapse node also enables
        coturn and publishes TURN URIs to clients.
      '';
    };

    publicIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public IP address advertised to coturn for listening and relaying.
      '';
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "2G";
    };

    enableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          passwordFile = lib.mkOption { type = lib.types.str; };
          admin = lib.mkOption { type = lib.types.bool; default = false; };
        };
      });
      default = {};
      description = "Declarative Matrix users provisioned via register_new_matrix_user.";
    };

    overrideEnableSynapse = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        When non-null, forces Synapse on/off regardless of role. Used during
        failover: set to true on the standby once it has been promoted, or
        false on the primary to drain it.
      '';
    };

    objectStorage.s3 = {
      bucket = lib.mkOption { type = lib.types.str; };
      regionName = lib.mkOption { type = lib.types.str; };
      endpointUrl = lib.mkOption { type = lib.types.str; };
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          env-style file with ACCESS_KEY_ID= and SECRET_ACCESS_KEY=. MUST be
          the SAME credentials/bucket on both primary and standby.
        '';
      };
      mediaStorePath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/matrix-synapse/media_store";
      };
      prefix = lib.mkOption { type = lib.types.str; default = ""; };
      storageClass = lib.mkOption { type = lib.types.str; default = "STANDARD"; };
      threadpoolSize = lib.mkOption { type = lib.types.int; default = 40; };
      storeLocal = lib.mkOption { type = lib.types.bool; default = true; };
      storeRemote = lib.mkOption { type = lib.types.bool; default = true; };
      storeSynchronous = lib.mkOption { type = lib.types.bool; default = true; };
    };

    replication = {
      peerHost = lib.mkOption {
        type = lib.types.str;
        description = "Public IP/hostname of the other cluster node.";
      };
      peerPort = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File containing either a raw replication password or a libpq passfile
          line. Used as `passfile=` in primary_conninfo on the standby and to
          set the password of the `replication` Postgres role on the primary.
        '';
      };
      allowedSourceIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          CIDRs allowed to connect to Postgres for replication. Used on the
          primary in pg_hba.conf hostssl entries and to gate the firewall.
        '';
      };
      sslMode = lib.mkOption {
        type = lib.types.str;
        default = "require";
      };
    };

    acme = {
      enable = lib.mkEnableOption "Porkbun DNS-01 ACME for matrixDomain";
      email = lib.mkOption {
        type = lib.types.str;
        default = "hectic.yukkop.it@gmail.com";
        description = "ACME registration email (passed to security.acme.defaults.email).";
      };
      porkbunApiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "File containing PORKBUN_API_KEY value.";
      };
      porkbunSecretApiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "File containing PORKBUN_SECRET_API_KEY value.";
      };
    };

    jitsi.preferredDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional self-hosted Jitsi Meet domain to advertise to Matrix/Element
        clients alongside the cluster-managed homeserver.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    {
      # signing key mount: copy into matrix-synapse data dir with correct perms
      # regardless of whether Synapse is currently enabled on this node, so a
      # failover flip does not need a separate provisioning step.
      systemd.tmpfiles.rules = [
        "d /var/lib/matrix-synapse 0750 matrix-synapse matrix-synapse -"
        "Z ${s3Cfg.mediaStorePath} 0700 matrix-synapse matrix-synapse -"
      ];

      systemd.services.matrix-cluster-signing-key = {
        description = "Install Matrix Synapse signing key from secrets";
        wantedBy = [ "multi-user.target" ];
        before = lib.optional synapseEnabled "matrix-synapse.service";
        requiredBy = lib.optional synapseEnabled "matrix-synapse.service";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          install -d -o matrix-synapse -g matrix-synapse -m 0750 /var/lib/matrix-synapse
          install -o matrix-synapse -g matrix-synapse -m 0400 \
            "${cfg.signingKeyFile}" \
            /var/lib/matrix-synapse/homeserver.signing.key
        '';
      };

      users.users.matrix-synapse = {
        isSystemUser = true;
        group = "matrix-synapse";
      };
      users.groups.matrix-synapse = {};
    }

    (lib.mkIf synapseEnabled {
      assertions = [
        {
          assertion = cfg.secretsFile != null;
          message = "hectic.generic.matrix-cluster.secretsFile must be set when Synapse runs on this node.";
        }
        {
          assertion = (cfg.turnSecretFile == null) == (cfg.publicIp == null);
          message = "hectic.generic.matrix-cluster.turnSecretFile and publicIp must be set together.";
        }
      ];

      services.coturn = lib.mkIf (cfg.turnSecretFile != null) rec {
        enable = true;
        realm = cfg.matrixDomain;
        use-auth-secret = true;
        static-auth-secret-file = cfg.turnSecretFile;
        cert = "${config.security.acme.certs.${realm}.directory}/full.pem";
        pkey = "${config.security.acme.certs.${realm}.directory}/key.pem";
        listening-ips = [ cfg.publicIp ];
        relay-ips = [ cfg.publicIp ];
        listening-port = 3478;
        tls-listening-port = 5349;
        no-cli = true;

        extraConfig = ''
          verbose
        '';
      };

      services.matrix-synapse = {
        enable = true;
        plugins = [ s3Plugin ];
        extraConfigFiles = [ cfg.secretsFile s3ConfigFile ];

        settings = {
          server_name = cfg.matrixDomain;
          public_baseurl = "https://${cfg.matrixDomain}";
          max_upload_size = cfg.maxUploadSize;
          media_store_path = s3Cfg.mediaStorePath;
          signing_key_path = "/var/lib/matrix-synapse/homeserver.signing.key";

          # Tolerate bursty Element/iPhone presence syncs without disabling limits.
          rc_presence.per_user = {
            per_second = 0.5;
            burst_count = 5;
          };

          experimental_features = {
            msc3266_enabled = true;
            msc4140_enabled = true;
            msc4143_enabled = true;
            msc4222_enabled = true;
          };

          matrix_rtc = {
            transports = [
              {
                type = "livekit";
                livekit_service_url = "https://${cfg.matrixDomain}/livekit/jwt";
              }
            ];
          };

          listeners = [
            {
              port = 8008;
              bind_addresses = [ "0.0.0.0" ];
              type = "http";
              tls = false;
              resources = [
                {
                  names = [ "client" "federation" "openid" ];
                  compress = false;
                }
              ];
            }
          ];

          enable_registration = cfg.enableRegistration;
          enable_registration_without_verification = cfg.enableRegistration;
        } // lib.optionalAttrs (cfg.turnSecretFile != null) {
          turn_uris = [
            "turn:${cfg.matrixDomain}:3478?transport=udp"
            "turn:${cfg.matrixDomain}:3478?transport=tcp"
            "turns:${cfg.matrixDomain}:5349?transport=udp"
            "turns:${cfg.matrixDomain}:5349?transport=tcp"
          ];
          turn_user_lifetime = 86400000;
          turn_allow_guests = true;
        };
      };

      environment.systemPackages = [ pkgs.matrix-synapse ];

      systemd.services.matrix-synapse-s3-config = {
        description = "Generate Synapse S3 media storage config";
        before = [ "matrix-synapse.service" ];
        requiredBy = [ "matrix-synapse.service" ];
        serviceConfig.Type = "oneshot";
        script = mkS3Config;
      };

      services.nginx = {
        enable = true;
        virtualHosts.${cfg.matrixDomain} = {
          forceSSL = true;
          enableACME = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:8008";
            extraConfig = ''
              client_max_body_size ${cfg.maxUploadSize};
            '';
          };
          locations."=/.well-known/matrix/server" = {
            extraConfig = ''
              default_type application/json;
              add_header Access-Control-Allow-Origin *;
              add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
              add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization";
            '';
            return = "200 '{\"m.server\": \"${cfg.matrixDomain}:443\"}'";
          };
        };
      };

      networking.firewall = lib.mkIf (cfg.turnSecretFile != null) {
        allowedUDPPorts = [ 3478 5349 ];
        allowedTCPPorts = [ 3478 5349 ];
        allowedTCPPortRanges = [
          {
            from = 49152;
            to = 65535;
          }
        ];
        allowedUDPPortRanges = [
          {
            from = 49152;
            to = 65535;
          }
        ];
      };

      systemd.services.matrix-synapse-users = lib.mkIf (matrixUsers != []) {
        description = "Provision Matrix Synapse users";
        wantedBy = [ "multi-user.target" ];
        after = [ "matrix-synapse.service" ];
        requires = [ "matrix-synapse.service" ];
        path = with pkgs; [ curl coreutils gawk ];
        serviceConfig = {
          Type = "oneshot";
          User = "matrix-synapse";
        };
        script = ''
          until curl -sf http://127.0.0.1:8008/_matrix/client/versions >/dev/null; do
            sleep 2
          done

          REGISTRATION_SHARED_SECRET="$(awk -F': *' '$1 == "registration_shared_secret" { print $2; exit }' "${cfg.secretsFile}")"

          if [ -z "$REGISTRATION_SHARED_SECRET" ]; then
            printf 'registration_shared_secret not found in %s\n' '${cfg.secretsFile}' >&2
            exit 1
          fi

${lib.concatStringsSep "\n" (map mkUserRegistration matrixUsers)}
        '';
      };
    })

    {
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        enableTCPIP = true;

        initdbArgs = [ "--locale=C" "--encoding=UTF8" ];

        settings = {
          wal_level = "replica";
          max_wal_senders = 4;
          hot_standby = "on";
        };
      };
    }

    (lib.mkIf (cfg.role == "primary") {
      services.postgresql = {
        authentication = lib.concatStringsSep "\n" ([
          "local all         all                          trust"
          "host  sameuser    all          127.0.0.1/32    scram-sha-256"
          "host  sameuser    all          ::1/128         scram-sha-256"
          "host  all         all          ::1/128         scram-sha-256"
          "host  all         all          0.0.0.0/0       scram-sha-256"
          "host  replication postgres     127.0.0.1/32    scram-sha-256"
          "host  replication postgres     ::1/128         scram-sha-256"
        ] ++ map (cidr:
          "hostssl replication replication ${cidr} scram-sha-256"
        ) cfg.replication.allowedSourceIPs);

        ensureUsers = [
          {
            name = "replication";
            ensureClauses = {
              login = true;
              replication = true;
            };
          }
        ];
      };

      # Apply replication password from SOPS-mounted file after postgres start.
      systemd.services.matrix-cluster-replication-password = {
        description = "Set Postgres replication role password from SOPS";
        wantedBy = [ "multi-user.target" ];
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          PW="$(tr -d '\n' < "${cfg.replication.passwordFile}")"
          ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -c \
            "ALTER ROLE replication WITH LOGIN REPLICATION PASSWORD '$PW';"
        '';
      };
    })

    (lib.mkIf (cfg.role == "standby") {
      systemd.targets.postgresql.requires = lib.mkForce [
        "postgresql.service"
      ];

      # Hot-standby bootstrap: standby.signal + primary_conninfo with passfile.
      # pg_basebackup must be run manually (see runbook) before this activates
      # for the first time.
      systemd.services.matrix-cluster-standby-bootstrap = {
        description = "Configure Matrix Postgres hot standby";
        wantedBy = [ "postgresql.service" ];
        before = [ "postgresql.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          if [ ! -d "${pgDataDir}" ]; then
            echo "Postgres data dir ${pgDataDir} missing; run pg_basebackup first (see MATRIX-FAILOVER-RUNBOOK.md)" >&2
            exit 0
          fi

          # Materialize a libpq passfile from the raw password secret.
          PASSFILE=/var/lib/postgresql/.matrix-cluster-replication.passfile
          PW="$(tr -d '\n' < "${cfg.replication.passwordFile}")"
          umask 077
          printf '%s:%d:replication:replication:%s\n' \
            '${cfg.replication.peerHost}' \
            ${toString cfg.replication.peerPort} \
            "$PW" > "$PASSFILE"
          chown postgres:postgres "$PASSFILE"
          chmod 0600 "$PASSFILE"

          touch "${pgDataDir}/standby.signal"
          chown postgres:postgres "${pgDataDir}/standby.signal"

          CONF="${pgDataDir}/postgresql.auto.conf"
          touch "$CONF"
          chown postgres:postgres "$CONF"
          # Strip any prior primary_conninfo line, then append fresh one.
          ${pkgs.gnused}/bin/sed -i '/^primary_conninfo/d' "$CONF"
          printf "primary_conninfo = 'host=%s port=%d user=replication passfile=%s sslmode=%s'\n" \
            '${cfg.replication.peerHost}' \
            ${toString cfg.replication.peerPort} \
            "$PASSFILE" \
            '${cfg.replication.sslMode}' >> "$CONF"
        '';
      };
    })

    (lib.mkIf cfg.acme.enable {
      security.acme = {
        acceptTerms = true;
        defaults.email = lib.mkDefault cfg.acme.email;
        certs.${cfg.matrixDomain} = {
          dnsProvider = "porkbun";
          webroot = lib.mkForce null;
          environmentFile = "/run/matrix-cluster/porkbun.env";
        };
      };

      systemd.services.matrix-cluster-acme-env = {
        description = "Assemble Porkbun ACME environment file";
        wantedBy = [ "multi-user.target" ];
        before = [ "acme-${cfg.matrixDomain}.service" ];
        requiredBy = [ "acme-${cfg.matrixDomain}.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          install -d -m 0755 /run/matrix-cluster
          API="$(tr -d '\n' < "${cfg.acme.porkbunApiKeyFile}")"
          SEC="$(tr -d '\n' < "${cfg.acme.porkbunSecretApiKeyFile}")"
          OUT=/run/matrix-cluster/porkbun.env
          umask 077
          {
            printf 'PORKBUN_API_KEY=%s\n' "$API"
            printf 'PORKBUN_SECRET_API_KEY=%s\n' "$SEC"
          } > "$OUT"
          chmod 0400 "$OUT"
        '';
      };
    })
  ]);
}
