# Attic repack migration helper

Local-only operator tool for safe resumable Attic cache repack/migration. Parent automation starts old/new services, supplies secrets, seeds spool, and runs this CLI.

## Deployment layout

- Original backend: `atticd`, port 8081, `/var/lib/atticd/server.db`, bucket
  `cache-hectic-lab` in HEL1.
- During the write freeze and after cutover the original backend runs in
  `api-server` mode, without its garbage collector, to preserve the comparison
  dataset. Public write methods remain blocked by nginx.
- Repacked backend: `atticd-repacked`, port 8082,
  `/var/lib/atticd-repacked/server.db`, bucket `nix-cache-hectic-lab` in HEL1.
- Both use the same `hectic` signing key and existing JWT verification secret;
  clients do not need a new trusted public key or token.
- New chunk settings: threshold/minimum 1 MiB, average 2 MiB, maximum 4 MiB.
- `https://cache.hectic-lab.com/next/hectic` selects the new backend.
- `https://cache.hectic-lab.com/previous/hectic` selects the original backend;
  nginx permits GET/HEAD only there.
- `repackedActive` in `nixos/system/hectic-lab/attic.nix` selects which backend
  owns the original `/hectic` URL. Keep it false until all cutover gates pass.

## Cutover and rollback gates

1. Finish all migration partitions, then run an unfiltered migration/delta pass.
2. Confirm no CI writers remain. Set `migrationWriteFreeze = true` while
   `repackedActive = false`, apply the small NixOS change, and briefly stop the
   original Attic to drain/cancel any prior in-flight writes.
3. Take a SQLite backup with SQLite's backup API, not a raw live-file copy.
   Keep backups and manifests under private `/var/lib/attic-repack`; the SQLite
   backup includes the cache's private signing key.
4. Restart the original backend for reads only, refresh the complete inventory,
   migrate any final delta, then run unfiltered `verify`. Its exit status must be
   zero; independently compare old/new store-path, NAR hash, size and metadata
   inventories. `status` alone is not a cutover certificate.
5. Pin the old/staging NixOS generation as a GC root, set `repackedActive = true`,
   build, inspect dry activation, and switch. `/hectic` now reaches the new
   backend; old data and `/previous/hectic` remain available.
6. Test public reads, signatures, and an authenticated upload at the original
   URL. Do not remove the old bucket or database as part of this procedure.

Rollback reapplies the pinned staging generation. The new backend and its data
must remain preserved: paths first uploaded after cutover may exist only there.
When editing the flags manually, clear `migrationWriteFreeze` explicitly if
writes to the original backend are intended after rollback.

## Throughput comparison

Compare the same store-path hashes at `/next/hectic` and `/previous/hectic` with
the same request concurrency. For example, fetch
`https://cache.hectic-lab.com/next/hectic/nar/<store-path-hash>.nar` with
`curl --fail --location --output /dev/null --write-out 'bytes=%{size_download} seconds=%{time_total}\n'`.
Do not print effective redirect URLs: S3 redirects contain temporary signatures.
Compare wall time and error rate as well as bytes/second because compressed sizes
can differ after rechunking. Do not use a build with source fallback as a pure
cache throughput measurement. The two endpoints share the VPS and nginx, so run
the comparison sequentially or account for shared-resource contention.

## Spool/state convention

Default state dir: `/var/lib/attic-repack` (`0700`). Raw NAR spool path:

```text
/var/lib/attic-repack/raw/{sha256hex}.nar
```

Parent may seed this file directly. Tool always verifies SHA-256 and byte length before upload. Checkpoints live under `checkpoints/{store_path_hash}.json` and contain no keypair/token.

## Commands

```sh
attic-repack init \
  --old-db file:/var/lib/atticd/server.db?mode=ro \
  --old-url http://127.0.0.1:8081 \
  --new-url http://127.0.0.1:8082 \
  --host cache.hectic-lab.com \
  --atticadm /run/current-system/sw/bin/atticadm \
  --server-config /etc/atticd/server.toml

attic-repack inventory --state-dir /var/lib/attic-repack > inventory.json
attic-repack status --state-dir /var/lib/attic-repack
attic-repack migrate --state-dir /var/lib/attic-repack --workers 2 --limit 20
attic-repack verify --state-dir /var/lib/attic-repack --workers 2
```

`ATTIC_MIGRATION_TOKEN` may be set for manual/tests. Otherwise token is minted in memory with `atticadm make-token` for hectic pull/push/create-cache/configure-cache. Token/keypair are never printed.

## Inventory JSON

`inventory` writes `attic-repack-inventory-v1`:

```json
{
  "format": "attic-repack-inventory-v1",
  "cache": "hectic",
  "spool_dir": "/var/lib/attic-repack/raw",
  "raw_nar_filename": "{sha256hex}.nar",
  "records": [
    {"nar_hash":"sha256:...","nar_size":123,"store_path":"/nix/store/...","metadata_fingerprint":"..."}
  ]
}
```

Records also include upload metadata: `store_path_hash`, `references`, `system`, `deriver`, `sigs`, `ca`.

## Safety

- Checkpoints and `status` are progress information, not a final cutover proof.
  After stopping old writers and taking a consistent snapshot, run an unfiltered
  `verify` (no `--paths-file` or `--limit`) to reread every new NAR and reconcile
  all paths, metadata, hashes, and sizes before switching the primary endpoint.
- A local store path can differ from the historical cached NAR. Such a local
  copy is rejected and recovered from the original S3 chunks instead.
- Old DB is opened readonly; old SQL NAR/chunk tables are never copied.
- Missing local raw NARs are reconstructed from old S3 chunkrefs with per-object retries and chunk/full hash checks.
- Upload uses Attic `PUT /_api/v1/upload-path` with JSON preamble plus raw uncompressed NAR.
- New cache verification compares immutable metadata against old rendered narinfo and reads/decompresses one payload per verified path invocation.
- Authenticated HTTP is refused unless URL host is loopback.

## Local build/test

```sh
nix build --option eval-cache false --impure --expr "let flake = builtins.getFlake \"git+file://$PWD\"; pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; }; in pkgs.callPackage ./infra/attic-migration {}"
nix build --option eval-cache false --impure --expr "let flake = builtins.getFlake \"git+file://$PWD\"; pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; }; p = pkgs.callPackage ./infra/attic-migration {}; in p.passthru.tests.unittest"
```
