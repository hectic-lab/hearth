{ pkgs, ... }: let
  opentofuUnstable = "github:NixOS/nixpkgs/nixos-unstable#opentofu";

  tofu = pkgs.writeShellScriptBin "tofu" ''
    exec ${pkgs.nix}/bin/nix run ${opentofuUnstable} -- "$@"
  '';

  packer = pkgs.stdenvNoCC.mkDerivation {
    pname = "packer";
    version = "1.16.0";
    src = pkgs.fetchurl {
      url = "https://releases.hashicorp.com/packer/1.16.0/packer_1.16.0_linux_amd64.zip";
      hash = "sha256-XtzRSrWbU1BAxRLb7Nbsnvl2oACwc8Gdk+TEMclIWB4=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      install -d $out/bin
      unzip -p $src packer > $out/bin/packer
      chmod 755 $out/bin/packer
    '';
  };

  buildMicroosSnapshots = pkgs.writeShellScriptBin "gitea-runners-build-microos-snapshots" ''
    set -eu

    : "''${HCLOUD_TOKEN:?HCLOUD_TOKEN is not set}"

    architecture="''${1:-both}"
    x86_location="''${GITEA_RUNNERS_X86_LOCATION:-nbg1}"
    x86_server_type="''${GITEA_RUNNERS_X86_SERVER_TYPE:-cx23}"
    case "$architecture" in
      x86|arm|both) ;;
      *)
        printf 'usage: gitea-runners-build-microos-snapshots [x86|arm|both]\n' >&2
        exit 2
        ;;
    esac

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT HUP INT TERM
    ssh_private_key_file="$workdir/packer-ssh-key"
    ssh-keygen -q -t ed25519 -N "" -f "$ssh_private_key_file"
    image_public_key_file="''${GITEA_RUNNERS_IMAGE_SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
    test -r "$image_public_key_file"
    packer_public_key_b64="$(base64 -w0 "$ssh_private_key_file.pub")"
    image_public_key_b64="$(base64 -w0 "$image_public_key_file")"

    curl -fsSL \
      https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/create.sh \
      -o "$workdir/create.sh"
    chmod +x "$workdir/create.sh"

    (
      cd "$workdir"
      folder_name="runner-images" \
      folder_path="$workdir" \
      create_snapshots=none \
      HCLOUD_TOKEN="$HCLOUD_TOKEN" \
      "$workdir/create.sh"
    )

    packer_dir="$workdir/runner-images/packer"
    "$packer_dir/scripts/install-verified-packer-plugin-hcloud.sh"

    # Packer may try to remove its remote script after the image-writing reboot,
    # while SSH is already unavailable. Keep that cleanup from aborting builds.
    sed -i \
      '/inline[[:space:]]*=[[:space:]]*\[local\.write_x86_image\]/a\    skip_clean       = true' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"
    sed -i \
      '/inline[[:space:]]*=[[:space:]]*\[local\.write_arm_image\]/a\    skip_clean       = true' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"
    sed -i \
      '/inline[[:space:]]*=[[:space:]]*\[local\.install_packages\]/a\    start_retry_timeout = "15m"' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"
    sed -i \
      '/ssh_username[[:space:]]*=[[:space:]]*"root"/a\  temporary_key_pair_type = "ed25519"' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"
    awk \
      -v ssh_private_key_file="$ssh_private_key_file" \
      '/token[[:space:]]*=[[:space:]]*var[.]hcloud_token/ {
        print
        print "  ssh_private_key_file = \"" ssh_private_key_file "\""
        next
      }
      { print }' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl" \
      > "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp"
    mv "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp" \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"

    cat > "$workdir/image-key-injection.txt" <<'EOF'
  partprobe /dev/sda || true
  udevadm settle
  root_device=""
  for candidate in /dev/sda[0-9]*; do
    if [ "$(blkid -s TYPE -o value "$candidate" 2>/dev/null || true)" = btrfs ]; then
      root_device="$candidate"
      break
    fi
  done
  test -n "$root_device"
  mount -o subvol=@ "$root_device" /mnt
  install -d -m 0700 /mnt/root/.ssh
  printf '%s' '__IMAGE_PUBLIC_KEY_B64__' | base64 -d > /mnt/root/.ssh/authorized_keys
  printf '\n%s' '__PACKER_PUBLIC_KEY_B64__' | base64 -d >> /mnt/root/.ssh/authorized_keys
  chmod 0600 /mnt/root/.ssh/authorized_keys
  sync
  umount /mnt
