{ system, inputs, self, pkgs }:
  (import ./migrator      { inherit system inputs self pkgs; }) //
  (import ./hemar         { inherit system inputs self pkgs; }) //
  (import (./. + "/sentinèlla") { inherit system inputs self pkgs; }) //
  (import ./db-tool       { inherit system inputs self pkgs; }) //
  (import ./with-attic-cache { inherit system inputs self pkgs; }) //
  (import ./element-web   { inherit system inputs self pkgs; }) //
  (import ./linux-devshell { inherit system inputs self pkgs; }) //
  (import ./windows-devshell { inherit system inputs self pkgs; })
