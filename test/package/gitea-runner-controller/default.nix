{ inputs, self, pkgs, system, ... }:
let
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

  mkTest = testName: testDrv: pkgs.runCommand "gitea-runner-controller-test-${testName}"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.dash
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ];
      LOG_SH = ../../../package/gitea-runner-controller/log.sh;
      STATE_SH = ../../../package/gitea-runner-controller/state.sh;
      DECIDE_SH = ../../../package/gitea-runner-controller/decide.sh;
      HCLOUD_SH = ../../../package/gitea-runner-controller/hcloud.sh;
      GITEA_SH = ../../../package/gitea-runner-controller/gitea.sh;
      CONTROLLER_SH = ../../../package/gitea-runner-controller/controller.sh;
      WEBHOOK_SH = ../../../package/gitea-runner-controller/webhook.sh;
    } ''
      test=${testDrv}
      ${builtins.readFile ./launch.sh}
      mkdir -p "$out"
    '';
in lib.mapAttrs' (name: drv:
  lib.nameValuePair "gitea-runner-controller-${name}" (mkTest name drv)
) testDrvs