EOF
    sed -i "s|__PACKER_PUBLIC_KEY_B64__|$packer_public_key_b64|" \
      "$workdir/image-key-injection.txt"
    sed -i "s|__IMAGE_PUBLIC_KEY_B64__|$image_public_key_b64|" \
      "$workdir/image-key-injection.txt"
    awk -v inject_file="$workdir/image-key-injection.txt" \
      '/done[.] Rebooting/ {
        while ((getline line < inject_file) > 0) print line
        close(inject_file)
      }
      { print }' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl" \
      > "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp"
    mv "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp" \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"

    cat > "$workdir/cloud-init-cleanup.txt" <<'EOF'
  cloud-init clean --logs --machine-id --seed --configs all || true
  rm -rf /run/cloud-init/* /var/lib/cloud/*
EOF
    awk -v cleanup_file="$workdir/cloud-init-cleanup.txt" \
      '/# Cleanup some logs/ {
        while ((getline line < cleanup_file) > 0) print "- [sh, -c, \"" line "\"]"
        close(cleanup_file)
      }
      { print }' \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl" \
      > "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp"
    mv "$packer_dir/hcloud-microos-snapshots.pkr.hcl.tmp" \
      "$packer_dir/hcloud-microos-snapshots.pkr.hcl"

    x86_base='https://download.opensuse.org/tumbleweed/appliances'
    x86_file='openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2'
    x86_url="$x86_base/$x86_file"

    arm_base='https://download.opensuse.org/ports/aarch64/tumbleweed/appliances'
    arm_file='openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2'
    arm_url="$arm_base/$arm_file"

    x86_sha="$(curl -fsSL "$x86_url.sha256" | awk '{print $1; exit}')"
    arm_sha="$(curl -fsSL "$arm_url.sha256" | awk '{print $1; exit}')"

    test -n "$x86_sha"
    test -n "$arm_sha"

    printf 'x86 digest: %s\n' "$x86_sha"
    printf 'arm digest: %s\n' "$arm_sha"

    (
      cd "$packer_dir"
      packer init hcloud-microos-snapshots.pkr.hcl
      case "$architecture" in
        x86)
          packer build \
            -only=hcloud.microos-x86-snapshot \
            -var 'selinux_package_to_install=k3s' \
            -var "x86_location=$x86_location" \
            -var "x86_server_type=$x86_server_type" \
            -var "opensuse_microos_x86_expected_sha256=$x86_sha" \
            -var "opensuse_microos_arm_expected_sha256=$arm_sha" \
            hcloud-microos-snapshots.pkr.hcl
          ;;
        arm)
          packer build \
            -only=hcloud.microos-arm-snapshot \
            -var 'selinux_package_to_install=k3s' \
            -var "opensuse_microos_x86_expected_sha256=$x86_sha" \
            -var "opensuse_microos_arm_expected_sha256=$arm_sha" \
            hcloud-microos-snapshots.pkr.hcl
          ;;
        both)
          packer build \
            -var 'selinux_package_to_install=k3s' \
            -var "x86_location=$x86_location" \
            -var "x86_server_type=$x86_server_type" \
            -var "opensuse_microos_x86_expected_sha256=$x86_sha" \
            -var "opensuse_microos_arm_expected_sha256=$arm_sha" \
            hcloud-microos-snapshots.pkr.hcl
          ;;
      esac
    )
  '';

  giteaRunnersSetup = pkgs.writeShellScriptBin "gitea-runners-setup" /* sh */ ''
    cat <<'EOF'
Gitea runners setup checklist

Tools available in this shell:
  tofu, packer, gitea-runners-build-microos-snapshots [x86|arm|both], kubectl, kustomize,
  kubeconform, sops, age, awscli2, hcloud,
  tea, docker, skopeo, go-containerregistry, jq, yq-go, curl, git, openssh, nix

Environment expected before real deploy/apply:
  TF_VAR_hcloud_token
  TF_VAR_ssh_public_key
  TF_VAR_ssh_private_key
  S3 backend credentials and endpoint access
  a matching SOPS age identity for sus/gitea-runners.yaml
  kubectl access to the target cluster
  a concrete registry digest for the pushed Nix-capable runner image if enabling
  the nix label

