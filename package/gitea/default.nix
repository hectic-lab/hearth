{
  lib,
  buildGo126Module,
  makeWrapper,
  writeShellScriptBin,
  git,
  bash,
  coreutils,
  gzip,
  nodejs,
  openssh,
  fetchurl,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  stdenv,
  sqliteSupport ? true,
  nixosTests,
}:

let
  pname = "gitea";
  version = "1.27.3";
  src = ./source;
  pnpm = pnpm_10.overrideAttrs (_: {
    version = "11.9.0";
    src = fetchurl {
      url = "https://registry.npmjs.org/pnpm/-/pnpm-11.9.0.tgz";
      hash = "sha256-K1Z6pmAmI4B4rC4KM77D/r1g6WKYeqxpdFbzGAgZsoc=";
    };
    postPatch = ''
      chmod +x bin/pnpm.cjs bin/pnpx.cjs
    '';
  });
  pnpmForNix = (writeShellScriptBin "pnpm" ''
    if [ "''${1-}" = config ] && [ "''${2-}" = set ] && [ "''${3-}" = manage-package-manager-versions ]; then
      exit 0
    fi
    exec ${pnpm}/bin/pnpm "$@"
  '').overrideAttrs (_: {
    version = "11.9.0";
  });
  pnpmPreInstall = ''
    export NODE_OPTIONS=--dns-result-order=ipv4first
  '';

  frontend = stdenv.mkDerivation {
    pname = "gitea-frontend";
    inherit src version;

    pnpmDeps = fetchPnpmDeps {
      pname = "gitea-frontend";
      inherit version src;
      pnpm = pnpmForNix;
      fetcherVersion = 3;
      prePnpmInstall = pnpmPreInstall;
      hash = "sha256-rXJmmnaA61YoN7xrmA18MBLFpRRMhWd4gwXGVd5eKpU=";
    };

    prePnpmInstall = pnpmPreInstall;

    nativeBuildInputs = [
      nodejs
      pnpmConfigHook
      pnpmForNix
    ];

    buildPhase = ''
      make frontend
    '';

    installPhase = ''
      mkdir -p $out
      cp -R public $out/
    '';
  };
in
buildGo126Module rec {
  inherit pname version src;

  proxyVendor = true;
  vendorHash = "sha256-YRBMGWKIZgMxOXaXG2bIBj1XzkhSwiMyfRy+yQGw+Bo=";

  outputs = [
    "out"
    "data"
  ];

  patches = [ ./static-root-path.patch ];

  overrideModAttrs = _: {
    postPatch = ''
      substituteInPlace go.mod \
        --replace-fail "go 1.26.4" "go 1.26"
    '';
  };

  postPatch = ''
    substituteInPlace modules/setting/server.go --subst-var data
    substituteInPlace go.mod \
      --replace-fail "go 1.26.4" "go 1.26"
  '';

  subPackages = [ "." ];

  nativeBuildInputs = [ makeWrapper ];

  tags = lib.optionals sqliteSupport [
    "sqlite"
    "sqlite_unlock_notify"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
    "-X 'main.Tags=${lib.concatStringsSep " " tags}'"
  ];

  postInstall = ''
    mkdir $data
    ln -s ${frontend}/public $data/public
    cp -R ./{templates,options} $data
    mkdir -p $out
    cp -R ./options/locale $out/locale

    wrapProgram $out/bin/gitea \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          git
          gzip
          openssh
        ]
      }
  '';

  passthru = {
    tests = nixosTests.gitea;
  };

  meta = {
    description = "Git with a cup of tea";
    homepage = "https://about.gitea.com";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      techknowlogick
      SuperSandro2000
    ];
    mainProgram = "gitea";
  };
}
