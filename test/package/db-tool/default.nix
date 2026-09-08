{ inputs, self, pkgs, system, ... }: let
  lib = inputs.nixpkgs.lib;

  # turn anything under test directory into a derivation that exposes $out/run.sh
  mkTestDrv = folder: name: type:
    if type == "directory" then
      pkgs.runCommand "test-${name}" {} ''
        if ! [ -f ${"${folder}/${name}/run.sh"} ]; then
          echo no run.sh in test/${name}
          exit 1
        fi

        mkdir -p "$out"
        cp -r ${"${folder}/${name}"}/* "$out/"
        chmod +x "$out/run.sh"
      ''
    else if lib.hasSuffix ".sh" name then
      pkgs.runCommand "test-${lib.removeSuffix ".sh" name}" {} ''
        mkdir -p "$out"
        install -Dm755 ${"${folder}/${name}"} "$out/run.sh"
      ''
    else
      null;

  testDir = folder: builtins.readDir folder;

  # attrset: testName -> drv with run.sh
  testDrvs = folder:
    lib.mapAttrs' (n: v:
      lib.nameValuePair (lib.removeSuffix ".sh" n) v
    ) (lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (n: t: mkTestDrv folder n t) (testDir folder)));

  database       = self.packages.${system}."db-dev";
  dbOps          = self.packages.${system}."db-ops";
  postgresInit   = self.packages.${system}."postgres-init";
  postgresCleanup = self.packages.${system}."postgres-cleanup";

  # Non-postgres tests: .sh files at ./test/ (excluding postgresql/ subdir)
  nonPgTestDrvs =
    lib.mapAttrs' (n: v: lib.nameValuePair (lib.removeSuffix ".sh" n) v)
      (lib.filterAttrs (_: v: v != null)
        (lib.mapAttrs (n: t: mkTestDrv ./test n t)
          (lib.filterAttrs (n: _: n != "postgresql") (testDir ./test))));

  # Postgres tests: subdirs at ./test/postgresql/
  pgTestDrvs = testDrvs ./test/postgresql;

  mkNonPgTest = testName: testDrv: pkgs.runCommand "db-tool-${testName}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    buildInputs       = [ database dbOps postgresInit postgresCleanup pkgs.postgresql_17 pkgs.dash ];
  } ''
        . ${self.legacyPackages.${system}.helpers.posix-shell.log}
    test=${testDrv}
    export HECTIC_LOG=trace
    set -eu

    # shellcheck disable=SC1090
    . "$test/run.sh"

    mkdir -p "$out"
  '';

  mkPgTest = testName: testDrv: pkgs.runCommand "db-tool-${testName}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    buildInputs       = [ database dbOps postgresInit postgresCleanup pkgs.postgresql_17 pkgs.dash pkgs.netcat-openbsd ];
  } ''
        . ${self.legacyPackages.${system}.helpers.posix-shell.log}
    test=${testDrv}
    export HECTIC_LOG=trace
    set -eu
    ${builtins.readFile ./postgresql/_lib.sh}

    # shellcheck disable=SC1090
    . "$test/run.sh"

    mkdir -p "$out"
  '';
in
  (lib.mapAttrs (name: drv: mkNonPgTest name drv) nonPgTestDrvs) //
  (lib.mapAttrs (name: drv: mkPgTest name drv) pgTestDrvs)
