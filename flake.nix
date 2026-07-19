{
  description = "yukkop's nix utilities";

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://cache.hectic-lab.com/hectic"
    ];
    extra-trusted-public-keys = [
      "hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixvim = {
      url = "github:nix-community/nixvim/nixos-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-mailserver = {
      url = "gitlab:simple-nixos-mailserver/nixos-mailserver/snm-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-minecraft.url = "github:Infinidoge/nix-minecraft";
    hectic-landing = {
      # NOTE(yukkop): private repo - SSH access required.
      # Only evaluated when nixosConfigurations."hectic-lab|x86_64-linux" is built.
      url = "git+ssh://git@github.com/liquizz/hectic-landing.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mechabellum-replay-analysis = {
      # NOTE(yukkop): private repo - SSH access required.
      # Only evaluated when nixosConfigurations."hectic-lab|x86_64-linux" is built.
      url = "git+ssh://git@github.com/LysmiMx/mechabellum-replay-analysis.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    ...
  }@inputs: let
    flake    = ./.;
    self-lib = import ./lib { inherit flake self inputs; };
    
    # Create overlay that includes legacy packages
    overlayWithLegacy = system: final: prev: 
      let
        baseOverlay = (import ./overlay { inherit flake self inputs nixpkgs; }) final prev;
        legacyPackages = import ./legacy { inherit system pkgs self; };
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
      in
        baseOverlay // legacyPackages;
    
    overlays = [ self.overlays.default ];
  in self-lib.forAllSystemsWithPkgs ([(import rust-overlay)] ++ overlays) ({
    system,
    pkgs,
  }: {
    packages.${system}         = import ./package            { inherit flake self inputs pkgs system; };
    devShells.${system}        = import ./devshell           { inherit flake self inputs pkgs system; };
    legacyPackages.${system}   = import ./legacy             { inherit flake self inputs pkgs system; };
    checks.${system}           = import ./test               { inherit flake self inputs pkgs system; };
  }) // {
    lib = self-lib;
    overlays.default           = import ./overlay            { inherit flake self inputs; };
    nixosModules               = import ./nixos/module       { inherit flake self inputs; };
    templates                  = import ./template           { inherit flake self inputs; };
    nixosConfigurations = {
      # NOTE(yukkop): in bfs one of dependencies is shadow-4.17.4 that
      # unsupported on aarch64-darwin
      "bfs.netherland.xray|x86_64-linux" = import ./nixos/system/bfs.netherland.xray { inherit flake self inputs; system = "x86_64-linux"; };
      "bfs.poland.xray|x86_64-linux"     = import ./nixos/system/bfs.poland.xray     { inherit flake self inputs; system = "x86_64-linux"; };
      # FIXME(yukkop): some why I cannot merge nixosConfigurations from `forAllSystemsWithPkgs` with this 
      "neuro|x86_64-linux"     = import ./nixos/system/neuro       { inherit flake self inputs; system = "x86_64-linux"; };
      "games|x86_64-linux"     = import ./nixos/system/games       { inherit flake self inputs; system = "x86_64-linux"; };
      "wsl|x86_64-linux"        = import ./nixos/system/wsl         { inherit flake self inputs; system = "x86_64-linux"; };
      "tenix|x86_64-linux"      = import ./nixos/system/tenix       { inherit flake self inputs; system = "x86_64-linux"; };
      "hectic-lab|x86_64-linux" = import ./nixos/system/hectic-lab  { inherit flake self inputs; system = "x86_64-linux"; };
    };
    darwinConfigurations = {
      "yukkop|aarch64-darwin" = import ./darwin/system/yukkop { inherit flake self inputs; system = "aarch64-darwin"; };
    };
  };
}
