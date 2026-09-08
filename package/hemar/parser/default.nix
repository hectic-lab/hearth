{ dash, hectic, symlinkJoin, yq-go }:
let
  shell = "${dash}/bin/dash";
  bashOptions = [
    "errexit"
    "nounset"
  ];

  hemar = hectic.writeShellApplication {
    inherit shell bashOptions;
    excludeShellChecks = [ "SC1091" ];
    name = "hemar";
    runtimeInputs = [ yq-go ];

    text = ''
      # shellcheck disable=SC2034
      WORKSPACE=${./.}
      . ${hectic.helpers.posix-shell.log}
      ${builtins.readFile ./hemar.sh}
    '';
  };
in
symlinkJoin {
  name = "hemar";
  paths = [ hemar ];
}
