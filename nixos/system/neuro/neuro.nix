{
  inputs,
  flake,
  self,
}: {
  lib,
  pkgs,
  config,
  ...
}: let
  ollamaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  ollamaWrapperBundledLibraryPath = "$out/lib/ollama:$out/lib/ollama/cuda_v12:$out/lib/ollama/cuda_v13";

  ollamaServiceBundledLibraryPath = "${ollamaPrebuilt}/lib/ollama:${ollamaPrebuilt}/lib/ollama/cuda_v12:${ollamaPrebuilt}/lib/ollama/cuda_v13";

  stableVideoDiffusionLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  ollamaPrebuilt = pkgs.stdenvNoCC.mkDerivation {
    pname = "ollama";
    version = "0.22.1";

    src = pkgs.fetchurl {
      url = "https://github.com/ollama/ollama/releases/download/v0.22.1/ollama-linux-amd64.tar.zst";
      hash = "sha256-4nwP6PYKgkFi+Bzge0v9p2fc5PNX12LhSbPQ3gq62fs=";
    };

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.gnutar
      pkgs.makeWrapper
      pkgs.zstd
    ];

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ];

    autoPatchelfIgnoreMissingDeps = [
      "libcuda.so.1"
    ];

    unpackPhase = ''
      runHook preUnpack
      tar --zstd -xf $src
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R . $out/
      test -x $out/bin/ollama
      mv $out/bin/ollama $out/bin/.ollama-unwrapped
      makeWrapper $out/bin/.ollama-unwrapped $out/bin/ollama \
        --set-default LD_LIBRARY_PATH "${ollamaLibraryPath}:/run/opengl-driver/lib:${ollamaWrapperBundledLibraryPath}"
      runHook postInstall
    '';

    meta.mainProgram = "ollama";
  };
in {
  imports = [
    self.nixosModules.hectic
    inputs.sops-nix.nixosModules.sops
    ./minecraft.nix
    ./hardware.nix 
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIETMumAHP+htbRvbrmzVoeesbT0+WcH1Wz8htk+7Ik+6"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJZFglwpPMFLnQDOqi84nlMFktZSSu1GzUIafvClUaD"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGj7u/JuY9RwjoxnmO2b+pwC8XbMn+QOy44UpuN0Y1do riquizu"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbR42mLupcsF64ydGSx7HdB+qMVJq41a43UZMI7VvOj"
  ];

  # disko.devices = {
  #   disk.master = {
  #     device = lib.mkDefault "/dev/disk/by-id/nvme-eui.00000000000000000026b7686dfafe35";
  #     type = "disk";
  #     content = {
  #       type = "gpt";
  #       partitions = {
  #         ESP = {
  #           size = "1G";
  #           type = "EF00";
  #           content = {
  #             type = "filesystem";
  #             format = "vfat";
  #             mountpoint = "/boot";
  #           };
  #         };
  #         root = {
  #           size = "100%";
  #           content = {
  #             type = "filesystem";
  #             format = "ext4";
  #             mountpoint = "/";
  #           };
  #         };
  #       };
  #     };
  #   };
  # };

  #hectic.services.matrix = {
  #  enable           = true;
  #  secretsFile      = config.sops.secrets."matrix/secrets".path;
  #  turnSecretFile   = config.sops.secrets."matrix/turn-secret".path;
  #  postgresql = {
  #    port           = 5432;
  #    initialEnvFile = config.sops.secrets."init-postgresql".path;
  #  };
  #  matrixDomain     = "accord.tube";
  #};

  #hectic.services.jitsi = {
  #  enable   = true;
  #  hostName = "meet.accord.tube";
  #};

  #hectic.services.xmpp = {
  #  enable = true;
  #  domain = "accord.tube";
  #  admins = [ "yukkop@accord.tube" ];
  #};

  # Static landing page for bfs.band on :80 and :443 (no HTTP->HTTPS redirect).
  security.acme = {
    acceptTerms = true;
    defaults.email = "security@bfs.band";
  };

  services.nginx = {
    enable = true;
    virtualHosts."bfs.band" = let
      site = pkgs.runCommand "bfs-band-site" {} ''
        mkdir -p $out
        cat > $out/index.html <<'EOF'
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <title>bfs.band</title>
          </head>
          <body>
            <h1>bfs.band</h1>
            <p>Coming soon.</p>
          </body>
        </html>
        EOF
      '';
    in {
      serverAliases = [ "www.bfs.band" ];
      enableACME    = true;
      addSSL        = true;   # serve on both :80 and :443, no forced redirect
      forceSSL      = false;
      root          = "${site}";
    };
  };

  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    package = ollamaPrebuilt;
    home = "/var/lib/ollama";
    models = "/var/lib/ollama/models";
    environmentVariables = {
      LD_LIBRARY_PATH = "${ollamaLibraryPath}:/run/opengl-driver/lib:${ollamaServiceBundledLibraryPath}";
      OLLAMA_NEW_ENGINE = "true";
    };
    loadModels = [ "qwen3.6:27b" "qwen3.5:9b" "gemma3:4b" "gpt-oss:20b" ];
    openFirewall = false;
  };

  hectic.services.stable-video-diffusion = {
    enable       = true;
    host         = "127.0.0.1";
    port         = 7861;
    package      = pkgs.hectic.stable-video-diffusion-api;
    device       = "cuda";
    libraryPath  = [
      stableVideoDiffusionLibraryPath
      "/run/opengl-driver/lib"
    ];
    openFirewall = false;
  };

  networking = {
    networkmanager.enable = true;
    useDHCP = lib.mkDefault true;
    interfaces.enp6s0 = {
      useDHCP = lib.mkDefault true;
      wakeOnLan.enable = true;
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [
        80 443 # HTTP, HTTPS
      ];
      allowedUDPPorts = [ 9 ]; # Wake on LAN
    };
  };

  hardware.enableRedistributableFirmware = true;

  hectic = {
    archetype.base.enable = true;
    archetype.dev.enable  = true;
  };

  sops = {
    gnupg.sshKeyPaths         = [ ];
    age.sshKeyPaths           = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile           = ../../../sus/neuro.yaml;

    #secrets."init-postgresql"     = {};
    #secrets."matrix/secrets"      = {};
    #secrets."matrix/turn-secret"  = {
    #  owner = "turnserver";
    #  group = "turnserver";
    #  mode = "0400";
    #};
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" "sr_mod" "ext4" ];
  boot.initrd.kernelModules = [ "nvme" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-label/NIXBOOT";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware = {
    cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  };

  swapDevices = [ ];

  programs.tmux.enable = true;

  zramSwap.enable        = true;
  zramSwap.priority      = 100;
  zramSwap.memoryMax     = null;
  zramSwap.algorithm     = lib.mkDefault "zstd";
  zramSwap.swapDevices   = 1;
  zramSwap.memoryPercent = lib.mkDefault 100;

  environment.systemPackages = with pkgs; let
    python-ai = python3.withPackages (ps: let
      torchCuda     = ps.torchWithCuda;
      torchvision   = ps.torchvision.override { torch = torchCuda; };
      pytorch3dCuda = ps.pytorch3d.override { torch = torchCuda; };
    in [
      torchCuda
      torchvision
      pytorch3dCuda
      ps.fvcore
      ps.iopath
      ps.tqdm
      hectic.py3-openai-shap-e  # Uncomment when needed; depends on torch
    ]);
  in [
    #python-ai
    git
    hectic.hiddify-core
    neovim
    wget
    ethtool
    rsync
    # docker
  ];
}
