{
  inputs,
  flake,
  self,
}: {
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.hectic.program.tmux;
in {
  imports = [
    inputs.home-manager.nixosModules.home-manager
  ];

  options.hectic.program.tmux.enable = lib.mkEnableOption "Enable hectic tmux config";

  config = lib.mkIf cfg.enable {
    programs.tmux.enable   = true;
    programs.tmux.terminal = lib.mkOverride 50 "tmux-256color";

    # alias depends on newSession = true (auto-creates session on attach)
    programs.zsh.shellAliases.tmux = "tmux a";
    programs.bash.shellAliases.tmux = "tmux a";

    home-manager.sharedModules = [
      (flake + "/home/module/program/tmux.nix")
    ];

    home-manager.users.root.home.stateVersion = lib.mkDefault "25.05";
  };
}
