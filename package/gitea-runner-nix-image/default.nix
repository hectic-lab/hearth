{
  bash,
  cacert,
  coreutils,
  dockerTools,
  git,
  lib,
  nix,
  symlinkJoin,
}:
let
  name = "gitea-runner-nix-image";
  tag = "2026-06-07";
  root = symlinkJoin {
    name = "${name}-root";
    paths = [
      bash
      cacert
      coreutils
      git
      nix
    ];
  };
in
dockerTools.buildLayeredImageWithNixDb {
  inherit name tag;

  contents = [ root ];

  fakeRootCommands = ''
    mkdir -p ./etc
    cat > ./etc/passwd <<'EOF'
    root:x:0:0:root:/root:/bin/bash
    nobody:x:65534:65534:nobody:/var/empty:/bin/false
    EOF
    cat > ./etc/group <<'EOF'
    root:x:0:
    nixbld:x:30000:
    nobody:x:65534:
    EOF
    for n in $(seq 1 10); do
      echo "nixbld$n:x:$((30000 + n)):30000:Nix build user $n:/var/empty:/bin/false" >> ./etc/passwd
      sed -i "s/^nixbld:x:30000:.*/&,nixbld$n/" ./etc/group
    done

    mkdir -p ./nix/var/nix/{gcroots,profiles,temproots,userpool,db}
    mkdir -p ./nix/var/log/nix/drvs
    chmod 1777 ./nix/var/nix/gcroots ./nix/var/nix/profiles
  '';

  extraCommands = ''
    mkdir -p etc/nix root tmp
    chmod 1777 tmp

    cat > etc/nix/nix.conf <<'EOF'
    accept-flake-config = true
    experimental-features = nix-command flakes
    substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
    http2 = false
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
    trusted-users = root
    sandbox = false
    EOF
  '';

  config = {
    Cmd = [ "${bash}/bin/bash" ];
    Env = [
      "HOME=/root"
      "PATH=${lib.makeBinPath [ bash coreutils git nix ]}"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "USER=root"
    ];
    Labels = {
      "org.opencontainers.image.description" = "Nix-capable Gitea Actions job image";
      "org.opencontainers.image.ref.name" = "${name}:${tag}";
      "org.opencontainers.image.source" = "https://gitea.hectic-lab.com/hectic-lab/util.nix";
    };
    WorkingDir = "/workspace";
  };
}
