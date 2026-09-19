# WorldOfSosal: Prism automatic updates

The published client entry points are:
- https://store.bfs.band/minecraft/ (BFS / Element host)
- https://store.hectic-lab.com/minecraft/world-of-sosal/ (hectic-lab)

Each site provides its own Prism ZIP with that site's update URL and matching
server address. Both installs use the same Minecraft world and modpack release.

Players import `WorldOfSosal-Prism.zip` into Prism once and approve its pre-launch
command. Before each launch, packwiz-installer reconciles the client with the
published pack: it adds, replaces, and removes managed files, checking hashes.
`options.txt` is seeded once and preserved. Pack configuration files are managed
and can be replaced. Upstream mods do not update independently of your release.
Minecraft 1.21.1, NeoForge 21.1.250, Java 21; the instance reserves up to 8 GiB.

The original `.mrpack` alone does not provide this automatic update mechanism.
Official workflow: https://packwiz.infra.link/tutorials/installing/packwiz-installer/

## Publishing a tested update

Keep the authoritative `.mrpack` in Storage Box at
`minecraft/pack/WorldOfSosal.mrpack`. For a server update, replace that archive,
set its new SHA-256 in `nixos/system/neuro/minecraft/world-of-sosal.nix`,
and rebuild/switch neuro before publishing the corresponding client export. The server importer and the
client export must consume the same archive; publishing only the client can make
it incompatible with the running server.

```sh
# Test the client and deploy the matching server release first.
python3 script/publish-prism-mirrors.py WorldOfSosal.mrpack
```

The mirror publisher creates temporary build directories and sets each server
address and update URL automatically. The builder downloads a SHA-256-pinned bootstrap from the
packwiz project's release, or accepts it via `--bootstrap /path/to/file.jar`.
External mods retain their original URLs and SHA-512 checksums. Embedded mods and
configuration are hosted with the release. Both required and optional client mods
are included, matching the current server importer's optional-mod behavior.

Publishing uploads an immutable directory, checks it if it already exists, and
atomically switches `current`. Previous directories remain available for rollback.
Do not remove a release while clients may still be reading it. Hash checks cause
an overlapping update to fail safely rather than silently accept mixed contents;
retry the launch if a publication overlapped a download.

The files live under `/var/www/store/minecraft/world-of-sosal` on `hectic-lab`,
served by the existing `store.hectic-lab.com` nginx virtual host. No nginx reload
is needed for pack updates. Keep `current/pack.toml` as the stable client URL.
The index must be alongside pack.toml: putting a release prefix in `[index].file`
also prefixes client installation paths with that directory in packwiz-installer.

If Minecraft/NeoForge versions change, update and test both the server pin and
client pack. packwiz-installer 0.5.14 understands NeoForge components in Prism's
`mmc-pack.json`; a launcher restart/relaunch may be necessary after changing them.

## Verification on 2026-09-18

- Source archive SHA-256:
  `f8c18acb9208e4592725632ae50dab4f9c308483b34fd43a6507c74fdbf8169f`.
- Public HTTPS installation into a clean Prism-format instance passed: all 141
  client mods and all overrides match the original archive. A second launch
  performed no downloads and preserved personal options.
- Direct probes of neuro public ports 25565, 25567, and 25568 timed out;
  the configured relay now provides the public entry point.
- Live WoW server reached `Done` with all 135 server mod SHA-512 hashes
  matching the same archive used for the Prism client.
- Public `store.hectic-lab.com:25568` status/ping succeeded (about 111 ms);
  a login handshake reached the online authentication encryption request.
  An authenticated Windows Prism session was subsequently verified on 2026-09-19 (see below).
- Server and tunnel are enabled at boot; relay and both NixOS configurations
  are deployed. No failed systemd units remain on neuro.
- Loader package `neoforge-1.21.1-21.1.250` built successfully in Nix.
- Automatic updater add/remove/config-update and options-preservation behavior
  tested with an actual packwiz-installer run against a controlled update fixture.

