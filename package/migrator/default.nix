{ dash, hectic, sqlite, postgresql_17, gawk, coreutils, self }:
let
  shell = "${dash}/bin/dash";
  bashOptions = [
    "errexit"
    "nounset"
  ];

  applyBundle = self.lib.hectic.applyBundleScript;

  migrator = hectic.writeShellApplication {
    inherit shell bashOptions;
    excludeShellChecks = [ "SC1091" ];
    name = "migrator";
    runtimeInputs = [ sqlite postgresql_17 gawk coreutils ];

    text = ''
      . ${hectic.helpers.posix-shell.log}/bin/log.sh
      ${applyBundle}
      ${builtins.readFile ./migrator.sh}
    '';
  };
in
migrator
