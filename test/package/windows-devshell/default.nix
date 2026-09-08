{ system, inputs, self, pkgs }:
let
  lib = inputs.nixpkgs.lib;

  windowsDevShellStandalone = self.packages.${system}.windows-devshell-standalone;

  mkTest = testName: testDrv: pkgs.runCommand "windows-devshell-test-${testName}"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
      windowsDevShellStandalone = windowsDevShellStandalone;
    } ''
      . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
      test=${testDrv}
      ${builtins.readFile ./launch.sh}
      mkdir -p "$out"
    '';

  testDir  = builtins.readDir ./test;
  testDrvs =
    lib.mapAttrs' (n: v:
      lib.nameValuePair (lib.removeSuffix ".sh" n) v
    ) (lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (n: t:
        if t == "directory" then
          pkgs.runCommand "test-${n}" {} ''
            if ! [ -f ${./test + "/${n}" + /run.sh} ]; then
              echo "no run.sh in test/${n}"
              exit 1
            fi
            mkdir -p "$out"
            cp -r ${./test + "/${n}"}/* "$out/"
            chmod +x "$out/run.sh"
          ''
        else if lib.hasSuffix ".sh" n then
          pkgs.runCommand "test-${lib.removeSuffix ".sh" n}" {} ''
            mkdir -p "$out"
            install -Dm755 ${./test + "/${n}"} "$out/run.sh"
          ''
        else
          null
      ) testDir));

in
  (lib.mapAttrs' (name: drv: lib.nameValuePair "windows-${name}" (mkTest "windows-${name}" drv)) testDrvs)
