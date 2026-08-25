{
  ...
}:
{ 
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.hardware.hetzner-cloud;
  isNewer = cfg.generation == "newer";
  networkMatchConfig =
    (lib.optionalAttrs (cfg.networkMatchConfigName != null) {
      Name = cfg.networkMatchConfigName;
    })
    // (lib.optionalAttrs (cfg.networkMatchConfigMac != null) {
      PermanentMACAddress = cfg.networkMatchConfigMac;
    });
in {
  options.hectic.hardware.hetzner-cloud = {
    enable = lib.mkEnableOption "Enable hetzner-cloud hardware configurations";
    generation = lib.mkOption {
      type = lib.types.enum [ "classic" "newer" ];
      default = "classic";
      description = ''
        Hetzner server generation profile.

        `classic` keeps the historical `/dev/sda` assumption.
        `newer` is for ccx/NVMe-era servers and defaults the disk device to
        `/dev/nvme0n1`.
      '';
    };
    #bootParUuid = lib.mkOption {
    #  type = with lib.types; nullOr oneOf [
    #    (lib.types.strMatching "^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$")
    #    (lib.types.strMatching "^[0-9a-fA-F-]{36}$")
    #  ];
    #  default = null;
    #  example = "5628-19B6";
    #  description = ''
    #    boot partition uuid if it is null 
    #    then will use "/dev/sda15" (default hetzner cloud boot device)
    #  '';
    #};
    ipv4 = lib.mkOption {
      type        = lib.types.strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}$";
      example     = "188.243.124.246";
      description = ''
        
      '';
    };
    ipv6 = lib.mkOption {
      type        = lib.types.strMatching "^([0-9a-fA-F]{1,4}:){3}[0-9a-fA-F]{1,4}$";
      example     = "2a01:4f8:1c1a:d883";
      description = ''
        
      '';
    };
    floatingIpv4 = lib.mkOption {
      type = with lib.types; nullOr (strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}$");
      default = null;
      example = "188.243.124.247";
      description = ''
        Optional Hetzner Floating IPv4 configured as `/32` on the primary interface.
      '';
    };
    device = lib.mkOption {
      type = lib.types.str;
      default = if isNewer then "/dev/nvme0n1" else "/dev/sda";
      example = "/dev/disk/by-uuid/f184a16b-6eca-41cb-b48a-ff37cdce1d79";
      description = ''
        boot device uuid 
        if it is null then will use "/dev/sda" 
        /dev/sda - default hetzner cloud device
        /dev/nvme0n1 - default for newer Hetzner generations
        !! But can changes on reboot if server have volumes
        !! So use IDs
      '';
    };
    networkMatchConfigName = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "enp1s0";
      description = ''
        Optional interface name to match in systemd-networkd.

        Prefer `networkMatchConfigMac` for stable matching across rescue
        images and installed systems that may rename interfaces differently.

        You can use `networkctl list` on server to know it.
      '';
    };
    networkMatchConfigMac = lib.mkOption {
      type = with lib.types; nullOr (strMatching "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$");
      default = null;
      example = "92:00:08:4a:b0:32";
      description = ''
        Optional permanent MAC address to match in systemd-networkd.

        This is the preferred Hetzner Cloud matching method because interface
        names can differ between rescue images and installed NixOS systems.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge
  [
    {
      boot.loader.systemd-boot.enable = false;
      boot.loader.efi.canTouchEfiVariables = false;
      boot.loader.grub = {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;
        device = "nodev";
      };

      boot.initrd.availableKernelModules = [
        "ata_piix"
        "uhci_hcd"
        "xen_blkfront"
      ] ++ (if pkgs.stdenv.hostPlatform.system != "aarch64-linux" then [ "vmw_pvscsi" ] else []);

      networking.useDHCP    = false;
      networking.useNetworkd = true;
      systemd.network.enable = true;
      systemd.network.networks."30-wan" = {
        matchConfig = networkMatchConfig;
        networkConfig.DHCP = "no";
        address = [
          "${cfg.ipv4}/32"
          "${cfg.ipv6}::/64"
        ] ++ lib.optional (cfg.floatingIpv4 != null) "${cfg.floatingIpv4}/32";
        routes = [
          {
            Gateway = "172.31.1.1";
            GatewayOnLink = true;
            PreferredSource = cfg.ipv4;
          }
          { Gateway = "fe80::1"; }
        ];
      };

      disko.devices = {
        disk = {
          main = {
            type = "disk";
            device = cfg.device;
            content = {
              type = "gpt";
              partitions = {
                boot = {
                  size = "1M";
                  type = "EF02";
                  priority = 1;
                };
                ESP = {
                  size = "512M";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot";
                  };
                };
                root = {
                  size = "100%";
                  content = {
                    type = "filesystem";
                    format = "ext4";
                    mountpoint = "/";
                  };
                };
              };
            };
          };
        };
      };

      assertions = [
        {
          assertion = cfg.networkMatchConfigName != null || cfg.networkMatchConfigMac != null;
          message = "hectic.hardware.hetzner-cloud requires networkMatchConfigName or networkMatchConfigMac";
        }
      ];
    } 
    (lib.mkIf (pkgs.stdenv.hostPlatform.system == "aarch64-linux") {
      boot.initrd.kernelModules = [ "virtio_gpu" ];
      boot.kernelParams = [ "console=tty" ];
    })
  ]);
}
