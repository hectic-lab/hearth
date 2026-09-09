{ attic-client
, coreutils
, dash
, gnused
, hectic
, lib
, nix
, util-linux
}:
let
  shell = "${dash}/bin/dash";
in
hectic.writeShellApplication {
  inherit shell;
  bashOptions = [
    "errexit"
    "nounset"
  ];
  excludeShellChecks = [ "SC2039" "SC2329" ];
  name = "with-attic-cache";
  runtimeInputs = [ attic-client coreutils gnused nix util-linux ];

  text = ''
    ATTIC_BIN_DEFAULT=${attic-client}/bin/attic
    COREUTILS_BIN_DEFAULT=${coreutils}/bin
    HOOK_SHELL_DEFAULT=${dash}/bin/dash
    NIX_BIN_DEFAULT=${nix}/bin/nix
    SETSID_BIN_DEFAULT=${util-linux}/bin/setsid
    TIMEOUT_BIN_DEFAULT=${coreutils}/bin/timeout
    ${builtins.readFile ./with-attic-cache.sh}
  '';

  meta = {
    description = "Run a Nix command while asynchronously uploading new build outputs to Attic";
    mainProgram = "with-attic-cache";
    platforms = lib.platforms.linux;
  };
}
