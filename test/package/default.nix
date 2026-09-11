{ system, inputs, self, pkgs }:
let
  smtpPackages = map
    (version: self.packages.${system}."pg-${version}-ext-smtp-client")
    [ "15" "16" "17" ];
in
  (import ./migrator      { inherit system inputs self pkgs; }) //
  (import ./hemar         { inherit system inputs self pkgs; }) //
  (import (./. + "/sentinèlla") { inherit system inputs self pkgs; }) //
  (import ./gitea-runner-controller { inherit system inputs self pkgs; }) //
  (import ./db-tool       { inherit system inputs self pkgs; }) //
  (import ./with-attic-cache { inherit system inputs self pkgs; }) //
  (import ./element-web   { inherit system inputs self pkgs; }) //
  (import ./linux-devshell { inherit system inputs self pkgs; }) //
  (import ./windows-devshell { inherit system inputs self pkgs; }) //
  {
    pg-smtp-client-metadata =
      assert builtins.all (package: package.pname == "pg_smtp_client") smtpPackages;
      assert builtins.all (package: package.version == "0.2.0") smtpPackages;
      pkgs.runCommand "pg-smtp-client-metadata" {} ''
        touch "$out"
      '';
  }
