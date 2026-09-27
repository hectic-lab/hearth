{
  lib,
  buildGo126Module,
  makeWrapper,
  git,
  bash,
  coreutils,
  gzip,
  nodejs,
  openssh,
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
  pnpm = pnpm_10;
  pnpmPatches = [ ./pnpm-engine.patch ];

  frontend = stdenv.mkDerivation {
    pname = "gitea-frontend";
    inherit src version;
    patches = pnpmPatches;

    pnpmDeps = fetchPnpmDeps {
      pname = "gitea-frontend";
      inherit version src;
      inherit pnpm;
      patches = pnpmPatches;
      fetcherVersion = 3;
      prePnpmInstall = ''
        pnpm config set engine-strict false
      '';
      hash = "sha256-H1sNMKRkoPlkheJFJVaof4bJ4gQHnbhosJaUqj9X8Gg=";
    };

    nativeBuildInputs = [
      nodejs
      pnpmConfigHook
      pnpm
    ];

    prePnpmInstall = ''
      pnpm config set engine-strict false
    '';

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
  deleteVendor = true;
  vendorHash = "sha256-YRBMGWKIZgMxOXaXG2bIBj1XzkhSwiMyfRy+yQGw+Bo=";

  outputs = [
    "out"
    "data"
  ];

  patches = [ ./static-root-path.patch ];

  postPatch = ''
    substituteInPlace modules/setting/server.go --subst-var data
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
    mv "$out/bin/gitea.dev" "$out/bin/gitea"
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
