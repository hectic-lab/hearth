{ dash, hectic, curl, coreutils, gawk, procps, writeTextFile, lib }:
let
  shell = "${dash}/bin/dash";
  bashOptions = [
    "errexit"
    "nounset"
  ];

  logHelpers = builtins.readFile ../../lib/shell/logs.sh;
  scriptText = builtins.readFile ./linux-devshell.sh;

  linuxDevShell = hectic.writeShellApplication {
    inherit shell bashOptions;
    name = "linux-devshell";
    runtimeInputs = [ curl coreutils gawk procps ];
  excludeShellChecks = [ "SC1090" "SC1091" "SC2034" ];

    text = ''
      ${logHelpers}
      ${scriptText}
    '';

    meta = {
      description = "Install Nix and enter development shell";
      mainProgram = "linux-devshell";
    };
  };

  linuxDevShellStandalone = writeTextFile {
    name = "linux-devshell";
    executable = true;
    text = ''
      #!/bin/sh
      ${lib.concatMapStringsSep "\n" (option: "set -o ${option}") bashOptions}

      ${logHelpers}
      ${scriptText}
    '';
    meta = {
      description = "Standalone linux-devshell script (single file)";
      mainProgram = "linux-devshell";
    };
  };
in
{
  linux-devshell = linuxDevShell;
  linux-devshell-standalone = linuxDevShellStandalone;
}
