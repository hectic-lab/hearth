{ inputs, self, pkgs, system, ... }: let
  lib = inputs.nixpkgs.lib;

  mkTestDrv = name: type:
    if type == "directory" then
      pkgs.runCommand "test-${name}" {} ''
        if ! [ -f ${./test + "/${name}" + /run.sh} ]; then
          echo "no run.sh in test/${name}"
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

  testDir  = builtins.readDir ./test;
  testDrvs =
    lib.mapAttrs' (n: v:
      lib.nameValuePair (lib.removeSuffix ".sh" n) v
    ) (lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (n: t: mkTestDrv n t) testDir));

  sentinella = self.packages.${system}."sentinèlla";

  mkTest = testName: testDrv: pkgs.runCommand "sentinella-test-${testName}"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      buildInputs       = [ sentinella pkgs.curl pkgs.jq pkgs.socat ];
    } ''
      . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
      export HECTIC_LOG=trace
      test=${testDrv}
      ${builtins.readFile ./launch.sh}

      mkdir -p "$out"
    '';
in lib.mapAttrs (name: drv: mkTest name drv) testDrvs
