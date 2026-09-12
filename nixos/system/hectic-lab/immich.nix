{ domain, ... }:
{
  config,
  ...
}:
{
  hectic.services.immich = {
    enable = true;
    domain = "immich.${domain}";

    storageBox = {
      enable = true;
      credentialsFile = config.sops.secrets."immich/storage-box".path;
    };
  };
}
