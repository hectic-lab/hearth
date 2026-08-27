{
  inputs ? null,
  flake ? null,
  self ? null,
  ...
}:
{
  config ? null,
  pkgs ? null,
  lib ? null,
  modulesPath ? null,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    self.nixosModules.hectic
    inputs.sops-nix.nixosModules.sops
    ./astroneer.nix
  ];

  hectic = {
    archetype.dev.enable = true;
    hardware.hetzner-cloud = {
      enable                 = true;
      networkMatchConfigName = "enp1s0";
      ipv4                   = "91.98.127.6";
      ipv6                   = "2a01:4f8:1c1b:6f10";
    };
  };

  sops = {
    gnupg.sshKeyPaths = [ ];
    age.sshKeyPaths   = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile   = ../../../sus/games.yaml;

    secrets."env"     = {};
  };

  environment.systemPackages = (with pkgs; [ rsync git steamcmd hectic.AstroTuxLauncher ]);

  hectic.services."project-zomboid" = {
    enable = true;
    serverName = "servertest";
    workshopItems = [ ];
    mods = [ ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAaObjLBslsdTlqEcYaS1TqX4x9aVJu75y27/8MFevO''
  ];
}
