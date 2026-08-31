{ system, inputs, self, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;

  mkSystem = module:
    lib.nixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
        self.nixosModules.hectic
        module
      ];
    };

  fakeP4d = pkgs.writeShellScriptBin "p4d" "exit 0";
  fakeP4 = pkgs.writeShellScriptBin "p4" "exit 0";

  enabledCfg = (mkSystem {
    hectic.services.p4d = {
      enable = true;
      package = fakeP4d;
    };
  }).config;

  bootstrapCfg = (mkSystem {
    hectic.services.p4d = {
      enable = true;
      package = fakeP4d;
      clientPackage = fakeP4;
      bootstrap.enable = true;
      openFirewall = true;
      caseSensitive = false;
    };
  }).config;
in {
  p4d-module-basic =
    assert enabledCfg.users.users.p4d.isSystemUser;
    assert enabledCfg.users.users.p4d.group == "p4d";
    assert enabledCfg.systemd.services.p4d.serviceConfig.User == "p4d";
    assert enabledCfg.systemd.services.p4d.serviceConfig.Group == "p4d";
    assert enabledCfg.systemd.services.p4d.serviceConfig.ExecStart == "${fakeP4d}/bin/p4d -r /var/lib/p4d -p ssl:0.0.0.0:1666 -J /var/lib/p4d/journal/journal -L /var/lib/p4d/logs/p4d.log";
    pkgs.runCommand "p4d-module-basic" {} ''
      touch "$out"
    '';

  p4d-module-bootstrap =
    assert lib.any (rule: rule == "d /var/lib/p4d/ssl 0700 p4d p4d - -") bootstrapCfg.systemd.tmpfiles.rules;
    assert bootstrapCfg.networking.firewall.allowedTCPPorts == [ 1666 ];
    assert bootstrapCfg.systemd.services.p4d.preStart != "";
    assert lib.hasInfix "configure set security=4" bootstrapCfg.systemd.services.p4d.preStart;
    assert lib.hasInfix "typemap -i" bootstrapCfg.systemd.services.p4d.preStart;
    assert lib.hasInfix "-C1" bootstrapCfg.systemd.services.p4d.serviceConfig.ExecStart;
    pkgs.runCommand "p4d-module-bootstrap" {} ''
      touch "$out"
    '';
}
