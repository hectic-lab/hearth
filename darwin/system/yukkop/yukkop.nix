{
  pkgs,
  lib,
  ...
}: let
  name = "yukkop";
in {
  nix.settings.experimental-features = "nix-command flakes";

  programs.zsh.enable = true;

  users.users.${name}.home = "/Users/${name}";

  environment.systemPackages = with pkgs; [
    git
    neovim
    tmux
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.${name} = {
    home.stateVersion = "25.11";

    programs.git = {
      enable = true;
      lfs.enable = true;
      settings = {
        user.name = name;
        user.email = "hectic.yukkop@gmail.com";
        push.autoSetupRemote = true;
        init.defaultBranch = "master";
      };
    };

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      history = {
        size = 10000;
        path = "$HOME/.zsh/.zsh_history";
      };

      shellAliases = {
        drs = "darwin-rebuild switch --flake ~/pj/hearth#'yukkop|aarch64-darwin'";
        nv = "nvim";
      };
    };

    programs.tmux = {
      enable = true;
      keyMode = "vi";
      escapeTime = 500;
      historyLimit = 50000;
      newSession = true;
    };
  };
  system.stateVersion = 6;
}
