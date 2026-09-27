{ system, pkgs, self, ... }: 
(import ./dev { inherit self system pkgs; }) 
// {
  c          = import ./c.nix          { inherit self system pkgs; };
  postgres-c = import ./postgres-c.nix { inherit self system pkgs; };
  pure-c     = import ./pure-c.nix     { inherit self system pkgs; };
  rust       = import ./rust.nix       { inherit self system pkgs; };
  ratatui    = import ./ratatui.nix    { inherit self system pkgs; };
  haskell    = import ./haskell.nix    { inherit self system pkgs; };
  neuro      = import ./neuro.nix      { inherit self system pkgs; };
  xmpp       = import ./xmpp.nix       { inherit self system pkgs; };
  gitea-runners = import ./gitea-runners.nix { inherit pkgs; };
  default    = pkgs.mkShell {
    buildInputs =
      (with self.packages.${system}; [
        nvim-alias
        nvim-pager
      ])
      ++ (with pkgs; [
        git
        jq
        yq-go
        curl
        #(writeScriptBin "hemar-check" ''
        #  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null vm-postgres 'zsh -c check'
        #'')
      ]);
  
    # environment
    PAGER = "${self.packages.${system}.nvim-pager}/bin/pager";
  };
}
