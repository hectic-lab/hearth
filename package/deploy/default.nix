{ inputs, symlinkJoin, dash, hectic, ssh-to-age, stdenv }:
let
  shell = "${dash}/bin/dash";
  bashOptions = [
    "errexit"
    "nounset"
  ];

  deploy = hectic.writeShellApplication {
    inherit shell bashOptions;
    excludeShellChecks = [ "SC1091" "SC2034" ];
    name = "deploy";
    runtimeInputs = [
      ssh-to-age
      inputs.nixos-anywhere.packages.${stdenv.hostPlatform.system}.nixos-anywhere
    ];

    text = ''
      . ${hectic.helpers.posix-shell.log}/bin/log.sh
      ${builtins.readFile ./deploy.sh}
    '';
  };
in
symlinkJoin {
  name = "deploy";
  paths = [ deploy ];
}
