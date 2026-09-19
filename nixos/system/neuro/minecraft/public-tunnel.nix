{ config, pkgs, ... }:
let
  mkTunnel = relay: {
    description = "WorldOfSosal WoW reverse tunnel to ${relay.name}";
    startLimitIntervalSec = 0;
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      User = "mc-wow-tunnel";
      Group = "mc-wow-tunnel";
      ExecStart = "${pkgs.openssh}/bin/ssh -NT -i ${config.sops.secrets."minecraft/wow-tunnel-key".path} -o IPQoS=none -o Ciphers=aes256-ctr -o MACs=hmac-sha2-256-etm@openssh.com -o KexAlgorithms=curve25519-sha256 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -R 127.0.0.1:25577:127.0.0.1:25567 mc-wow-relay@${relay.address}";
      Restart = "always";
      RestartSec = 10;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
in {
  users.groups.mc-wow-tunnel = { };
  users.users.mc-wow-tunnel = {
    isSystemUser = true;
    group = "mc-wow-tunnel";
  };
  sops.secrets."minecraft/wow-tunnel-key" = {
    sopsFile = ../../../../sus/neuro-minecraft.yaml;
    owner = "mc-wow-tunnel";
    group = "mc-wow-tunnel";
    mode = "0400";
  };
  programs.ssh.knownHosts.minecraft-wow-relay = {
    hostNames = [ "128.140.75.58" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFpr4DPSaJt0xeuGIfcZBJD3LsJHTdIRIs2Tt9HF+CT";
  };
  programs.ssh.knownHosts.minecraft-wow-relay-bfs = {
    hostNames = [ "91.198.166.181" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcCn57nlWY5QyEz17kxuAbIX9PkjPwtlGzdJyhy+SQQ";
  };
  systemd.services.minecraft-wow-tunnel = mkTunnel {
    name = "hectic-lab";
    address = "128.140.75.58";
  };
  systemd.services.minecraft-wow-tunnel-bfs = mkTunnel {
    name = "bfs.band";
    address = "91.198.166.181";
  };
}
