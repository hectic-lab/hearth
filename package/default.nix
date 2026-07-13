{ self, pkgs, inputs, ... }: let
  rust = {
    nativeBuildInputs = [
      pkgs.pkgsBuildHost.rust-bin.stable."1.81.0".default
      pkgs.pkg-config
    ];
    commonArgs = {
      inherit (self.lib) cargoToml;
      inherit (rust) nativeBuildInputs;
    };
  };
  buildPostgresqlExtension =
    pkgs: pkgs.callPackage (import (builtins.path {
      name = "extension-builder";
      path = ./buildPostgresqlExtension.nix;
    }));
  buildPgrxExtension = pkgs: 
    pkgs.callPackage (import (builtins.path {
      name = "extension-builder";
      path = ./buildPgrxExtension.nix;
    })) { 
      cargo-pgrx = pkgs.cargo-pgrx_0_12_6;
      inherit (pkgs.darwin.apple_sdk.frameworks) Security;
    };

  buildSmtpExt = pkgs: versionSuffix: let
    postgresql = pkgs."postgresql_${versionSuffix}";
    src = pkgs.fetchFromGitHub {
      owner = "brianpursley";
      repo = "pg_smtp_client";
      rev = "6ff3b71e3705e0d4081a51c21ca0379e869ba5fb";
      hash = "sha256-wC/2rAsSDO83UITaFhtaf3do3aaOAko4gnKUOzwURc8=";
    };
    cargo = self.lib.cargoToml src;
  in
    buildPgrxExtension pkgs {
      pname = cargo.package.name;
      version = cargo.package.version;
  
      inherit src postgresql;
  
      buildInputs = with pkgs; [ openssl ];

      cargoHash = "sha256-Cg5qY4TKkSJRSAtlFbjIRhea0dXPLEyasi5n09HcYeo=";
  
      doCheck = false;
    };
  buildPlShExt = pkgs: versionSuffix: let
      version = "4.0"; 
    in buildPostgresqlExtension pkgs {
      stdenv = pkgs.clangStdenv;
      postgresql = pkgs."postgresql_${versionSuffix}";
    } {
      pname = "plsh";
      inherit version;
      src = pkgs.fetchFromGitHub {
        owner = "petere";
        repo = "plsh";
        rev = "d88079617309974f71b3f8e4d5f96869dba66835";
        hash = "sha256-H9B5L+yIjjVNhnuF+bIZKyCrOqfIvu5W26aqyqL5UdQ=";
      };
      nativeBuildInputs = with pkgs; [ pkg-config ];
    };
  buildPlHaskellExt = pkgs: versionSuffix: let
      version = "4.0"; 
    in buildPostgresqlExtension pkgs {
      stdenv = pkgs.clangStdenv;
      postgresql = pkgs."postgresql_${versionSuffix}";
    } {
      pname = "plhaskell";
      inherit version;
      src = pkgs.fetchFromGitHub {
        owner = "ed-o-saurus";
        repo = "PLHaskell";
        rev = "d917f0991a455cf0558c2036e360ba1a9b40a8ef";
        hash = "sha256-+sJmR/SCMfxxExa7GZuNmWez1dfhvlM9qOdO9gHNf74=";
      };
      preBuild = ''
        last=$(pwd)
        cd ${pkgs.haskellPackages.ghc}
        include=$(dirname "${pkgs.haskellPackages.ghc}/$(find . -name HsFFI.h)")
        ls $include
        cd $last
        export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I$include"
      '';
      nativeBuildInputs = with pkgs; [
        pkg-config
        curl
        ghc
        haskellPackages.hsc2hs
        haskellPackages.ghc 
      ];
    };
  buildHttpExt = pkgs: versionSuffix: let
      version = "1.6.1";
    in buildPostgresqlExtension pkgs {
      stdenv = pkgs.clangStdenv;
      postgresql = pkgs."postgresql_${versionSuffix}";
    } {
      pname = "http";
      inherit version;
      src = pkgs.fetchFromGitHub {
        owner = "pramsey";
        repo = "pgsql-http";
        rev = "v${version}";
        hash = "sha256-C8eqi0q1dnshUAZjIsZFwa5FTYc7vmATF3vv2CReWPM=";
    };
    nativeBuildInputs = with pkgs; [pkg-config curl];
  };
  dbToolPkgs = pkgs.callPackage ./db-tool { inherit self; };
  linuxDevShellPkgs = pkgs.callPackage ./linux-devshell {};
  windowsDevShellPkgs = pkgs.callPackage ./windows-devshell {
    inherit (linuxDevShellPkgs) linux-devshell-standalone;
  };
