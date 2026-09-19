#!/usr/bin/env python3
"""Build and publish the same tested server pack on both independent entry points."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mrpack', type=Path)
    ap.add_argument('--bootstrap', type=Path)
    args = ap.parse_args()
    archive = args.mrpack.resolve()
    expected = hashlib.sha256(archive.read_bytes()).hexdigest()
    # Publishing a client before deploying its server can prevent players joining.
    deployed = subprocess.run([
        'ssh', '-o', 'BatchMode=yes', 'neuro',
        'systemctl is-active --quiet minecraft-server-wowMineMap && '
        'sha256sum /var/lib/minecraft-modpacks/worldOfSosal/WorldOfSosal.mrpack',
    ], capture_output=True, text=True, check=True).stdout.split()[0]
    if deployed != expected:
        ap.error('Deploy this mrpack on neuro first: the server archive hash differs')
    scripts = Path(__file__).resolve().parent
    mirrors = [
        ('hectic-lab', 'https://store.hectic-lab.com/minecraft/world-of-sosal/', 'store.hectic-lab.com:25568'),
        ('bfs.poland.xray', 'https://store.bfs.band/minecraft/world-of-sosal/', 'wow.bfs.band'),
    ]
    with tempfile.TemporaryDirectory(prefix='prism-mirrors-') as temporary:
        root = Path(temporary)
        bootstrap = args.bootstrap.resolve() if args.bootstrap else None
        builds = []
        for host, url, server in mirrors:
            output = root / host
            command = [sys.executable, str(scripts / 'build-prism-pack.py'),
                       str(archive), str(output), '--base-url', url, '--server', server]
            if bootstrap:
                command += ['--bootstrap', str(bootstrap)]
            subprocess.run(command, check=True)
            if bootstrap is None:
                bootstrap = root / 'packwiz-installer-bootstrap.jar'
                with zipfile.ZipFile(output / 'WorldOfSosal-Prism.zip') as z:
                    bootstrap.write_bytes(z.read('.minecraft/packwiz-installer-bootstrap.jar'))
            builds.append((host, url, output))
        # Each switch is atomic on its host. A failed publication exits nonzero;
        # rerunning safely verifies existing releases and retries both mirrors.
        for host, url, output in builds:
            subprocess.run([sys.executable, str(scripts / 'publish-prism-pack.py'),
                            str(output), host], check=True)
            print(url, flush=True)


if __name__ == '__main__':
    main()
