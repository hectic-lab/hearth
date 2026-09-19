{ ... }:
{
  imports = [ (import ../../module/generic/minecraft-public-relay.nix { }) ];
  services.minecraft-public-relay = {
    enable = true;
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNWWegOVTOF3EOmam32iP7sMybULMTxsXuC+cEGITQ8 minecraft-wow-relay";
  };
  systemd.tmpfiles.rules = [ "d /var/www/store/minecraft/world-of-sosal 0755 root root -" ];
  services.nginx.virtualHosts."bfs.band".locations = {
    "= /minecraft".return = "302 /minecraft/world-of-sosal/";
    "= /minecraft/".return = "302 /minecraft/world-of-sosal/";
    "^~ /minecraft/" = {
      root = "/var/www/store";
      extraConfig = ''
        autoindex off;
        add_header Cache-Control "no-cache";
        try_files $uri $uri/ =404;
      '';
    };
  };
}