OpenTofu validation gate:
  tofu version
  tofu -chdir=infra/gitea-runners/opentofu validate

Nix image build/publish/digest gate:
  nix build .#gitea-runner-nix-image
  publish the archive, then pin the registry-reported digest in the runner label
  mapping
  nix:docker://gitea.hectic-lab.com/hectic-lab/gitea-runner-nix-image@sha256:<registry-digest>

SOPS token Secret creation gate:
  kubectl apply -f infra/gitea-runners/k8s/namespace.yaml
  umask 077
  token_file=$(mktemp /tmp/gitea-runner-token.XXXXXX)
  trap 'rm -f "$token_file"' EXIT
  sops -d --extract '["gitea"]["hectic-lab"]["org-runner-registration-token"]' sus/gitea-runners.yaml > "$token_file"
  kubectl -n gitea-runners create secret generic gitea-runner-token \
    --from-file=token="$token_file" \
    --dry-run=client \
    -o yaml | kubectl -n gitea-runners apply -f -

Cluster provision gate:
  tofu -chdir=infra/gitea-runners/opentofu init
  tofu -chdir=infra/gitea-runners/opentofu validate
  tofu -chdir=infra/gitea-runners/opentofu plan -out=.sisyphus/evidence/task-12-deploy.plan
  tofu -chdir=infra/gitea-runners/opentofu apply .sisyphus/evidence/task-12-deploy.plan
  export KUBECONFIG="$(tofu -chdir=infra/gitea-runners/opentofu output -raw kubeconfig_path)"

Kubernetes apply gate:
  kubectl config current-context
  kubectl get nodes -o wide
  kubectl get sc
  kubectl apply -k infra/gitea-runners/k8s

Verification commands:
  kubectl -n gitea-runners get statefulset gitea-runner
  kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
  kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
  kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide
  kubectl -n gitea-runners get events --sort-by=.lastTimestamp | tail -n 50
  kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200

Main blockers and gates:
  do not run tofu apply without all external inputs
  do not apply the k8s overlay until the gitea-runner-token Secret exists
  do not enable the nix label until the image has been published with a concrete digest
  do not print, load, or require secrets on shell entry
EOF
  '';
in pkgs.mkShell {
  name = "gitea-runners";

  buildInputs = [
    tofu
    packer
    buildMicroosSnapshots
    giteaRunnersSetup
    pkgs.nix
    pkgs.kubectl
    pkgs.kustomize
    pkgs.kubeconform
    pkgs.sops
    pkgs.age
    pkgs.awscli2
    pkgs.hcloud
    pkgs.tea
    pkgs.docker
    pkgs.skopeo
    pkgs.go-containerregistry
    pkgs.jq
    pkgs.yq-go
    pkgs.curl
    pkgs.git
    pkgs.openssh
    pkgs.unzip
  ];

  shellHook = ''
    export GITEA_RUNNERS_ROOT="$PWD/infra/gitea-runners"
    export GITEA_RUNNERS_TOFU_DIR="$GITEA_RUNNERS_ROOT/opentofu"
    export GITEA_RUNNERS_K8S_DIR="$GITEA_RUNNERS_ROOT/k8s"
    export GITEA_RUNNERS_IMAGE_DIR="$GITEA_RUNNERS_ROOT/image"
    export GITEA_RUNNERS_NAMESPACE="gitea-runners"

    alias cd-gitea-runners='cd "$GITEA_RUNNERS_ROOT"'
    alias cd-gitea-runners-tofu='cd "$GITEA_RUNNERS_TOFU_DIR"'
    alias cd-gitea-runners-k8s='cd "$GITEA_RUNNERS_K8S_DIR"'

    echo ""
    echo "=== Gitea runner setup DevShell ==="
    echo ""
    echo "Run gitea-runners-setup for the full setup checklist."
    echo "Paths: "
    echo "  root=$GITEA_RUNNERS_ROOT"
    echo "  tofu=$GITEA_RUNNERS_TOFU_DIR"
    echo "  k8s=$GITEA_RUNNERS_K8S_DIR"
    echo "  image=$GITEA_RUNNERS_IMAGE_DIR"
    echo ""
  '';
}
