{ inputs, self, ... }: let
  lib = inputs.nixpkgs.lib;
in final: prev: (
  let
    packages = self.packages.${prev.stdenv.hostPlatform.system};
    legacyPackages = self.legacyPackages.${prev.stdenv.hostPlatform.system};
  in {
    hectic = packages // legacyPackages;
    p4d = if final.stdenv.hostPlatform.system == "x86_64-linux" then prev.p4d.overrideAttrs (_: {
      version = "2023.1/2797325";
      src = final.fetchurl {
        url = "https://ftp.perforce.com/pub/perforce/r23.1/bin.linux26x86_64/helix-core-server.tgz";
        hash = "sha256-O8znAlq2XjrixG0FA4cfkgcI9t/w9QMHV0spUjYKl48=";
      };
    }) else prev.p4d;
    p4 = prev.p4.overrideAttrs (_: {
      version = "2024.1/3006289";
      src = final.fetchurl {
        url = "https://ftp.perforce.com/pub/perforce/r24.1/bin.tools/p4source.tgz";
        hash = "sha256-z3I3cikbbSrmS7dUMMKi6edPnZk2BYAmdO+pfYRJUVQ=";
      };
    });
    postgresql_17 = prev.postgresql_17 // {pkgs = prev.postgresql_17.pkgs // {
      http = packages.pg-17-ext-http;
      pg_smtp_client = packages.pg-17-ext-smtp-client;
      plhaskell = packages.pg-17-ext-plhaskell;
      plsh = packages.pg-17-ext-plsh;
      hemar = packages.pg-17-ext-hemar;
    };};
    postgresql_16 = prev.postgresql_16 // {pkgs = prev.postgresql_16.pkgs // {
      http = packages.pg-16-ext-http;
      pg_smtp_client = packages.pg-16-ext-smtp-client;
      plhaskell = packages.pg-16-ext-plhaskell;
      plsh = packages.pg-16-ext-plsh;
      hemar = packages.pg-16-ext-hemar;
    };};
    postgresql_15 = prev.postgresql_15 // {pkgs = prev.postgresql_15.pkgs // {
      http = packages.pg-15-ext-http;
      pg_smtp_client = packages.pg-15-ext-smtp-client;
      plhaskell = packages.pg-15-ext-plhaskell;
      plsh = packages.pg-15-ext-plsh;
      hemar = packages.pg-15-ext-hemar;
    };};
  }
)
