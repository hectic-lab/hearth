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

Publish the archive without adding secrets to the image layers, then use the
registry-reported digest as the only final `nix` label image reference:

```text
nix:docker://gitea.hectic-lab.com/hectic-lab/gitea-runner-nix-image@sha256:<registry-digest>
```

The `2026-06-07` tag may be pushed as a human-readable companion tag, but the
runner label mapping must use the `@sha256:` reference above. Keep
`ubuntu-latest` on the `gitea/runner` default image unless a later runner
configuration task explicitly changes it. Only the `nix` label should select
this custom image.

If the Gitea container registry is unavailable, select a private registry that
is reachable from the runner Kubernetes cluster and requires authentication that
can be provided through Kubernetes image-pull secrets. Record the selected
registry and replace the host in the same digest-pinned form:

```text
nix:docker://<private-registry>/<namespace>/gitea-runner-nix-image@sha256:<registry-digest>
```

Do not fall back to `latest` or a tag-only mapping.

## Task 7 publication status

Local build evidence is recorded in
`.sisyphus/evidence/task-7-image-digest.txt`. In this environment, Docker could
load and tag the image, but pushing to the preferred registry failed with
`unauthorized: reqPackageAccess`, so no registry digest was available to pin as a
concrete final mapping. Kubernetes pull smoke is recorded in
`.sisyphus/evidence/task-7-image-pull.txt` and is blocked here because `kubectl`
is not installed or not on `PATH`.

Once registry credentials are available, rerun the push, capture the
registry-reported digest, and replace `<registry-digest>` in the mapping above
before Task 6/9 consumes the label configuration.

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
