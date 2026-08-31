{ system, inputs, self, pkgs, flake }:
  (import ./package { inherit system inputs self pkgs; }) //
  (import ./nixos { inherit system inputs self pkgs flake; })