## WoW server and public entry point

The WoW map and WorldOfSosal mods share the `wowMineMap` server on neuro,
listening on 25567. There is no separate WorldOfSosal world/server on 25568.
The client pack and server both pin Minecraft 1.21.1 / NeoForge 21.1.250.
Map import runs before mod import, and both finish before Minecraft starts.

The public entry point is `store.hectic-lab.com:25568`:

```
Prism -> hectic-lab:25568 -> loopback:25577 -> SSH tunnel -> neuro:25567
```

`minecraft-wow-proxy.socket` and its socket-proxyd service run on hectic-lab.
`minecraft-wow-tunnel.service` on neuro establishes a reverse SSH forward and
reconnects after failures. A dedicated SSH identity may listen only on
127.0.0.1:25577 at the relay; it has no interactive shell or other forwarding.
Both services and firewall rules are in Nix and start on boot. The SSH client
uses an explicit AES-CTR / HMAC-SHA256-ETM / curve25519 transport profile with
IPQoS=none, tested on the neuro-to-lab route. The default profile stalled after
the handshake on this route. Both ends check peer liveness so stale listeners
are eventually released. Minecraft initially used `online-mode=true`. It now uses offline mode at the
owner's request; see the RCON and authentication section below.

For a temporary direct local tunnel, use:

```sh
ssh -NTL 0.0.0.0:25568:127.0.0.1:25567 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 neuro
```

That command exposes the local 25568 listener on all interfaces, as requested.
Use 127.0.0.1 instead of the first 0.0.0.0 if only this computer should use it.

Credentials are encrypted in `sus/neuro-minecraft.yaml` with the actual neuro
host identity and owner keys. The existing `sus/neuro.yaml` is unchanged.
The source WoW archive remains untouched in Storage Box. Import is idempotent:
an existing world with level.dat is preserved. Never delete the world to update
mods; publish/deploy a matching modpack release instead.

Useful checks:

```sh
ssh neuro systemctl status minecraft-world-import-wowMineMap \
  minecraft-modpack-import-worldOfSosal minecraft-server-wowMineMap \
  minecraft-wow-tunnel --no-pager
ssh hectic-lab systemctl status minecraft-wow-proxy.socket --no-pager
ssh neuro journalctl -u minecraft-server-wowMineMap -n 80 --no-pager
```

The initial isolated server compatibility test reached `Done` and answered the
Minecraft status/ping protocol. Its logs also contain nonfatal recipe and class
function errors from the supplied modpack; successful startup does not imply that
every recipe or RPG class feature works correctly.

The imported map metadata is `wow mine`, DataVersion 3953 (Minecraft 1.21),
spawn 0 / 68 / -32; extracted size is approximately 11.7 GiB. The archive
SHA-256 was verified before extraction.

## Windows Prism GUI verification on 2026-09-19

- Downloaded the published ZIP through the browser and imported it in Prism 8.4.
- Fixed the generated instance.cfg: ConfigVersion=1.2 is required. Without it,
  Prism selects its legacy INI parser and corrupts the quoted pre-launch command.
  The corrected ZIP is published at the same URL. Previously imported copies
  need the command corrected in Settings / Custom commands, or a fresh import.
- Used Java 21.0.4; the first packwiz download hit two transient timeouts.
  Cancelled the incomplete launch and retried successfully. All 141 downloaded
  client mod hashes match the original mrpack. NeoForge reports 202 mods when
  bundled/internal mod components are included.
- Joined store.hectic-lab.com:25568 in the actual Minecraft GUI. The server
  confirmed the authenticated join, and the client reached the Origins selection
  screen. No character origin was selected during testing.
- Tested a separate copy of the pack manifest with an inert config text file:
  launching from Prism added it; restoring the production manifest and launching
  again automatically deleted it. Existing files were reused from cache, and
  options.txt retained its checksum. The production pack contents were unchanged.
- Restored the instance's regular current/pack.toml update URL.

