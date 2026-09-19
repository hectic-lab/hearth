{ ... }:
{
  imports = [ (import ../../module/generic/minecraft-public-relay.nix { }) ];
  services.minecraft-public-relay = {
    enable = true;
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNWWegOVTOF3EOmam32iP7sMybULMTxsXuC+cEGITQ8 minecraft-wow-relay";
  };
}
