# Using the `hectic` Attic Cache

This document explains how to:

1. pull build artifacts from the cache
2. push new artifacts to the cache
3. configure this flake to use the cache

## Cache endpoints

- API endpoint: `https://cache.hectic-lab.com`
- Binary cache endpoint: `https://cache.hectic-lab.com/hectic`

The `hectic` cache is:

- public for reads
- private for pushes

## Requirements

Use the Attic client package:

```sh
nix shell nixpkgs#attic-client
```

Or run commands directly with:

```sh
nix shell nixpkgs#attic-client -c <command>
```

## Read from the cache

### Get the cache public key

```sh
nix shell nixpkgs#attic-client -c attic cache info hectic
```

Copy the `Public Key` value, which looks like:

```text
hectic:...
```

### Configure Nix to trust the cache

Per-user: `~/.config/nix/nix.conf`

```ini
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = hectic:PASTE_PUBLIC_KEY_HERE
```

System-wide: `/etc/nix/nix.conf`

```ini
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = hectic:PASTE_PUBLIC_KEY_HERE
```

After that, normal Nix commands can download from the cache automatically:

```sh
nix build .#migrator
nix develop
nix flake check
```

## Use the cache from this flake

You can also advertise the cache from `flake.nix`:

```nix
nixConfig = {
  extra-substituters = [
    "https://cache.nixos.org"
    "https://cache.hectic-lab.com/hectic"
  ];
  extra-trusted-public-keys = [
    "hectic:PASTE_PUBLIC_KEY_HERE"
  ];
};
```

Then users can run:

```sh
nix build --accept-flake-config .#migrator
```

## Log in for pushing

Pushing requires an Attic token.

```sh
nix shell nixpkgs#attic-client -c attic login local https://cache.hectic-lab.com "<TOKEN>"
```

Example with `pass`:

```sh
nix shell nixpkgs#attic-client -c attic login local https://cache.hectic-lab.com "$(pass show atticd/hectic-lab/token)"
```

## Push build results

### Push a package

```sh
nix build .#migrator
nix shell nixpkgs#attic-client -c attic push local:hectic ./result
```

### Push a check

```sh
nix build .#checks.x86_64-linux.arguments
nix shell nixpkgs#attic-client -c attic push local:hectic ./result
```

### Push a NixOS system build

```sh
nix build '.#nixosConfigurations."hectic-lab|x86_64-linux".config.system.build.toplevel'
nix shell nixpkgs#attic-client -c attic push local:hectic ./result
```

## Recommended workflow

### Local development

Use the cache for reads only:

```sh
nix build .#migrator
nix develop
nix flake check
```

### CI / builder

1. Build
2. Push to Attic

Example:

```sh
nix build .#migrator
nix shell nixpkgs#attic-client -c attic push local:hectic ./result
```

## Useful commands

### Show cache info

```sh
nix shell nixpkgs#attic-client -c attic cache info hectic
```

### Check login config

```sh
nix shell nixpkgs#attic-client -c attic cache info local:hectic
```

### Re-login with a new token

```sh
nix shell nixpkgs#attic-client -c attic login local https://cache.hectic-lab.com "<NEW_TOKEN>"
```

## Automatic uploads from trusted CI

The `deploy-neuro` workflow uses `with-attic-cache` around its deployment command:

```sh
# ATTIC_TOKEN must be supplied through a secret, not committed or printed.
nix run '.#with-attic-cache' -- -- nix build '.#my-package'
```

The wrapper installs a temporary Nix `post-build-hook`. Each successful local
build queues all output paths, including build-only dependencies and multiple
outputs. A separate worker uploads batches with `attic push --stdin --no-closure`
and two concurrent uploads. Pending outputs have registered garbage-collection
roots until uploaded. Substituted paths and the initial bootstrap of the wrapper
itself are not uploaded; this avoids copying the public NixOS cache into Attic.

The worker runs during the build and drains after success or failure. Uploads
have bounded retries; exhausted uploads fail an otherwise successful command.
If the build failed, its original exit status is preserved. Defaults are 30
minutes for the wrapped command, 10 minutes for the final drain, and three
120-second attempts per batch of up to 32 paths. These limits can be adjusted with
`WITH_ATTIC_BUILD_TIMEOUT`, `WITH_ATTIC_DRAIN_TIMEOUT`,
`WITH_ATTIC_UPLOAD_TIMEOUT`, `WITH_ATTIC_UPLOAD_RETRIES`, and
`WITH_ATTIC_BATCH_SIZE` (positive integer seconds/counts without leading zeros).

The heavier `deploy-neuro` workflow overrides these defaults: 6 hours for the
build/deploy command, batches of at most 8 paths, and 600 seconds per upload attempt. The
upload deadline covers the **whole batch**, not each individual path. Its final
drain is bounded at 1 hour; the 435-minute job budget leaves 15 minutes for setup
and cleanup. The `gross-nix-x86-perf` runner limit and Gitea's endless-task
watchdog are 8 hours. VM hard lifetime starts at allocation and has no controller
destruction grace. A prolonged cache outage can still exhaust the drain before
every queued path is uploaded.

