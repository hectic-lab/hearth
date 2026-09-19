#!/usr/bin/env python3
"""Build a Prism auto-update instance and immutable packwiz release from an mrpack.

Upload the pack directory to an immutable release, then atomically switch current.
Publish only releases tested with the server, including Minecraft/NeoForge upgrades.
"""
import argparse
import hashlib
import html
import io
import json
from pathlib import Path, PurePosixPath
import re
import struct
import tomllib
import urllib.parse
import urllib.request
import zipfile

BOOTSTRAP_URL = 'https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar'
BOOTSTRAP_SHA256 = 'a8fbb24dc604278e97f4688e82d3d91a318b98efc08d5dbfcbcbcab6443d116c'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def quote(s):
    return json.dumps(s, ensure_ascii=False)

def safe_path(s):
    p = PurePosixPath(s)
    if not s or p.is_absolute() or any(x in ('', '.', '..') for x in s.split('/')) or re.search(r'[\\\x00-\x1f:*?"<>|]', s):
        raise ValueError(f'Unsafe pack path: {s!r}')
    return p

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mrpack', type=Path)
    ap.add_argument('output', type=Path, help='new output directory (must not exist)')
    ap.add_argument('--base-url', default='https://store.hectic-lab.com/minecraft/world-of-sosal/')
    ap.add_argument('--server', help='optional initial multiplayer server address')
    ap.add_argument('--bootstrap', type=Path)
    args = ap.parse_args()
    base = args.base_url.rstrip('/') + '/'
    if not base.startswith('https://'):
        ap.error('--base-url must use HTTPS')
    archive = args.mrpack.read_bytes()
    release = digest(archive)
    bootstrap = args.bootstrap.read_bytes() if args.bootstrap else urllib.request.urlopen(BOOTSTRAP_URL, timeout=60).read()
    if digest(bootstrap) != BOOTSTRAP_SHA256:
        raise ValueError('Bootstrap checksum mismatch')
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.output / 'pack'
    root.mkdir(parents=True)
    entries = {}
    destinations = set()
    def write(path, data, *, metafile=False, preserve=False):
        safe_path(path)
        dest = root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        entries[path] = {'file': path, 'hash': digest(data), 'metafile': metafile, 'preserve': preserve}
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        manifest = json.loads(z.read('modrinth.index.json'))
        deps = manifest['dependencies']
        if manifest['formatVersion'] != 1 or manifest['game'] != 'minecraft' or set(deps) != {'minecraft', 'neoforge'}:
            raise ValueError('Expected a Minecraft NeoForge mrpack v1')
        for f in manifest['files']:
            path = safe_path(f['path'])
            if f.get('env', {}).get('client') == 'unsupported':
                continue
            if f['path'] in destinations:
                raise ValueError('Duplicate destination: ' + f['path'])
            destinations.add(f['path'])
            url = f['downloads'][0]
            sha = f['hashes']['sha512']
            if not url.startswith('https://') or not re.fullmatch('[0-9a-fA-F]{128}', sha):
                raise ValueError('Invalid URL/hash: ' + f['path'])
            # Include optional mods too, matching the server importer. The published
            # manifest, rather than upstream latest versions, controls all updates.
            meta = f'name = {quote(path.name)}\nfilename = {quote(path.name)}\nside = "client"\n\n[download]\nurl = {quote(url)}\nhash-format = "sha512"\nhash = {quote(sha)}\n'
            write(str(path) + '.pw.toml', meta.encode(), metafile=True)
        for prefix in ('overrides/', 'client-overrides/'):
            for item in z.infolist():
                if not item.filename.startswith(prefix) or item.is_dir():
                    continue
                name = item.filename[len(prefix):]
                safe_path(name)
                if not (name.startswith(('config/', 'mods/', 'resourcepacks/', 'shaderpacks/')) or name == 'options.txt'):
                    raise ValueError('Review unexpected override: ' + name)
                if name in destinations:
                    raise ValueError('Override duplicates downloaded mod: ' + name)
                write(name, z.read(item), preserve=name == 'options.txt')
    index = 'hash-format = "sha256"\n'
    for entry in sorted(entries.values(), key=lambda e: e['file']):
        index += '\n[[files]]\n'
        for k, v in entry.items():
            if isinstance(v, bool):
                if v:
                    index += f'{k} = true\n'
            else:
                index += f'{k} = {quote(v)}\n'
    (root / 'index.toml').write_text(index)
    pack = f'name = "WorldOfSosal"\npack-format = "packwiz:1.1.0"\nversion = {quote(manifest["versionId"])}\n\n[index]\nfile = "index.toml"\nhash-format = "sha256"\nhash = "{digest(index.encode())}"\n\n[versions]\nminecraft = {quote(deps["minecraft"])}\nneoforge = {quote(deps["neoforge"])}\n'
    tomllib.loads(pack)
    (root / 'pack.toml').write_text(pack)
    (args.output / 'latest.mrpack').write_bytes(archive)
    # Prism otherwise uses its legacy INI parser and corrupts quoted commands.
    cfg = '\n'.join(['[General]', 'ConfigVersion=1.2', 'InstanceType=OneSix', 'name=WorldOfSosal Auto Update', 'iconKey=default', 'OverrideCommands=true', 'PreLaunchCommand=' + quote(f'"$INST_JAVA" -jar packwiz-installer-bootstrap.jar {base}current/pack.toml'), 'OverrideMemory=true', 'MinMemAlloc=1024', 'MaxMemAlloc=8192', ''])
    mmc = {'formatVersion': 1, 'components': [{'uid':'net.minecraft', 'version':deps['minecraft'], 'important':True}, {'uid':'net.neoforged', 'version':deps['neoforge'], 'important':True}]}
    def nbt_string(value):
        data = value.encode()
        return struct.pack('>H', len(data)) + data
    # Initial server list is seeded only during instance import, never overwritten.
    servers = b'\x0a\x00\x00\x09' + nbt_string('servers') + b'\x0a\x00\x00\x00\x01'
    servers += b'\x08' + nbt_string('name') + nbt_string('WorldOfSosal')
    servers += b'\x08' + nbt_string('ip') + nbt_string(args.server or '') + b'\x00\x00'
    with zipfile.ZipFile(args.output / 'WorldOfSosal-Prism.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('instance.cfg', cfg)
        z.writestr('mmc-pack.json', json.dumps(mmc, indent=2))
        z.writestr('.minecraft/packwiz-installer-bootstrap.jar', bootstrap)
        if args.server:
            z.writestr('.minecraft/servers.dat', servers)
    page = f'''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>WorldOfSosal</title>
<h1>WorldOfSosal — автоматическое обновление</h1>
<p>Один раз скачайте <a href="WorldOfSosal-Prism.zip">инстанс для Prism Launcher</a>, затем выберите «Добавить сборку → Импорт из zip». Разрешите команду перед запуском: она устанавливает и обновляет моды через packwiz.</p>
<p>Minecraft {html.escape(deps['minecraft'])} · NeoForge {html.escape(deps['neoforge'])} · Java 21 · память 8 ГБ.</p>
<p>{'Сервер: <code>' + html.escape(args.server) + '</code>.' if args.server else 'Адрес игрового сервера будет сообщён отдельно.'}</p>
<p>Моды и конфигурация сборки обновляются при каждом запуске. Личные настройки options.txt сохраняются. При смене Minecraft или NeoForge может потребоваться повторный запуск после обновления версии.</p>
<p><a href="latest.mrpack">Обычный mrpack без автообновлений</a> · <a href="SHA256SUMS">Контрольные суммы</a></p></html>'''
    (args.output / 'index.html').write_text(page)
    files = ['WorldOfSosal-Prism.zip', 'latest.mrpack', 'pack/pack.toml']
    (args.output / 'SHA256SUMS').write_text(''.join(f'{digest((args.output/f).read_bytes())}  {f.replace("pack/", "current/")}\n' for f in files))
    print(json.dumps({'release':release, 'minecraft':deps['minecraft'], 'neoforge':deps['neoforge'], 'managed_files':len(entries), 'server':args.server}))

if __name__ == '__main__':
    main()
