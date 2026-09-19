{ ... }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.minecraft-public-relay;
in {
  options.services.minecraft-public-relay = {
    enable = lib.mkEnableOption "restricted SSH relay for Minecraft";
    publicPort = lib.mkOption { type = lib.types.port; default = 25568; };
    tunnelPort = lib.mkOption { type = lib.types.port; default = 25577; };
    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "Public SSH key of the Minecraft tunnel client";
    };
  };
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
    users.groups.mc-wow-relay = { };
    users.users.mc-wow-relay = {
      isSystemUser = true;
      group = "mc-wow-relay";
      openssh.authorizedKeys.keys = [
        "restrict,port-forwarding,permitlisten=\"127.0.0.1:${toString cfg.tunnelPort}\" ${cfg.publicKey}"
      ];
    };
    services.openssh.extraConfig = ''
      Match User mc-wow-relay
        ClientAliveInterval 15
        ClientAliveCountMax 3
        AllowTcpForwarding remote
        PermitListen 127.0.0.1:${toString cfg.tunnelPort}
        AllowAgentForwarding no
        X11Forwarding no
        PermitTTY no
        ForceCommand ${pkgs.coreutils}/bin/false
      Match all
    '';
    systemd.sockets.minecraft-wow-proxy = {
      description = "WorldOfSosal WoW public Minecraft port";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "0.0.0.0:${toString cfg.publicPort}" ];
    };
    systemd.services.minecraft-wow-proxy = {
      description = "Forward Minecraft to the neuro reverse tunnel";
      requires = [ "minecraft-wow-proxy.socket" ];
      after = [ "minecraft-wow-proxy.socket" ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString cfg.tunnelPort}";
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
