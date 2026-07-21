{
  pkgs,
  lib,
  ...
}: let
  name = "yukkop";
in {
  nix.settings.experimental-features = "nix-command flakes";

  programs.zsh.enable = true;

  services.openssh.enable = true;

  users.users.${name} = {
    home = "/Users/${name}";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJf9ljuqny71bZJokebK4Ybfml0MFMCkApS+tbMdBudp u0_a472@localhost"
    ];
  };

  environment.systemPackages = with pkgs; [
    aerospace
    git
    neovim
    tmux
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.users.${name} = {
    home.stateVersion = "25.11";

    home.packages = with pkgs; [
      iproute2mac
      jujutsu
    ];

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

      initContent = ''
        export PATH=/Users/yukkop/.opencode/bin:$PATH
      '';
    };

    programs.tmux = {
      enable = true;
      keyMode = "vi";
      escapeTime = 500;
      historyLimit = 50000;
      newSession = true;
    };

    xdg.configFile."aerospace/aerospace.toml".text = ''
      start-at-login = true

      enable-normalization-flatten-containers = true
      enable-normalization-opposite-orientation-for-nested-containers = true

      default-root-container-layout = 'tiles'
      default-root-container-orientation = 'auto'
      accordion-padding = 30

      on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
      automatically-unhide-macos-hidden-apps = false

      [exec]
        inherit-env-vars = true

      [exec.env-vars]
        PATH = '/run/current-system/sw/bin:/etc/profiles/per-user/yukkop/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:''${PATH}'

      [gaps]
        inner.horizontal = 8
        inner.vertical = 8
        outer.left = 8
        outer.bottom = 8
        outer.top = 8
        outer.right = 8

      [mode.main.binding]
        alt-enter = 'exec-and-forget open -n /System/Applications/Utilities/Terminal.app'

        alt-slash = 'layout tiles horizontal vertical'
        alt-comma = 'layout accordion horizontal vertical'
        alt-f = 'fullscreen'

        alt-h = 'focus left'
        alt-j = 'focus down'
        alt-k = 'focus up'
        alt-l = 'focus right'

        alt-shift-h = 'move left'
        alt-shift-j = 'move down'
        alt-shift-k = 'move up'
        alt-shift-l = 'move right'

        alt-minus = 'resize smart -50'
        alt-equal = 'resize smart +50'

        alt-1 = 'workspace 1'
        alt-2 = 'workspace 2'
        alt-3 = 'workspace 3'
        alt-4 = 'workspace 4'
        alt-5 = 'workspace 5'
        alt-6 = 'workspace 6'
        alt-7 = 'workspace 7'
        alt-8 = 'workspace 8'
        alt-9 = 'workspace 9'

        alt-shift-1 = 'move-node-to-workspace 1'
        alt-shift-2 = 'move-node-to-workspace 2'
        alt-shift-3 = 'move-node-to-workspace 3'
        alt-shift-4 = 'move-node-to-workspace 4'
        alt-shift-5 = 'move-node-to-workspace 5'
        alt-shift-6 = 'move-node-to-workspace 6'
        alt-shift-7 = 'move-node-to-workspace 7'
        alt-shift-8 = 'move-node-to-workspace 8'
        alt-shift-9 = 'move-node-to-workspace 9'

        alt-tab = 'workspace-back-and-forth'
        alt-shift-tab = 'move-workspace-to-monitor --wrap-around next'

        alt-shift-semicolon = 'mode service'

      [mode.service.binding]
        esc = ['reload-config', 'mode main']
        r = ['flatten-workspace-tree', 'mode main']
        f = ['layout floating tiling', 'mode main']
        b = ['balance-sizes', 'mode main']
        backspace = ['close-all-windows-but-current', 'mode main']

        alt-shift-h = ['join-with left', 'mode main']
        alt-shift-j = ['join-with down', 'mode main']
        alt-shift-k = ['join-with up', 'mode main']
        alt-shift-l = ['join-with right', 'mode main']
    '';
  };
  system.stateVersion = 6;
}
