#!/bin/dash

die() {
  printf '%s\n' "with-attic-cache: $*" >&2
  exit 1
}

log() {
  printf '%s\n' "with-attic-cache: $*" >&2
}

positive_number() {
  case ${1:-} in
    ''|*[!0-9]*|0*) return 1 ;;
    *) return 0 ;;
  esac
}

reject_unsafe_value() {
  label=$1
  value=$2
  nl='
'
  case $value in
    *"'"*|*"\""*|*"$nl"*) die "$label contains unsupported quote or newline" ;;
  esac
}

queue_empty() {
  ! ls "$pending_dir"/* >/dev/null 2>&1 && ! ls "$uploading_dir"/* >/dev/null 2>&1
}

write_state() {
  cat > "$state_file" <<EOF
attic_bin='$attic_bin'
attic_cache='$attic_cache'
batch_file='$batch_file'
batch_size='$batch_size'
claimed_file='$claimed_file'
done_dir='$done_dir'
failed_dir='$failed_dir'
gcroots_dir='$gcroots_dir'
pending_dir='$pending_dir'
stop_file='$stop_file'
timeout_bin='$timeout_bin'
upload_backoff='$upload_backoff'
upload_failed='$upload_failed'
upload_retries='$upload_retries'
upload_timeout='$upload_timeout'
uploading_dir='$uploading_dir'
worker_interval='$worker_interval'
xdg_config_home='$xdg_config_home'
EOF
  chmod 600 "$state_file"
}

make_hook() {
  cat > "$hook" <<EOF
#!$hook_shell
set -eu
set -f
PATH='$coreutils_bin'
gcroots_dir='$gcroots_dir'
nix_bin='$nix_bin'
pending_dir='$pending_dir'
queue_dir='$queue_dir'
store_dir='$store_dir'
umask 077
mkdir -p "\$pending_dir" "\$gcroots_dir"
for path in \${OUT_PATHS:-}; do
  case "\$path" in
    "\$store_dir"/*) ;;
    *) echo "with-attic-cache hook: rejecting non-store path: \$path" >&2; exit 1 ;;
  esac
  case "\$path" in
    *.drv) echo "with-attic-cache hook: refusing drv path: \$path" >&2; exit 1 ;;
  esac
  [ -e "\$path" ] || { echo "with-attic-cache hook: missing output: \$path" >&2; exit 1; }
  base=\$(basename "\$path")
  safe=\$(printf '%s' "\$base" | tr -c 'A-Za-z0-9._-' '_')
  tmp=\$(mktemp "\$queue_dir/\$safe.XXXXXX.tmp")
  id=\$(basename "\$tmp")
  rec="\$pending_dir/\$id"
  root="\$gcroots_dir/\$id"
  "\$nix_bin" build --offline --out-link "\$root" "\$path" >/dev/null
  printf '%s\n' "\$path" > "\$tmp"
  mv "\$tmp" "\$rec"
done
EOF
  chmod 700 "$hook"
}

write_attic_config() {
  mkdir -p "$xdg_config_home/attic"
  cat > "$xdg_config_home/attic/config.toml" <<EOF
default-server = "ci"

[servers.ci]
endpoint = "$attic_endpoint"
token-file = "$token_file"
EOF
  chmod 600 "$xdg_config_home/attic/config.toml"
}

claim_batch() {
  : > "$batch_file"
  : > "$claimed_file"
  count=0
  for rec in "$pending_dir"/*; do
    [ -f "$rec" ] || continue
    name=$(basename "$rec")
    claimed="$uploading_dir/$name"
    if mv "$rec" "$claimed" 2>/dev/null; then
      path=$(sed -n '1p' "$claimed")
      printf '%s\n' "$path" >> "$batch_file"
      printf '%s\n' "$claimed" >> "$claimed_file"
      count=$((count + 1))
      [ "$count" -ge "$batch_size" ] && break
    fi
  done
  [ "$count" -gt 0 ]
}

finish_claimed() {
  while IFS= read -r claimed; do
    [ -f "$claimed" ] || continue
    name=$(basename "$claimed")
    mv "$claimed" "$done_dir/$name" 2>/dev/null || rm -f "$claimed"
    rm -f "$gcroots_dir/$name" 2>/dev/null || true
  done < "$claimed_file"
}

fail_claimed() {
  batch_id=$(date +%s).$$
  cp "$batch_file" "$failed_dir/$batch_id.paths" 2>/dev/null || true
  while IFS= read -r claimed; do
    [ -f "$claimed" ] || continue
    name=$(basename "$claimed")
    mv "$claimed" "$failed_dir/$name" 2>/dev/null || true
  done < "$claimed_file"
  touch "$upload_failed"
}

upload_once() {
  claim_batch || return 1
  attempt=1
  while [ "$attempt" -le "$upload_retries" ]; do
    if env -u ATTIC_TOKEN XDG_CONFIG_HOME="$xdg_config_home" \
      "$timeout_bin" --foreground -k 10 "$upload_timeout" \
      "$attic_bin" push --stdin --no-closure --jobs 2 "$attic_cache" \
      < "$batch_file"; then
      finish_claimed
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$upload_retries" ] && sleep "$upload_backoff"
  done
  fail_claimed
  return 2
}

worker_loop() {
  while :; do
    upload_once || true
    if [ -f "$stop_file" ] && queue_empty; then
      break
    fi
    sleep "$worker_interval"
  done
  [ ! -f "$upload_failed" ]
}

# shellcheck disable=SC2317
stop_build_group() {
  [ -n "${build_pid:-}" ] || return 0
  kill -0 "-$build_pid" 2>/dev/null || return 0
  kill -TERM "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
  i=0
  while kill -0 "-$build_pid" 2>/dev/null && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "-$build_pid" 2>/dev/null; then
    kill -KILL "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
  fi
}

wait_worker_bounded() {
  [ -n "${worker_pid:-}" ] || return 0
  touch "$stop_file" 2>/dev/null || true
  i=0
  while [ "$i" -lt "$drain_timeout" ]; do
    if ! kill -0 "$worker_pid" 2>/dev/null; then
      if wait "$worker_pid" 2>/dev/null; then
        kill -KILL "-$worker_pid" 2>/dev/null || true
        worker_pid=
        return 0
      else
        rc=$?
        kill -KILL "-$worker_pid" 2>/dev/null || true
        worker_pid=
        return "$rc"
      fi
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -n "${worker_pid:-}" ] && kill -0 "$worker_pid" 2>/dev/null; then
    kill -TERM "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "-$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    worker_pid=
    touch "$upload_failed" 2>/dev/null || true
    return 124
  fi
  return 0
}

# shellcheck disable=SC2317
on_signal() {
  signal_status=$1
  stop_build_group
  touch "$stop_file" 2>/dev/null || true
}

# shellcheck disable=SC2317
cleanup() {
  status=$?
  trap - EXIT INT TERM
  stop_build_group
  if [ -n "${worker_pid:-}" ]; then
    kill -TERM "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "-$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}

if [ "${1:-}" = "--worker" ]; then
  [ "$#" -eq 2 ] || die "usage: with-attic-cache --worker state-file"
  # shellcheck disable=SC1090
  . "$2"
  trap 'exit 143' TERM
  trap 'exit 130' INT
  worker_loop
  exit $?
fi

umask 077
[ "$#" -gt 0 ] || die "usage: with-attic-cache -- command [args...]"
[ "$1" = "--" ] || die "expected -- before command"
shift
[ "$#" -gt 0 ] || die "missing command"
[ -n "${ATTIC_TOKEN:-}" ] || die "ATTIC_TOKEN is required"

attic_endpoint=${WITH_ATTIC_ENDPOINT:-https://cache.hectic-lab.com}
attic_cache=${WITH_ATTIC_CACHE:-ci:hectic}
build_timeout=${WITH_ATTIC_BUILD_TIMEOUT:-1800}
drain_timeout=${WITH_ATTIC_DRAIN_TIMEOUT:-600}
upload_timeout=${WITH_ATTIC_UPLOAD_TIMEOUT:-120}
upload_retries=${WITH_ATTIC_UPLOAD_RETRIES:-3}
upload_backoff=${WITH_ATTIC_UPLOAD_BACKOFF:-2}
worker_interval=${WITH_ATTIC_WORKER_INTERVAL:-1}
batch_size=${WITH_ATTIC_BATCH_SIZE:-32}

positive_number "$build_timeout" || die "WITH_ATTIC_BUILD_TIMEOUT must be canonical positive seconds"
positive_number "$drain_timeout" || die "WITH_ATTIC_DRAIN_TIMEOUT must be canonical positive seconds"
positive_number "$upload_timeout" || die "WITH_ATTIC_UPLOAD_TIMEOUT must be canonical positive seconds"
positive_number "$upload_retries" || die "WITH_ATTIC_UPLOAD_RETRIES must be canonical positive"
positive_number "$upload_backoff" || die "WITH_ATTIC_UPLOAD_BACKOFF must be canonical positive seconds"
positive_number "$worker_interval" || die "WITH_ATTIC_WORKER_INTERVAL must be canonical positive seconds"
positive_number "$batch_size" || die "WITH_ATTIC_BATCH_SIZE must be canonical positive"

reject_unsafe_value WITH_ATTIC_ENDPOINT "$attic_endpoint"
reject_unsafe_value WITH_ATTIC_CACHE "$attic_cache"

case ${NIX_CONFIG:-} in
  *post-build-hook*) die "existing NIX_CONFIG post-build-hook would be replaced; refusing" ;;
esac

attic_bin=${WITH_ATTIC_ATTIC:-$ATTIC_BIN_DEFAULT}
coreutils_bin=${WITH_ATTIC_COREUTILS_BIN:-$COREUTILS_BIN_DEFAULT}
hook_shell=${WITH_ATTIC_HOOK_SHELL:-$HOOK_SHELL_DEFAULT}
nix_bin=${WITH_ATTIC_NIX:-$NIX_BIN_DEFAULT}
setsid_bin=${WITH_ATTIC_SETSID:-$SETSID_BIN_DEFAULT}
timeout_bin=${WITH_ATTIC_TIMEOUT:-$TIMEOUT_BIN_DEFAULT}
store_dir=${NIX_STORE_DIR:-/nix/store}

reject_unsafe_value WITH_ATTIC_ATTIC "$attic_bin"
reject_unsafe_value WITH_ATTIC_COREUTILS_BIN "$coreutils_bin"
reject_unsafe_value WITH_ATTIC_HOOK_SHELL "$hook_shell"
reject_unsafe_value WITH_ATTIC_NIX "$nix_bin"
reject_unsafe_value WITH_ATTIC_SETSID "$setsid_bin"
reject_unsafe_value WITH_ATTIC_TIMEOUT "$timeout_bin"
reject_unsafe_value NIX_STORE_DIR "$store_dir"

configured_hook=$(env -u ATTIC_TOKEN "$nix_bin" config show post-build-hook 2>/dev/null)
[ -z "$configured_hook" ] || die "existing Nix post-build-hook would be replaced; refusing"

tmp_parent=${TMPDIR:-/tmp}
reject_unsafe_value TMPDIR "$tmp_parent"
tmp_dir=$(mktemp -d "$tmp_parent/with-attic-cache.XXXXXX")
chmod 700 "$tmp_dir"
queue_dir="$tmp_dir/spool"
pending_dir="$queue_dir/pending"
uploading_dir="$queue_dir/uploading"
done_dir="$queue_dir/done"
failed_dir="$queue_dir/failed"
gcroots_dir="$tmp_dir/gcroots"
xdg_config_home="$tmp_dir/xdg"
token_file="$tmp_dir/attic-token"
hook="$tmp_dir/post-build-hook"
batch_file="$tmp_dir/batch.paths"
claimed_file="$tmp_dir/claimed.records"
state_file="$tmp_dir/worker.state"
stop_file="$tmp_dir/stop-worker"
upload_failed="$tmp_dir/upload-failed"
build_pid=
worker_pid=
signal_status=0
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

mkdir -p "$pending_dir" "$uploading_dir" "$done_dir" "$failed_dir" "$gcroots_dir" "$xdg_config_home"
printf '%s\n' "$ATTIC_TOKEN" > "$token_file"
chmod 600 "$token_file"
unset ATTIC_TOKEN
write_attic_config
make_hook
write_state

old_nix_config=${NIX_CONFIG:-}
if [ -n "$old_nix_config" ]; then
  NIX_CONFIG="$old_nix_config
post-build-hook = $hook"
else
  NIX_CONFIG="post-build-hook = $hook"
fi
export NIX_CONFIG

"$setsid_bin" "$0" --worker "$state_file" &
worker_pid=$!

"$setsid_bin" "$timeout_bin" -k 15 "$build_timeout" "$@" &
build_pid=$!
if wait "$build_pid"; then
  build_status=0
else
  build_status=$?
fi
stop_build_group
build_pid=

[ "$signal_status" -ne 0 ] && build_status=$signal_status
touch "$stop_file"

if wait_worker_bounded; then
  worker_status=0
else
  worker_status=$?
fi
[ "$signal_status" -ne 0 ] && build_status=$signal_status

if [ "$build_status" -eq 0 ] && [ "$worker_status" -ne 0 ]; then
  log "build succeeded but one or more uploads failed"
  exit 70
fi
if [ "$build_status" -eq 0 ] && [ -f "$upload_failed" ]; then
  log "build succeeded but one or more uploads failed"
  exit 70
fi
if [ "$build_status" -eq 0 ] && ! queue_empty; then
  log "build succeeded but final drain timed out"
  exit 71
fi
if [ "$build_status" -ne 0 ] && [ -f "$upload_failed" ]; then
  log "build failed and one or more uploads also failed"
fi
exit "$build_status"
