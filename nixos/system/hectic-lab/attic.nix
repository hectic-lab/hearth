{
  domain,
  ...
}: {
  config,
  pkgs,
  ...
}: {
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

  services.nginx.virtualHosts."cache.${domain}" = {
    enableACME = true;
    forceSSL   = true;
    extraConfig = ''
      client_max_body_size 0;
    '';
    locations."/" = {
      proxyPass = "http://127.0.0.1:8081";
      extraConfig = ''
        # Allow quiet periods while Attic fetches NAR chunks from object storage.
        proxy_read_timeout 300s;
      '';
    };
  };
}
