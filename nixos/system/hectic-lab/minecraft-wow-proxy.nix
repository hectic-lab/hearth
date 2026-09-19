{ pkgs, ... }:
{
  # Public entry point; the backend arrives through a restricted reverse tunnel.
  networking.firewall.allowedTCPPorts = [ 25568 ];
  users.groups.mc-wow-relay = { };
  users.users.mc-wow-relay = {
    isSystemUser = true;
    group = "mc-wow-relay";
    openssh.authorizedKeys.keys = [
      "restrict,port-forwarding,permitlisten=\"127.0.0.1:25577\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNWWegOVTOF3EOmam32iP7sMybULMTxsXuC+cEGITQ8 minecraft-wow-relay"
    ];
  };
  services.openssh.extraConfig = ''
    Match User mc-wow-relay
      ClientAliveInterval 15
      ClientAliveCountMax 3
      AllowTcpForwarding remote
      PermitListen 127.0.0.1:25577
      AllowAgentForwarding no
      X11Forwarding no
      PermitTTY no
      ForceCommand ${pkgs.coreutils}/bin/false
    Match all
  '';
  systemd.sockets.minecraft-wow-proxy = {
    description = "WorldOfSosal WoW public Minecraft port";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "0.0.0.0:25568" ];
  };
  systemd.services.minecraft-wow-proxy = {
    description = "Forward Minecraft to the neuro reverse tunnel";
    requires = [ "minecraft-wow-proxy.socket" ];
    after = [ "minecraft-wow-proxy.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:25577";
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
