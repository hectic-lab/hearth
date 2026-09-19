#!/usr/bin/env python3
"""Publish build-prism-pack.py output; switch the complete pack atomically.

Usage: python3 script/publish-prism-pack.py OUTPUT_DIRECTORY [SSH_HOST]
Coordinate gameplay updates with deployment of the same release on the server.
"""
import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1]).resolve()
host = sys.argv[2] if len(sys.argv) > 2 else 'hectic-lab'
if host.startswith('-'):
    raise ValueError('Invalid SSH host')
release = hashlib.sha256((root / 'pack/pack.toml').read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='prism-publish-') as temporary:
    archive = Path(temporary) / 'publish.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for name in ['pack', 'WorldOfSosal-Prism.zip', 'latest.mrpack', 'SHA256SUMS', 'index.html']:
            tar.add(root / name, arcname=name)
    remote = f'/tmp/prism-publish-{release}.tar.gz'
    subprocess.run(['scp', '-o', 'BatchMode=yes', str(archive), f'{host}:{remote}'], check=True)
    script = '''set -eu
umask 022
base=/var/www/store/minecraft/world-of-sosal
release=RELEASE
archive=/tmp/prism-publish-$release.tar.gz
mkdir -p "$base/releases"
stage=$(mktemp -d "$base/.publish.XXXXXX")
trap 'rm -rf "$stage"; rm -f "$archive"' EXIT
tar -xzf "$archive" -C "$stage"
chmod -R u=rwX,go=rX "$stage"
if test -d "$base/releases/$release"; then
  diff -qr "$stage/pack" "$base/releases/$release"
else
  mv "$stage/pack" "$base/releases/$release"
fi
for name in WorldOfSosal-Prism.zip latest.mrpack SHA256SUMS index.html; do
  mv "$stage/$name" "$base/$name"
done
ln -s "releases/$release" "$stage/current"
mv -Tf "$stage/current" "$base/current"
echo "Published $release"
'''.replace('RELEASE', release)
    subprocess.run(['ssh', '-o', 'BatchMode=yes', host, 'sh', '-s'], input=script, text=True, check=True)
print('https://store.hectic-lab.com/minecraft/world-of-sosal/')
