{ ... }:
{ 
  lib,
  config,
  ...
}: let
  cfg = config.hectic.hardware.njalla;
in {
  options.hectic.hardware.njalla = {
    enable = lib.mkEnableOption "Enable njalla hardware configurations";
    ipv4 = lib.mkOption {
      type        = lib.types.strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}$";
      example     = "185.193.126.103";
      description = ''
        Njalla IPv4 address assigned to the host.
      '';
    };
    ipv4PrefixLength = lib.mkOption {
      type        = lib.types.int;
      default     = 24;
      example     = 24;
      description = ''
        Njalla IPv4 prefix length.
      '';
    };
    ipv4Gateway = lib.mkOption {
      type        = lib.types.strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}$";
      default     = "185.193.126.1";
      example     = "185.193.126.1";
      description = ''
        Njalla IPv4 gateway.
      '';
    };
    ipv6 = lib.mkOption {
      type        = lib.types.strMatching "^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$";
      example     = "2a0a:3840:1337:126:0:b9c1:7e67:1337";
      description = ''
        Njalla IPv6 address assigned to the host.
      '';
    };
    ipv6PrefixLength = lib.mkOption {
      type        = lib.types.int;
      default     = 64;
      example     = 64;
      description = ''
        Njalla IPv6 prefix length.
      '';
    };
    ipv6Gateway = lib.mkOption {
      type        = lib.types.strMatching "^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$";
      default     = "2a0a:3840:1337:126::1";
      example     = "2a0a:3840:1337:126::1";
      description = ''
        Njalla IPv6 gateway.
      '';
    };
    networkMatchConfigName = lib.mkOption {
      type        = lib.types.str;
      default     = "eth0";
      example     = "eth0";
      description = ''
        Njalla container network interface name.
      '';
    };
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/vda";
      example = "/dev/disk/by-id/virtio-root";
      description = ''
        Njalla installation disk for disko/nixos-anywhere.

        `/dev/vda` is the default block device visible on the inspected Njalla
        host. Prefer a stable `/dev/disk/by-id/...` path when available.
      '';
    };
    enableDisko = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Whether to provide a disko layout for nixos-anywhere installs.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.isContainer = true;

      networking.useDHCP    = false;
      networking.useNetworkd = true;
      systemd.network.enable = true;
      systemd.network.networks."30-wan" = {
        matchConfig.Name = cfg.networkMatchConfigName;
        networkConfig.DHCP = "no";
        address = [
          "${cfg.ipv4}/${toString cfg.ipv4PrefixLength}"
          "${cfg.ipv6}/${toString cfg.ipv6PrefixLength}"
        ];
        routes = [
          { Gateway = cfg.ipv4Gateway; }
          { Gateway = cfg.ipv6Gateway; }
        ];
      };

      networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
    }
    (lib.mkIf cfg.enableDisko {
      boot.loader.grub.device = cfg.device;

      disko.devices.disk.main = {
        type = "disk";
        device = cfg.device;
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size     = "1M";
              type     = "EF02";
              priority = 1;
            };
            root = {
              size    = "100%";
              content = {
                type       = "filesystem";
                format     = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    })
  ]);
}
