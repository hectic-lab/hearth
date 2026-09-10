# Gitea runner Nix image

The repo-owned Nix-capable job image is built by the flake package
`gitea-runner-nix-image`.

```sh
nix build .#gitea-runner-nix-image
```

The package emits a Docker archive with the local build tag:

```text
gitea-runner-nix-image:2026-06-07
```

That tag is build metadata only. Do not use it as the final Gitea runner label
mapping because runner job images must be immutable.

## Publication target

Preferred registry:

```text
gitea.hectic-lab.com/hectic-lab/gitea-runner-nix-image
```

Publish the archive without adding secrets to the image layers. Controller-owned
zero-idle runners select this image through `nixImageId` / `GCR_NIX_IMAGE_ID`;
they do not use a Gitea label-to-container-image mapping:

```text
nixImageId = "<Hetzner-image-id>";
```

The `2026-06-07` tag may be pushed as a human-readable companion tag. The
legacy Kubernetes rollback pool is currently disabled and has no labels.
If it is restored, its Nix-capable image must be configured separately and
digest-pinned before enabling a `nix` label.

Do not use a tag-only image for a restored Kubernetes rollback pool.

## Task 7 publication status

Local build evidence is recorded in
`.sisyphus/evidence/task-7-image-digest.txt`. Kubernetes pull smoke is recorded in
`.sisyphus/evidence/task-7-image-pull.txt` and is blocked here because `kubectl`
is not installed or not on `PATH`.

After importing the archive as a Hetzner image, record its image ID in the
controller host configuration before dispatching Nix jobs.

## Image contents

The image includes `nix`, `git`, `bash`, `coreutils`, and `cacert`. Its
`/etc/nix/nix.conf` enables flakes and configures the repo substituters from the
top-level `flake.nix`:

```text
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
http2 = false
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
sandbox = false
```

No Gitea runner token, SSH key, SOPS key, kubeconfig, Hetzner token, or S3
credential belongs in this image. Runtime secrets stay with the Kubernetes
runner configuration and token-file mount contract.
