{ pkgs, ... }:
let
  port = 22222;
  stateDir = "/var/lib/experimental-sshd";
  configFile = pkgs.writeText "experimental-sshd_config" ''
    Port 22222
    ListenAddress 0.0.0.0
    ListenAddress ::

    HostKey ${stateDir}/ssh_host_ed25519_key
    HostKey ${stateDir}/ssh_host_rsa_key

    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    PermitRootLogin prohibit-password
    UsePAM yes
    AuthenticationMethods publickey
    AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
    LogLevel DEBUG3

    VersionAddendum none
    HostKeyAlgorithms rsa-sha2-512,rsa-sha2-256,ssh-ed25519
    KexAlgorithms curve25519-sha256,diffie-hellman-group14-sha256
    Ciphers aes256-ctr,aes128-ctr
    MACs hmac-sha2-512,hmac-sha2-256
  '';

  keygenScript = pkgs.writeShellScript "experimental-sshd-keygen" ''
    set -eu

    ${pkgs.coreutils}/bin/mkdir -p -m 0700 ${stateDir}

    if [ ! -f ${stateDir}/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f ${stateDir}/ssh_host_ed25519_key -N ""
    fi

    if [ ! -f ${stateDir}/ssh_host_rsa_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t rsa -b 4096 -f ${stateDir}/ssh_host_rsa_key -N ""
    fi
  '';
in
{
  environment.etc."ssh/experimental-sshd_config".source = configFile;

  networking.firewall.allowedTCPPorts = [ port ];

  systemd.services.experimental-sshd-keygen = {
    description = "Generate experimental SSH host keys";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "experimental-sshd";
      ExecStart = keygenScript;
    };
  };

  systemd.services.experimental-sshd = {
    description = "Experimental SSH daemon";
    wantedBy = [ "multi-user.target" ];
    wants = [ "experimental-sshd-keygen.service" ];
    after = [ "network.target" "experimental-sshd-keygen.service" ];
    serviceConfig = {
      Type = "simple";
      StateDirectory = "experimental-sshd";
      RuntimeDirectory = "experimental-sshd";
      ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f /etc/ssh/experimental-sshd_config";
    };
    preStart = ''
      ${pkgs.openssh}/bin/sshd -t -f /etc/ssh/experimental-sshd_config
    '';
  };
}
