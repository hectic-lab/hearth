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

  postgresqlTestDrvs = testDrvs ./test/postgresql;
  sqliteTestDrvs     = testDrvs ./test/sqlite;

  migrator = self.packages.${system}.migrator;
  
  mkPgTest = testName: testDrv: pkgs.runCommand "migrator-test-${testName}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    buildInputs       = [ pkgs.which migrator pkgs.postgresql ];
  } ''
        . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
    test=${testDrv}
    export HECTIC_LOG=trace
    ${builtins.readFile ./util.sh}
    ${builtins.readFile ./lauch-postgresql.sh}

    # success marker for Nix
    # shellcheck disable=SC2154
    mkdir -p "$out"
  '';

  mkSqliteTest = testName: testDrv: pkgs.runCommand "migrator-test-${testName}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    buildInputs       = [ pkgs.which migrator pkgs.sqlite ];
  } ''
        . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
    test=${testDrv}
    export HECTIC_LOG=trace
    ${builtins.readFile ./util.sh}
    ${builtins.readFile ./lauch-sqlite.sh}

    # success marker for Nix
    # shellcheck disable=SC2154
    mkdir -p "$out"
  '';
in (lib.mapAttrs (name: drv: mkPgTest name drv) postgresqlTestDrvs) // (lib.mapAttrs (name: drv: mkSqliteTest name drv) sqliteTestDrvs)