The build timeout covers the entire wrapped command, not each derivation.
Completed outputs can be reused from the cache, but an interrupted CUDA/Magma
compilation does not produce a cacheable output or resume on the next ephemeral
runner. Exit code 124 with `interrupted by the user` can therefore mean the
wrapper deadline expired, not that someone manually cancelled the job.

The workflow also sets `fallback = true` in `NIX_CONFIG`, inherited by nested
Nix commands. If substitution fails, Nix can build the affected derivation from
source instead of aborting solely because the cache is unavailable. Caches and
signature checks remain enabled. Fallback cannot fix an unavailable upstream
source or a genuine compilation error, and rebuilding can consume more time.

Uploader logs report each attempt's batch size, whole-batch deadline and exit
status, distinguish deadline expiration from other failures, and list paths in
exhausted batches. The final summary counts queue records: acknowledged,
unconfirmed after exhausted attempts, pending and in flight. These are not
unique artifact counts: an unsuccessful batch may already have uploaded some
paths, and a successful retry can reuse those cached results.

This integration targets the root, single-user Nix environment on the ephemeral
runner. It refuses to replace an existing post-build hook. SIGINT/SIGTERM stop
the command and attempt a bounded drain; SIGKILL, VM destruction, or a hard
runner timeout cannot guarantee uploads. A failed upload remains a visible CI
failure, not a claim that the artifact was cached.

### CI credentials and rollout

- `ATTIC_TOKEN` is a Gitea repository secret for `hinterland/hearth`, passed only
  to the deployment step. The workflow remains manual and restricted to `master`.
- The token grants pull/push only for `hectic`, without deletion or cache
  administration. The current token expires **2027-09-09**; rotate it before then.
- The wrapper stores it in a private temporary `0600` file, references that file
  from Attic configuration, and removes `ATTIC_TOKEN` from child environments.
  Neither the hook nor `NIX_CONFIG` contains the token. Cleanup removes private
  files after the worker stops.
- Never expose this credential to untrusted PR workflows or bake it into runner
  images. A writer to this cache can publish artifacts trusted by its consumers.
- The `hectic` cache is public for reads. Build outputs must not contain secrets
  or content that must remain private; the wrapper uploads every successful local
  output, not just the final system.
- Workflow/package changes must be published to `master` before dispatched runs
  use them. Creating the secret alone does not enable uploads in an existing run.

## Common issues

### `flake 'nixpkgs' does not provide attribute 'attic'`

Use:

```sh
nix shell nixpkgs#attic-client
```

Not:

```sh
nix shell nixpkgs#attic
```

### `HTTP 413 Payload Too Large`

This means nginx rejected the upload body size. The server must allow large uploads on the Attic vhost.

### Push succeeds for some paths but fails for others

Usually means:

- nginx body size limit
- timeout/reverse proxy issue
- bad token permissions

On `hectic-lab`, the upload API has separate nginx locations for
`/_api/v1/upload-path` and `/next/_api/v1/upload-path`. Requests stream to Attic
without whole-body buffering, using HTTP/1.1 upstream and 600-second
`proxy_send_timeout` and `proxy_read_timeout` values. These are inactivity
timeouts, not an upload throughput guarantee. The CI wrapper still enforces its
own whole-batch deadline. The legacy `/previous/` endpoint stays read-only.

The host's Attic package also restricts its AWS SDK rustls connector to HTTP/1.1
after observed S3 `REFUSED_STREAM` failures. This is a reproducible, host-scoped
derived Cargo vendor tree; the pinned input tree and Cargo.lock are unchanged.
TLS certificate verification remains enabled. Nix clients now force HTTP/1.1 for
cache pulls because the cache endpoint has produced HTTP/2 framing errors; the
Attic upload client separately uses HTTP/1.1 upstream. The pinned crate path
makes upstream changes fail visibly during a future upgrade. This mitigates the
observed transport error, not every possible Hetzner S3 timeout.

### Cache pulls do not work

Check:

- `substituters`
- `trusted-public-keys`
- the exact public key from `attic cache info hectic`

## Notes about retention and storage

- The cache currently uses Hetzner Object Storage
- If no `retention-period` is configured, cached objects do not expire automatically
- This is good for long-lived reuse, but storage usage can grow over time

## Summary

### Read access

```sh
nix build .#migrator
```

after configuring:

```ini
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = hectic:PASTE_PUBLIC_KEY_HERE
```

### Push access

```sh
nix shell nixpkgs#attic-client -c attic login local https://cache.hectic-lab.com "<TOKEN>"
nix build .#migrator
nix shell nixpkgs#attic-client -c attic push local:hectic ./result
```
