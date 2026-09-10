{ inputs, self, pkgs, system, ... }:
if !pkgs.stdenv.hostPlatform.isLinux then {} else let
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

  withAtticCache = self.packages.${system}.with-attic-cache;

  mkTest = testName: testDrv: pkgs.runCommand "with-attic-cache-test-${testName}"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.dash
        pkgs.gnugrep
        pkgs.gnused
        pkgs.util-linux
        withAtticCache
      ];
    } ''
      test=${testDrv}
      ${builtins.readFile ./launch.sh}
      mkdir -p "$out"
    '';

  timeBudgets = pkgs.runCommand "with-attic-cache-time-budgets"
    {
      nativeBuildInputs = [
        (pkgs.python3.withPackages (p: [ p.pyyaml ]))
        pkgs.dash
      ];
      DASH = "${pkgs.dash}/bin/dash";
      WORKFLOW_FILE = ../../../.gitea/workflows/deploy-neuro.yaml;
      DECIDE_SH = ../../../package/gitea-runner-controller/decide.sh;
      CONTROLLER_SH = ../../../package/gitea-runner-controller/controller.sh;
      HCLOUD_SH = ../../../package/gitea-runner-controller/hcloud.sh;
      GCR_GITEA_URL = "https://example.invalid";
      GCR_NIX_VERSION = "2.24.0";
      GCR_NIX_TARBALL_SHA256 = "dummy-x86-nix-sha256";
      GCR_ARM_NIX_TARBALL_SHA256 = "dummy-arm-nix-sha256";
      GCR_ACT_RUNNER_VERSION = "0.2.11";
      GCR_ACT_RUNNER_SHA256 = "dummy-runner-sha256";
      GITEA_WATCHDOG = self.nixosConfigurations."hectic-lab|x86_64-linux".config.services.gitea.settings.actions.ENDLESS_TASK_TIMEOUT;
    } ''
      python ${./time-budgets.py}
      mkdir -p "$out"
    '';

  discoveredTests = lib.mapAttrs' (name: drv:
    lib.nameValuePair "with-attic-cache-${name}" (mkTest name drv)
  ) testDrvs;
in discoveredTests // {
  with-attic-cache-time-budgets = timeBudgets;
}
