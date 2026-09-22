# Project Zomboid backups

`hectic.services."project-zomboid".backup` creates local backups without stopping
or pausing the server. The default schedule is every 30 minutes. Each run:

1. rsyncs `Zomboid/Saves/Multiplayer/<serverName>` and non-secret server
   settings (`SandboxVars`, spawn-points, and spawn-regions) from
   `Zomboid/Server` into a private staging tree;
2. waits five seconds and repeats the rsync to narrow the live-write window;
3. publishes a timestamped `tar.zst` archive; and
4. deletes local archives older than `backup.retentionDays`.

The service lock prevents overlapping runs. Missing save or server-config paths
skip the run through systemd `ConditionPathExists` checks.

## Consistency and secrets

This is a best-effort, crash-consistent backup. It does not stop Project
Zomboid and does not use an atomic filesystem snapshot. A backup taken during a
busy save can therefore contain files from slightly different moments; the
second rsync reduces but cannot remove this risk.

Archives do not include the generated server INI, `admin-password`,
host-generated password files, or the S3 credentials file. The server INI is
generated again during service startup; provision secret-backed values separately
after a restore.

## hectic-lab

hectic-lab runs the timer every 30 minutes and keeps local archives for 14 days:

```text
/var/lib/project-zomboid/backups/archive/
```

Check it with:

```sh
systemctl list-timers project-zomboid-backup.timer
systemctl status project-zomboid-backup.service
journalctl -u project-zomboid-backup.service
```

## Optional S3 upload

S3 upload is disabled by default. Enabling it requires `bucket`, `endpoint`,
`region`, and an absolute runtime `credentialsFile` outside `/nix/store`. The
endpoint must use HTTPS. systemd reads the environment file without executing
it; keep it root-owned and mode `0400`:

```sh
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

Set `backup.s3.prefix` to choose the object-key prefix and
`backup.s3.remoteRetentionDays` to prune old archives from that prefix. Remote
deletion runs only after a successful upload and only matches this server's
archive name prefix. Configure bucket lifecycle expiration/versioning too when
available; it remains the stronger recovery and cleanup control.

## Restore

Restoring must be done while the server is stopped so it cannot modify files
during extraction:

```sh
systemctl stop project-zomboid.service
tar --zstd --no-same-owner --no-same-permissions \
  -xf /var/lib/project-zomboid/backups/archive/<archive>.tar.zst \
  -C /var/lib/project-zomboid
chown -R project-zomboid:project-zomboid /var/lib/project-zomboid/Zomboid
systemctl start project-zomboid.service
```

Re-provision password files and secret-backed INI values before starting.
Verify the restored save and server name before allowing players to reconnect.
