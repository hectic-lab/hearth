{ dash, hectic, git, gnutar, gzip, bzip2, xz, unzip, coreutils, file }:
let
  shell = "${dash}/bin/dash";
in
hectic.writeShellApplication {
  inherit shell;
  bashOptions = [
    "errexit"
    "nounset"
  ];
  excludeShellChecks = [ "SC1091" "SC2209" ];
  name = "merge-archive";
  runtimeInputs = [ git gnutar gzip bzip2 xz unzip coreutils file ];

  text = ''
    . ${hectic.helpers.posix-shell.log}/bin/log.sh
    . ${hectic.helpers.posix-shell.pager_or_cat}/bin/pager_or_cat.sh
    ${builtins.readFile ./merge-archive.sh}
  '';

  meta = {
    description = "Merge an archive into a git repository with --allow-unrelated-histories";
    mainProgram = "merge-archive";
  };
}
