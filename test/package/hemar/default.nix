{ inputs, self, pkgs, system, ... }: let 
  lib = inputs.nixpkgs.lib;

  # turn anything under ./test into a derivation that exposes $out/run.sh
  mkTestDrv = name: type:
    if type == "directory" then
      pkgs.runCommand "test-${name}" {} ''
        if ! [ -f ${./test + "/${name}" + /run.sh} ]; then
          echo no run.sh in test/${name}
	  exit 1
        fi

        mkdir -p "$out"
        cp -r ${./test + "/${name}"}/* "$out/"
        chmod +x "$out/run.sh"
      ''
    else if lib.hasSuffix ".sh" name then
      pkgs.runCommand "test-${lib.removeSuffix ".sh" name}" {} ''
        mkdir -p "$out"
        install -Dm755 ${./test + "/${name}"} "$out/run.sh"
      ''
    else
      null;

  testDir = builtins.readDir ./test;

  # attrset: testName -> drv with run.sh
  testDrvs =
    lib.mapAttrs' (n: v:
      lib.nameValuePair (lib.removeSuffix ".sh" n) v
    ) (lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (n: t: mkTestDrv n t) testDir));

  hemar = self.packages.${system}.hemar-parser;
  mkPgTest = testName: testDrv: pkgs.runCommand "hemar-test-${testName}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    buildInputs = [ hemar pkgs.yq-go pkgs.which ];
  } ''
        . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
    test=${testDrv}
    ${builtins.readFile ./lauch.sh}

    # success marker for Nix
    # shellcheck disable=SC2154
    mkdir -p "$out"
  '';
in lib.mapAttrs (name: drv: mkPgTest name drv) testDrvs