## Independent BFS entry point (2026-09-19)

- Server: `wow.bfs.band`; downloads: https://store.bfs.band/minecraft/.
- BFS is `bfs.poland.xray` (91.198.166.181), the host of Element.
- `minecraft-wow-tunnel-bfs` connects neuro directly to BFS. The BFS path does
  not transit hectic-lab; both tunnels have independent reconnecting services.
- Shared proxy implementation: `nixos/module/generic/minecraft-public-relay.nix`.
  Host settings remain in `minecraft-wow-proxy.nix` (hectic-lab) and
  `minecraft-wow.nix` (BFS). A dedicated HTTPS virtual host serves `store.bfs.band`. The legacy
  `bfs.band/minecraft/` URLs remain available for already imported instances.
- Downloaded BFS ZIP seeds `wow.bfs.band` and uses the stable manifest
  `https://store.bfs.band/minecraft/world-of-sosal/current/pack.toml`. It does not
  redirect installation metadata to hectic-lab. Upstream mod and Java/loader
  downloads still use their original providers (e.g. Modrinth, GitHub, Mojang).
- Existing hectic-lab instances can be migrated without reinstalling mods:
  in Edit / Settings / Custom commands, replace only the manifest URL in
  Pre-launch command with the BFS URL above. Change the multiplayer server
  address to wow.bfs.band. New users should import the ZIP from BFS.
- `script/publish-prism-mirrors.py` builds host-specific ZIPs from one archive
  and publishes both mirrors. It checks that the running neuro server's cached
  archive has the same SHA-256. Each host's switch is atomic; publication across
  two hosts is sequential, so rerun the command if it exits unsuccessfully.
- Both configurations were deployed; public Minecraft status/ping succeeds
  on BFS (~125 ms), HTTPS serves the pack, and Element/Matrix HTTP checks pass.

Clean installation through the BFS manifest passed: all 141 client mods and
all overrides match the source archive. A second updater run performed no
downloads and preserved options.txt. The public BFS login protocol reached
online authentication; the earlier full GUI login used hectic-lab.

## BFS DNS and dedicated download site (2026-09-19)

Porkbun DNS, TTL 600:

| Type | Name | Value |
| --- | --- | --- |
| A | store.bfs.band | 91.198.166.181 |
| A | wow.bfs.band | 91.198.166.181 |
| SRV | _minecraft._tcp.wow.bfs.band | 0 0 25568 wow.bfs.band |

Players enter `wow.bfs.band` without a port in Minecraft Java. In Porkbun,
SRV Priority is `0`, and Target is `0 25568 wow.bfs.band` (weight, port, host).
The root download URL https://store.bfs.band/ redirects to the WorldOfSosal page.
The NixOS virtual host obtains and renews its HTTPS certificate automatically.
The publication script now seeds this update URL and the port-free game address.
Existing BFS instances retain working legacy update URLs; switching their
pre-launch manifest to the new store host is optional. Root bfs.band remains
the existing Element entry point.

## RCON and authentication (2026-09-19)

The WoW server now has `online-mode=false`. Account authentication is disabled;
player names can be impersonated, and offline UUIDs differ from online UUIDs.
Existing inventory/permissions may require a separate UUID migration.

RCON listens on TCP 25575 on neuro; its port is not opened in the firewall or
forwarded through the public Minecraft relays. The server-specific automatic
firewall is disabled and only game port 25567 is explicitly permitted.
A random password is stored in SOPS as `minecraft/rcon-password`, injected into
server.properties at startup with mode 0600, and is absent from the Nix store.

Start a local-only SSH tunnel and leave it running:

```sh
ssh -NT -L 127.0.0.1:25575:127.0.0.1:25575 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 neuro
```

Retrieve the password in another terminal (do not paste it into logs):

```sh
ssh neuro cat /run/secrets/minecraft/rcon-password
```

Configure the RCON client with host `127.0.0.1`, port `25575`, and that password.
There is no RCON username. These changes apply to wowMineMap only.
