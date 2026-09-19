# Current Minecraft access (2026-09-18)

WorldOfSosal on the WoW map uses `store.hectic-lab.com:25568` publicly.
The game server is `neuro:25567`; a restricted persistent reverse SSH tunnel
connects it to the public relay. See `docs/minecraft-prism.md` and the Nix modules
`minecraft/public-tunnel.nix` / `hectic-lab/minecraft-wow-proxy.nix`.

Verified LAN: neuro is `192.168.88.10`, gateway `192.168.88.1`.
SSH access is `95.31.254.84:34457`. Direct external Minecraft TCP probes timed out,
and no UPnP IGD was discovered. The old TP-Link network and manual port-forward
instructions below describe the previous network, not the active configuration.

---

# Router Access (TP-Link)

The server `neuro` is behind a NAT router at `192.168.0.1`.

## Network Info

| Device | IP |
|--------|-----|
| Router (TP-Link) | 192.168.0.1 |
| neuro (internal) | 192.168.0.10 |
| neuro (external) | 95.31.254.84 |

## Access Router Admin Panel

The router blocks requests with non-local `Host` headers, so SSH port forwarding
with `-L` returns 403. Use a SOCKS proxy instead:

1. Start SSH SOCKS proxy:
   ```sh
   ssh -D 1080 neuro
   ```

2. Launch browser with SOCKS proxy:
   ```sh
   nix run nixpkgs#chromium -- --proxy-server="socks5://localhost:1080"
   # or
   nix run nixpkgs#firefox -- # then configure manually (see below)
   ```

3. Navigate to **http://192.168.0.1**

### Firefox Manual Configuration

1. Settings -> Network Settings -> Settings...
2. Select "Manual proxy configuration"
3. SOCKS Host: `localhost`, Port: `1080`, SOCKS v5
4. Click OK

## Port Forwarding

Ports that need to be forwarded from router to `192.168.0.10`:

| External Port | Internal Port | Protocol | Service |
|---------------|---------------|----------|---------|
| 22 | 22 | TCP | SSH |
| 80 | 80 | TCP | HTTP |
| 443 | 443 | TCP | HTTPS |
| 4443 | 4443 | TCP | Jitsi |
| 5222 | 5222 | TCP | XMPP (c2s) |
| 5269 | 5269 | TCP | XMPP (s2s) |
| 10000 | 10000 | UDP | Jitsi Videobridge |
| 25565 | 25565 | TCP | Minecraft |
| 25567 | 25567 | TCP | Minecraft WoW Mine map |
| 25568 | 25568 | TCP | Minecraft World of Sosal |

## Troubleshooting

Check if ports are open externally:
```sh
nix run nixpkgs#nmap -- -Pn -p 80,443 95.31.254.84
```

Expected: `open` (not `filtered`)