in {
  py3-datetime                 = pkgs.callPackage ./py3-datetime.nix                  {};
  py3-marzban                  = pkgs.callPackage ./py3-marzban.nix                   { inherit self; };
  py3-asyncpayments            = pkgs.callPackage ./py3-asyncpayments.nix             {};
  py3-payok                    = pkgs.callPackage ./py3-payok.nix                     {};
  py3-asyncio                  = pkgs.callPackage ./py3-asyncio.nix                   {};
  py3-cryptomus                = pkgs.callPackage ./py3-cryptomus.nix                 {};
  py3-modulegraph              = pkgs.callPackage ./py3-modulegraph.nix               {};
  py3-swifter                  = pkgs.callPackage ./py3-swifter.nix                   {};
  py3-aiogram-newsletter       = pkgs.callPackage ./py3-aiogram-newsletter.nix        {};
  py3-openai-shap-e            = pkgs.callPackage ./py3-openai-shap-e.nix             {};
  hiddify-core                 = pkgs.callPackage ./hiddify-core                      {};
  nvim-alias                   = pkgs.callPackage ./nvim-alias.nix                    {};
  bolt-unpack                  = pkgs.callPackage ./bolt-unpack.nix                   {};
  merge-archive                = pkgs.callPackage ./merge-archive                     {};
  nvim-pager                   = pkgs.callPackage ./nvim-pager.nix                    {};
  colorize                     = pkgs.callPackage ./colorize.nix                      {};
  github-gh-tl                 = pkgs.callPackage ./github/gh-tl.nix                  {};
  supabase-with-env-collection = pkgs.callPackage ./supabase-with-env-collection.nix  {};
  migration-name               = pkgs.callPackage ./migration-name.nix                {};
  plgo                         = pkgs.callPackage ./plgo                              {};
  pg-from                      = pkgs.callPackage ./postgres/pg-from/default.nix      rust.commonArgs;
  pg-schema                    = pkgs.callPackage ./postgres/pg-schema/default.nix    rust.commonArgs;
  pg_wdumpall                  = pkgs.callPackage ./postgres/pg_wdumpall.nix          rust.commonArgs; 
  pg_wdump                     = pkgs.callPackage ./postgres/pg_wdump.nix             rust.commonArgs; 
  pg-migration                 = pkgs.callPackage ./postgres/pg-migration/default.nix rust.commonArgs;
  slpt                         = pkgs.callPackage ./slpt.nix                          {};
  c-hectic                     = pkgs.callPackage ./c/hectic/default.nix              {};
  watch                        = pkgs.callPackage ./c/watch/default.nix               {};
  support-bot                  = pkgs.callPackage ./support-bot                       {};
  gitea-heatmap                = pkgs.callPackage ./gitea                             {};
  gitea-runner-nix-image       = pkgs.callPackage ./gitea-runner-nix-image            {};
  nix-derivation-hash          = pkgs.callPackage ./nix-derivation-hash               {};
  "sentinèlla"                 = pkgs.callPackage (./. + "/sentinèlla")               {};
  deploy                       = pkgs.callPackage ./deploy                            { inherit inputs; };
  element-web                  = pkgs.callPackage ./element-web                       {};
  shellplot                    = pkgs.callPackage ./shellplot                         {};
  onlinepubs2man               = pkgs.callPackage ./onlinepubs2man                    {};
  migrator                     = pkgs.callPackage ./migrator                          { inherit self; };
  "parse-uri"                  = pkgs.callPackage ./parse-uri                        {};
  "db-dev"                     = dbToolPkgs."db-dev";
  "db-ops"                     = dbToolPkgs."db-ops";
  "postgres-init"              = dbToolPkgs."postgres-init";
  "postgres-cleanup"           = dbToolPkgs."postgres-cleanup";
  "hectic-inheritance"         = dbToolPkgs."hectic-inheritance";
  "linux-devshell"             = linuxDevShellPkgs.linux-devshell;
  "linux-devshell-standalone"  = linuxDevShellPkgs.linux-devshell-standalone;
  "windows-devshell-standalone" = windowsDevShellPkgs.windows-devshell-standalone;
  nbt2json                     = pkgs.callPackage ./nbt2json                          {};
  hemar-parser                 = pkgs.callPackage ./hemar/parser                      {};
  AstroTuxLauncher              = pkgs.callPackage ./AstroTuxLauncher.nix             {};
  pg-17-ext-http               = buildHttpExt      pkgs "17";
  pg-17-ext-smtp-client        = buildSmtpExt      pkgs "17";
  pg-17-ext-plhaskell          = buildPlHaskellExt pkgs "17";
  pg-17-ext-plsh               = buildPlShExt      pkgs "17";
  pg-16-ext-http               = buildHttpExt      pkgs "16";
  pg-16-ext-smtp-client        = buildSmtpExt      pkgs "16";
  pg-16-ext-plhaskell          = buildPlHaskellExt pkgs "16";
  pg-16-ext-plsh               = buildPlShExt      pkgs "16";
  pg-15-ext-http               = buildHttpExt      pkgs "15";
  pg-15-ext-smtp-client        = buildSmtpExt      pkgs "15";
  pg-15-ext-plhaskell          = buildPlHaskellExt pkgs "15";
  pg-15-ext-plsh               = buildPlShExt      pkgs "15";
  stable-video-diffusion-api   = pkgs.callPackage ./stable-video-diffusion-api {};
  media-browser                = pkgs.callPackage ./media-browser {};
}
