#!/bin/sh
set -eu

SERVER_NAME=${SERVER_NAME:-servertest}
DATA_DIR=${DATA_DIR:-/var/lib/project-zomboid}
ARCHIVE=${1:-}

usage() {
  printf '%s\n' "Usage: $0 /path/to/project-zomboid-${SERVER_NAME}-<timestamp>.tar.zst"
  printf '%s\n' "Environment: SERVER_NAME, DATA_DIR"
}

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' 'Run as root.' >&2
  exit 1
fi

if [ -z "$ARCHIVE" ]; then
  usage >&2
  exit 2
fi

if [ ! -r "$ARCHIVE" ]; then
  printf 'Backup archive is not readable: %s\n' "$ARCHIVE" >&2
  exit 1
fi

ARCHIVE_DIR="$DATA_DIR/backups/archive"
SAVE_DIR="$DATA_DIR/Zomboid/Saves/Multiplayer/$SERVER_NAME"
SERVER_DIR="$DATA_DIR/Zomboid/Server"
TMP_LIST=$(mktemp)
ROLLBACK_ARCHIVE=''
SERVER_STOPPED=0
RESTORE_SUCCEEDED=0

cleanup() {
  rm -f "$TMP_LIST"
}

on_exit() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$SERVER_STOPPED" -eq 1 ] \
    && [ "$RESTORE_SUCCEEDED" -eq 0 ] && [ -n "$ROLLBACK_ARCHIVE" ]; then
    set +e
    rm -rf "$SAVE_DIR"
    rm -f \
      "$SERVER_DIR/${SERVER_NAME}_SandboxVars.lua" \
      "$SERVER_DIR/${SERVER_NAME}_spawnpoints.lua" \
      "$SERVER_DIR/${SERVER_NAME}_spawnregions.lua"
    tar --zstd --no-same-owner --no-same-permissions \
      -xpf "$ROLLBACK_ARCHIVE" -C "$DATA_DIR"
    chown -R project-zomboid:project-zomboid "$SAVE_DIR" "$SERVER_DIR"
    systemctl start project-zomboid.service
    systemctl start project-zomboid-backup.timer
    printf '%s\n' "Restore failed; current state restored from $ROLLBACK_ARCHIVE" >&2
  fi
  cleanup
  exit "$status"
}
trap on_exit EXIT

if ! tar --zstd -tf "$ARCHIVE" >"$TMP_LIST"; then
  printf 'Archive integrity check failed: %s\n' "$ARCHIVE" >&2
  exit 1
fi

while IFS= read -r member; do
  case "$member" in
    Zomboid/*) ;;
    *)
      printf 'Unsafe archive member: %s\n' "$member" >&2
      exit 1
      ;;
  esac
  case "$member" in
    /*|*../*)
      printf 'Path traversal member: %s\n' "$member" >&2
      exit 1
      ;;
  esac
done <"$TMP_LIST"

if ! systemctl start project-zomboid-backup.service; then
  printf '%s\n' 'Could not create fresh backup of current state.' >&2
  exit 1
fi

CURRENT_ARCHIVE=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f \
  -name "project-zomboid-$SERVER_NAME-*.tar.zst" \
  -printf '%T@ %p\n' | sort -nr | awk 'NR == 1 {sub(/^[^ ]* /, ""); print}')

if [ -z "$CURRENT_ARCHIVE" ]; then
  printf '%s\n' 'Fresh current-state backup was not found.' >&2
  exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
ROLLBACK_ARCHIVE="$ARCHIVE_DIR/project-zomboid-$SERVER_NAME-pre-restore-$stamp.tar.zst"
cp --reflink=auto "$CURRENT_ARCHIVE" "$ROLLBACK_ARCHIVE" 2>/dev/null \
  || cp "$CURRENT_ARCHIVE" "$ROLLBACK_ARCHIVE"
chmod 0600 "$ROLLBACK_ARCHIVE"
chown project-zomboid:project-zomboid "$ROLLBACK_ARCHIVE"

systemctl stop project-zomboid-backup.timer
systemctl stop project-zomboid.service
SERVER_STOPPED=1

if [ "$(systemctl show project-zomboid --property=ActiveState --value)" != inactive ]; then
  printf '%s\n' 'Project Zomboid did not stop; refusing to restore.' >&2
  exit 1
fi

rm -rf "$SAVE_DIR"
rm -f \
  "$SERVER_DIR/${SERVER_NAME}_SandboxVars.lua" \
  "$SERVER_DIR/${SERVER_NAME}_spawnpoints.lua" \
  "$SERVER_DIR/${SERVER_NAME}_spawnregions.lua"

tar --zstd --no-same-owner --no-same-permissions \
  -xpf "$ARCHIVE" -C "$DATA_DIR"
chown -R project-zomboid:project-zomboid "$SAVE_DIR" "$SERVER_DIR"

systemctl start project-zomboid.service
started=0
for _ in $(seq 1 90); do
  if [ "$(systemctl show project-zomboid --property=ActiveState --value)" = active ] \
    && [ "$(systemctl show project-zomboid --property=SubState --value)" = running ]; then
    started=1
    break
  fi
  sleep 2
done

if [ "$started" -ne 1 ]; then
  printf 'Restore completed, but service did not become healthy. Rollback: %s\n' \
    "$ROLLBACK_ARCHIVE" >&2
  exit 1
fi

systemctl start project-zomboid-backup.timer
RESTORE_SUCCEEDED=1
printf 'Restore completed.\n'
printf 'Rollback archive: %s\n' "$ROLLBACK_ARCHIVE"
