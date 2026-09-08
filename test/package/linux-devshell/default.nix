{ inputs, self, pkgs, system, ... }: let
  lib = inputs.nixpkgs.lib;

  mkTestDrv = name: type:
    if type == "directory" then
      pkgs.runCommand "test-${name}" {} ''
        if ! [ -f ${./test + "/${name}" + /run.sh} ]; then
          echo "no run.sh in test/${name}"
          exit 1
        fi
        mkdir -p "$out"
        cp -r ${./test + "/${name}"}/* "$out/"
        chmod +x "$out/run.sh"
      ''
    else if lib.hasSuffix ".sh" name then
      pkgs.runCommand "test-${lib.removeSuffix ".sh" name}" {} ''
        mkdir -p "$out"
        install -Dm755 ${./test + "/${name}"} "$out/run.sh"
      ''
    else
      null;

  testDir  = builtins.readDir ./test;
  testDrvs =
    lib.mapAttrs' (n: v:
      lib.nameValuePair (lib.removeSuffix ".sh" n) v
    ) (lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (n: t: mkTestDrv n t) testDir));

  linuxDevShell = self.packages.${system}.linux-devshell;
  linuxDevShellStandalone = self.packages.${system}.linux-devshell-standalone;

  archBootstrap = pkgs.fetchurl {
    url = "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst";
    hash = "sha256-1YnwGo2li1yIzm6W6yYYwuZeY16Ddsrz1LRTY6/A3Ww=";
  };

  ubuntuBootstrap = pkgs.fetchurl {
    url = "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz";
    hash = "sha256-a8LN45MK0Iizu0b6RSeeltJbw4EPIJhQ7L5HInEYdPk=";
  };

  mkTest = testName: testDrv: pkgs.runCommand "linux-devshell-test-${testName}"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      buildInputs       = [ pkgs.dash ];
      linuxDevShell = linuxDevShell;
      linuxDevShellStandalone = linuxDevShellStandalone;
    } ''
      . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
      export HECTIC_LOG=trace
      test=${testDrv}
      linuxDevShell="${linuxDevShell}"
      linuxDevShellStandalone="${linuxDevShellStandalone}"
      ${builtins.readFile ./launch.sh}

      mkdir -p "$out"
    '';

  mkArchTest = name: root: pkgs.runCommand "linux-devshell-test-arch-${name}"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.zstd pkgs.git ];
      buildInputs       = [ pkgs.dash pkgs.proot ];
      linuxDevShellStandalone = linuxDevShellStandalone;
      archBootstrap = archBootstrap;
    } ''
      . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
      export HECTIC_LOG=trace

      log notice "test case: ''${WHITE}arch ${name}"

      ARCH_DIR="$(mktemp -d)"
      trap 'rm -rf "$ARCH_DIR"' EXIT

      log info "Extracting Arch bootstrap..."
      tar --zstd -xf "${archBootstrap}" -C "$ARCH_DIR" --strip-components=1 \
        --no-same-permissions --no-same-owner --warning=no-unknown-keyword \
        --exclude='etc/ca-certificates' --exclude='etc/ssl' || true

      log info "Preparing Arch environment..."
      mkdir -p "$ARCH_DIR/root/test-repo/script"
      cp "${linuxDevShellStandalone}" "$ARCH_DIR/root/test-repo/script/linux-devshell"
      chmod +x "$ARCH_DIR/root/test-repo/script/linux-devshell"

      cat > "$ARCH_DIR/root/test-repo/flake.nix" <<'EOF'
      {
        description = "Test flake for linux-devshell";
        inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        outputs = { self, nixpkgs }: {
          devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
            shellHook = ''''
              echo "=== Inside dev shell ==="
              exit 0
            '''';
          };
        };
      }
      EOF

      mkdir -p "$ARCH_DIR/root/test-repo/.git"
      git init "$ARCH_DIR/root/test-repo"
      git -C "$ARCH_DIR/root/test-repo" config user.email "test@example.com"
      git -C "$ARCH_DIR/root/test-repo" config user.name "Test"
      git -C "$ARCH_DIR/root/test-repo" add .
      git -C "$ARCH_DIR/root/test-repo" commit -m "init"

      log info "Running linux-devshell as ${name} in Arch via proot..."
      ${lib.optionalString root "proot -b /dev -0 -r \"$ARCH_DIR\" -w /root/test-repo /bin/sh -c '"}
      ${lib.optionalString (!root) "proot -b /dev -r \"$ARCH_DIR\" -w /root/test-repo /bin/sh -c '"}
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export TMPDIR=/tmp
        mkdir -p /nix /build /tmp
        /root/test-repo/script/linux-devshell 2>&1
      ' | tee /tmp/proot-output || true

      log info "Checking ${name} behavior..."

      if ! grep -q "Nix not found" /tmp/proot-output; then
        log error "Script did not detect missing Nix as ${name}"
        cat /tmp/proot-output
        exit 1
      fi
      log success "Script detects missing Nix as ${name}"

      if ! grep -q "Installing via nixos.org" /tmp/proot-output; then
        log error "Script did not attempt Nix installation as ${name}"
        cat /tmp/proot-output
        exit 1
      fi
      log success "Script attempts Nix installation as ${name}"

      if grep -q "installing Nix as root is not supported" /tmp/proot-output; then
        log success "Script handles root install warning"
      fi

      if grep -q "Patched nix.conf" /tmp/proot-output; then
        log success "Script patches nix.conf for ${name} install"
      fi

      if ! grep -q "Failed to download Nix installer" /tmp/proot-output; then
        log error "Script did not handle download failure as ${name}"
        cat /tmp/proot-output
        exit 1
      fi
      log success "Script handles network failure as ${name}"

      log success "Script runs correctly in Arch Linux as ${name}"

      mkdir -p "$out"
    '';

  mkUbuntuTest = name: root: pkgs.runCommand "linux-devshell-test-ubuntu-${name}"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gnutar pkgs.gzip pkgs.git ];
      buildInputs       = [ pkgs.dash pkgs.proot ];
      linuxDevShellStandalone = linuxDevShellStandalone;
      ubuntuBootstrap = ubuntuBootstrap;
    } ''
      . ${self.legacyPackages.${system}.helpers.posix-shell.log}/bin/log.sh
      export HECTIC_LOG=trace

      log notice "test case: ''${WHITE}ubuntu ${name}"

      UBUNTU_DIR="$(mktemp -d)"
      trap 'rm -rf "$UBUNTU_DIR"' EXIT

      log info "Extracting Ubuntu bootstrap..."
      tar -xf "${ubuntuBootstrap}" -C "$UBUNTU_DIR" \
        --no-same-permissions --no-same-owner || true

      log info "Preparing Ubuntu environment..."
      mkdir -p "$UBUNTU_DIR/root/test-repo/script"
      cp "${linuxDevShellStandalone}" "$UBUNTU_DIR/root/test-repo/script/linux-devshell"
      chmod +x "$UBUNTU_DIR/root/test-repo/script/linux-devshell"

      cat > "$UBUNTU_DIR/root/test-repo/flake.nix" <<'EOF'
      {
        description = "Test flake for linux-devshell";
        inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        outputs = { self, nixpkgs }: {
          devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
            shellHook = ''''
              echo "=== Inside dev shell ==="
              exit 0
            '''';
          };
        };
      }
      EOF

      mkdir -p "$UBUNTU_DIR/root/test-repo/.git"
      git init "$UBUNTU_DIR/root/test-repo"
      git -C "$UBUNTU_DIR/root/test-repo" config user.email "test@example.com"
      git -C "$UBUNTU_DIR/root/test-repo" config user.name "Test"
      git -C "$UBUNTU_DIR/root/test-repo" add .
      git -C "$UBUNTU_DIR/root/test-repo" commit -m "init"

      log info "Running linux-devshell as ${name} in Ubuntu via proot..."
      ${lib.optionalString root "proot -b /dev -0 -r \"$UBUNTU_DIR\" -w /root/test-repo /bin/sh -c '"}
      ${lib.optionalString (!root) "proot -b /dev -r \"$UBUNTU_DIR\" -w /root/test-repo /bin/sh -c '"}
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export TMPDIR=/tmp
        mkdir -p /nix /build /tmp
        /root/test-repo/script/linux-devshell 2>&1
      ' | tee /tmp/proot-output || true

      log info "Checking ${name} behavior..."

      if ! grep -q "Nix not found" /tmp/proot-output; then
        log error "Script did not detect missing Nix as ${name}"
        cat /tmp/proot-output
        exit 1
      fi
      log success "Script detects missing Nix as ${name}"

      if ! grep -q "Installing via nixos.org" /tmp/proot-output; then
        log error "Script did not attempt Nix installation as ${name}"
        cat /tmp/proot-output
        exit 1
      fi
      log success "Script attempts Nix installation as ${name}"

      if grep -q "installing Nix as root is not supported" /tmp/proot-output; then
        log success "Script handles root install warning"
      fi

      if grep -q "Patched nix.conf" /tmp/proot-output; then
        log success "Script patches nix.conf for ${name} install"
      fi

      if grep -q "Failed to download Nix installer" /tmp/proot-output || grep -q "curl is required" /tmp/proot-output; then
        log success "Script handles missing curl or network failure as ${name}"
      else
        log error "Script did not handle failure gracefully as ${name}"
        cat /tmp/proot-output
        exit 1
      fi

      log success "Script runs correctly in Ubuntu as ${name}"

      mkdir -p "$out"
    '';
in
  (lib.mapAttrs (name: drv: mkTest name drv) testDrvs) // {
    arch-integration-root = mkArchTest "root" true;
    arch-integration-user = mkArchTest "user" false;
    ubuntu-integration-root = mkUbuntuTest "root" true;
    ubuntu-integration-user = mkUbuntuTest "user" false;
  }
