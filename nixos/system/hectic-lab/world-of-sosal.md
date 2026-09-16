# WorldOfSosal pack publishing

The public endpoint is `https://store.hectic-lab.com/world-of-sosal/`. Nix
deploys only its landing page and nginx configuration. Pack files, the checksum
manifest, and `latest.mrpack` stay under `/var/www/store/world-of-sosal` on the
host and never enter Git or the Nix store.

## Publish an uploaded pack

Run these commands on `hectic-lab` as root after the Storage Box pack has
already been uploaded to a local staging path. Pick a stable version name; do
not replace an existing versioned release.

```sh
set -eu
source_pack=/path/to/already-uploaded/WorldOfSosal.mrpack
version=2026-09-16
root=/var/www/store/world-of-sosal
release_name="WorldOfSosal-${version}.mrpack"
release_path="$root/releases/$release_name"

printf '%s  %s\n' \
  f8c18acb9208e4592725632ae50dab4f9c308483b34fd43a6507c74fdbf8169f \
  "$source_pack" | sha256sum --check --status
test ! -e "$release_path"
install -o root -g nginx -m 0640 "$source_pack" "$release_path.new"
mv -T "$release_path.new" "$release_path"

manifest="$root/.SHA256SUMS.$$"
(cd "$root/releases" && sha256sum -- *.mrpack) > "$manifest"
chown root:nginx "$manifest"
chmod 0640 "$manifest"
mv -Tf "$manifest" "$root/SHA256SUMS"

latest="$root/.latest.mrpack.$$"
ln -s "releases/$release_name" "$latest"
mv -Tf "$latest" "$root/latest.mrpack"
```

Versioned releases use a one-year immutable cache policy. `latest.mrpack` and
`SHA256SUMS` disable caching so an atomic replacement becomes visible quickly.
The manifest is available at
`https://store.hectic-lab.com/world-of-sosal/SHA256SUMS`.

Import the current pack in Prism Launcher with:

```text
prismlauncher://import?url=https%3A%2F%2Fstore.hectic-lab.com%2Fworld-of-sosal%2Flatest.mrpack
```

Direct URL imports do not auto-update. Repeat the publication and import steps
for each new pack version.
