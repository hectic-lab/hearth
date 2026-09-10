{
  domain,
  ...
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  repackedActive = true;
  migrationWriteFreeze = false;

  uploadProxyConfig = ''
    # Stream large NARs and tolerate S3 backpressure while Attic reads them.
    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
  '';

  repackedSettings = config.services.atticd.settings // {
    listen = "127.0.0.1:8082";
    allowed-hosts = [ "cache.${domain}" ];
    api-endpoint = if repackedActive then "https://cache.${domain}/" else "https://cache.${domain}/next/";
    substituter-endpoint = if repackedActive then "https://cache.${domain}/" else "https://cache.${domain}/next/";
    database.url = "sqlite:///var/lib/atticd-repacked/server.db?mode=rwc";
    storage = {
      type     = "s3";
      bucket   = "nix-cache-hectic-lab";
      endpoint = "https://hel1.your-objectstorage.com";
      region   = "hel1";
    };
    chunking = {
      nar-size-threshold = 1048576;
      min-size           = 1048576;
      avg-size           = 2097152;
      max-size           = 4194304;
    };
    compression.type = "zstd";
  };

  repackedConfigFile = pkgs.runCommand "checked-atticd-repacked.toml" {
    configFile = (pkgs.formats.toml { }).generate "server-repacked.toml" repackedSettings;
  } ''
    export ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="$(${lib.getExe pkgs.openssl} genrsa -traditional 4096 | ${pkgs.coreutils}/bin/base64 -w0)"
    export ATTIC_SERVER_DATABASE_URL="sqlite://:memory:"
    ${lib.getExe config.services.atticd.package} --mode check-config -f $configFile
    cat <$configFile >$out
  '';
in {
  hectic.services.attic = {
    enable          = true;
    hostName        = "cache.${domain}";
    port            = 8081;
    environmentFile = config.sops.secrets."atticd/environment".path;
    storage = {
      bucket   = "cache-hectic-lab";
      endpoint = "https://hel1.your-objectstorage.com";
      region   = "hel1";
    };
  };

  # Slow S3 chunk reads can exceed the SDK's default 20-second stall grace.
  services.atticd.package = pkgs.attic-server.overrideAttrs (old: {
    # Restrict the SDK TLS connector to HTTP/1.1 after S3 REFUSED_STREAM errors.
    cargoDeps = pkgs.runCommand "attic-cargo-vendor-http1" { } ''
      mkdir "$out"
      shopt -s dotglob
      for entry in ${old.cargoDeps}/*; do
        ln -s "$entry" "$out/$(basename "$entry")"
      done
      crate=aws-smithy-http-client-1.0.6
      rm "$out/$crate"
      cp -rL ${old.cargoDeps}/"$crate" "$out/$crate"
      chmod -R u+w "$out/$crate"
      substituteInPlace "$out/$crate/src/client/tls.rs" \
        --replace-fail '.enable_http2()' ""
    '';
    postPatch = (old.postPatch or "") + ''
      substituteInPlace server/src/storage/s3.rs \
        --replace-fail 'let mut builder = S3ConfigBuilder::from(&shared_config);' \
          'let mut builder = S3ConfigBuilder::from(&shared_config)
              .stalled_stream_protection(
                  aws_sdk_s3::config::StalledStreamProtectionConfig::enabled()
                      .grace_period(Duration::from_secs(120))
                      .build(),
              );'
    '';
  });

  services.atticd.settings = lib.mkIf repackedActive {
    api-endpoint = lib.mkForce "https://cache.${domain}/previous/";
    substituter-endpoint = "https://cache.${domain}/previous/";
  };
  services.atticd.mode = if migrationWriteFreeze || repackedActive then "api-server" else "monolithic";

  systemd.services.atticd-repacked = {
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    serviceConfig = config.systemd.services.atticd.serviceConfig // {
      ExecStart       = "${lib.getExe config.services.atticd.package} -f ${repackedConfigFile} --mode monolithic";
      EnvironmentFile = config.sops.secrets."atticd/environment".path;
      StateDirectory  = "atticd-repacked";
      User            = "atticd-repacked";
      Group           = "atticd-repacked";
    };
  };

  services.nginx.virtualHosts."cache.${domain}" = {
    enableACME = true;
    forceSSL   = true;
    extraConfig = ''
      client_max_body_size 0;
    '';
    locations."/" = {
      proxyPass = if repackedActive then "http://127.0.0.1:8082" else "http://127.0.0.1:8081";
      extraConfig = ''
        # Allow quiet periods while Attic fetches NAR chunks from object storage.
        proxy_read_timeout 300s;
      '' + lib.optionalString (migrationWriteFreeze && !repackedActive) ''
        # Quiesce the old writer during the final snapshot and verification.
        limit_except GET {
          deny all;
        }
      '';
    };
    locations."/next/" = {
      proxyPass = "http://127.0.0.1:8082/";
      extraConfig = ''
        # Allow quiet periods while Attic fetches NAR chunks from object storage.
        proxy_read_timeout 300s;
      '';
    };
    locations."= /_api/v1/upload-path" = lib.mkIf (repackedActive || !migrationWriteFreeze) {
      proxyPass = if repackedActive then "http://127.0.0.1:8082" else "http://127.0.0.1:8081";
      extraConfig = uploadProxyConfig;
    };
    locations."= /next/_api/v1/upload-path" = {
      proxyPass = "http://127.0.0.1:8082/_api/v1/upload-path";
      extraConfig = uploadProxyConfig;
    };
    locations."/previous/" = {
      proxyPass = "http://127.0.0.1:8081/";
      extraConfig = ''
        # Legacy backend is exposed for read-only migration checks.
        limit_except GET {
          deny all;
        }
        # Allow quiet periods while Attic fetches NAR chunks from object storage.
        proxy_read_timeout 300s;
      '';
    };
  };
}
