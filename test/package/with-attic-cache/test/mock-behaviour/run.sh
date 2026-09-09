#!/bin/dash
set -eu

make_env() {
  root=$(mktemp -d)
  store="$root/store"
  bin="$root/bin"
  log="$root/log"
  test_shell=$(command -v dash)
  mkdir -p "$store" "$bin"
  : > "$log"

  printf '#!%s\n' "$test_shell" > "$bin/nix"
  cat >> "$bin/nix" <<'EOS'
set -eu
if [ "$1" = config ] && [ "$2" = show ] && [ "$3" = post-build-hook ]; then
  [ "${NIX_CONFIG_FAIL:-}" = 1 ] && exit 12
  [ "${NIX_CONFIGURED_HOOK:-}" = 1 ] && printf '/configured/hook\n'
  exit 0
fi
if [ "$1" = build ] && [ "$2" = --offline ] && [ "$3" = --out-link ]; then
  root=$4
  path=$5
  mkdir -p "$(dirname "$root")"
  ln -s "$path" "$root"
  printf 'gcroot %s -> %s\n' "$root" "$path" >> "$TEST_LOG"
  exit 0
fi
exit 2
EOS
  chmod +x "$bin/nix"

  printf '#!%s\n' "$test_shell" > "$bin/attic"
  cat >> "$bin/attic" <<'EOS'
set -eu
[ "${ATTIC_TOKEN+x}" ] && { echo token leaked to attic env >&2; exit 41; }
case "$*" in *SECRET*) echo token leaked to argv >&2; exit 42 ;; esac
config="$XDG_CONFIG_HOME/attic/config.toml"
grep -q 'token-file = ' "$config" || exit 43
! grep -q SECRET "$config" || exit 44
token_file=$(sed -n 's/token-file = "\(.*\)"/\1/p' "$config")
mode=$(stat -c '%a' "$token_file")
[ "$mode" = 600 ] || { echo "bad token mode $mode" >&2; exit 45; }
[ "$(cat "$token_file")" = SECRET ] || exit 46
tmp_root=$(dirname "$XDG_CONFIG_HOME")
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in *.drv) echo drv queued >&2; exit 47 ;; esac
  found=0
  tries=0
  while [ "$tries" -lt 20 ]; do
    for root in "$tmp_root/gcroots"/*; do
      [ -L "$root" ] || continue
      [ "$(readlink "$root")" = "$path" ] && found=1
    done
    [ "$found" -eq 1 ] && break
    tries=$((tries + 1))
    sleep 0.1
  done
  [ "$found" -eq 1 ] || { echo "missing gcroot for $path" >&2; exit 48; }
  printf 'upload %s\n' "$path" >> "$TEST_LOG"
done
if [ "${ATTIC_HANG:-}" = 1 ]; then
  trap '' TERM
  sleep 60 &
  printf '%s\n' "$!" > "$TEST_ROOT/attic-grandchild.pid"
  wait
fi
if [ "${ATTIC_FAIL_MODE:-}" = transient ]; then
  count_file="$TEST_ROOT/transient-count"
  count=0
  [ -f "$count_file" ] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  [ "$count" -eq 1 ] && exit 9
fi
[ "${ATTIC_FAIL_MODE:-}" = permanent ] && exit 10
exit 0
EOS
  chmod +x "$bin/attic"
}

common_env() {
  export ATTIC_TOKEN=SECRET
  export NIX_STORE_DIR="$store"
  export TEST_LOG="$log"
  export TEST_ROOT="$root"
  export WITH_ATTIC_ATTIC="$bin/attic"
  export WITH_ATTIC_NIX="$bin/nix"
  export WITH_ATTIC_BUILD_TIMEOUT=5
  export WITH_ATTIC_DRAIN_TIMEOUT=3
  export WITH_ATTIC_UPLOAD_TIMEOUT=2
  export WITH_ATTIC_UPLOAD_RETRIES=2
  export WITH_ATTIC_UPLOAD_BACKOFF=1
  export WITH_ATTIC_WORKER_INTERVAL=1
  export WITH_ATTIC_BATCH_SIZE=64
}

make_command() {
  printf '#!%s\n' "$test_shell" > "$bin/build-command"
  cat >> "$bin/build-command" <<'EOS'
set -eu
[ "${ATTIC_TOKEN+x}" ] && { echo token leaked to build env >&2; exit 31; }
hook=$(printf '%s\n' "$NIX_CONFIG" | sed -n 's/^post-build-hook = //p')
[ -x "$hook" ] || exit 32
mkdir -p "$NIX_STORE_DIR/aaa-out" "$NIX_STORE_DIR/bbb-out" "$NIX_STORE_DIR/ccc-out.drv"
OUT_PATHS="$NIX_STORE_DIR/aaa-out $NIX_STORE_DIR/bbb-out" "$hook"
if OUT_PATHS="$NIX_STORE_DIR/ccc-out.drv" "$hook" 2>/dev/null; then
  echo drv accepted >&2
  exit 33
fi
printf 'build ok\n' >> "$TEST_LOG"
exit "${BUILD_EXIT:-0}"
EOS
  chmod +x "$bin/build-command"
}

make_concurrent_command() {
  printf '#!%s\n' "$test_shell" > "$bin/build-command"
  cat >> "$bin/build-command" <<'EOS'
set -eu
hook=$(printf '%s\n' "$NIX_CONFIG" | sed -n 's/^post-build-hook = //p')
for n in 1 2 3 4 5; do
  mkdir -p "$NIX_STORE_DIR/out-$n"
  OUT_PATHS="$NIX_STORE_DIR/out-$n" "$hook" &
done
wait
EOS
  chmod +x "$bin/build-command"
}

make_slow_command() {
  printf '#!%s\n' "$test_shell" > "$bin/build-command"
  cat >> "$bin/build-command" <<'EOS'
trap 'printf terminated >> "$TEST_LOG"; exit 99' TERM
sleep 10
EOS
  chmod +x "$bin/build-command"
}

make_signal_command() {
  printf '#!%s\n' "$test_shell" > "$bin/build-command"
  cat >> "$bin/build-command" <<'EOS'
set -eu
hook=$(printf '%s\n' "$NIX_CONFIG" | sed -n 's/^post-build-hook = //p')
mkdir -p "$NIX_STORE_DIR/signal-out"
OUT_PATHS="$NIX_STORE_DIR/signal-out" "$hook"
trap '' TERM
sleep 60 &
printf '%s\n' "$!" > "$TEST_ROOT/build-grandchild.pid"
wait
EOS
  chmod +x "$bin/build-command"
}

make_env
common_env
make_command
with-attic-cache -- "$bin/build-command"
assert_file_contains "multiple outputs uploaded" "$log" 'upload .*/aaa-out'
assert_file_contains "space separated outputs uploaded" "$log" 'upload .*/bbb-out'
assert_file_contains "hook excluded drv path" "$log" 'build ok'
assert_file_contains "gcroot registered" "$log" 'gcroot .*aaa-out'

make_env
common_env
make_command
with-attic-cache -- "$bin/build-command"
if grep -q SECRET "$log"; then
  fail "token appeared in test log"
fi
pass "token absent from command logs"

make_env
common_env
make_concurrent_command
with-attic-cache -- "$bin/build-command"
uploads=$(grep -c '^upload ' "$log")
[ "$uploads" -eq 5 ] || fail "concurrent producers uploaded $uploads paths, expected 5"
pass "concurrent producers"

make_env
common_env
make_command
export ATTIC_FAIL_MODE=transient
with-attic-cache -- "$bin/build-command"
[ "$(cat "$root/transient-count")" -eq 2 ] || fail "transient retry count"
pass "transient retry"
unset ATTIC_FAIL_MODE

make_env
common_env
make_command
export ATTIC_FAIL_MODE=permanent
export WITH_ATTIC_DRAIN_TIMEOUT=4
if with-attic-cache -- "$bin/build-command"; then
  fail "permanent upload failure succeeded"
fi
[ "$(grep -c '^upload ' "$log")" -le 4 ] || fail "permanent failure retried indefinitely"
pass "permanent upload failure is nonzero after successful build"
unset ATTIC_FAIL_MODE

make_env
common_env
make_command
export ATTIC_FAIL_MODE=permanent
export BUILD_EXIT=23
set +e
with-attic-cache -- "$bin/build-command"
status=$?
set -e
[ "$status" -eq 23 ] || fail "build failure status preserved: $status"
pass "build failure status preserved while drain still runs"
unset ATTIC_FAIL_MODE BUILD_EXIT

make_env
common_env
make_command
unset ATTIC_TOKEN
if with-attic-cache -- "$bin/build-command" 2> "$root/missing.err"; then
  fail "missing token accepted"
fi
assert_file_contains "missing token rejected" "$root/missing.err" 'ATTIC_TOKEN is required'

make_env
common_env
make_slow_command
export WITH_ATTIC_BUILD_TIMEOUT=1
set +e
with-attic-cache -- "$bin/build-command"
status=$?
set -e
[ "$status" -ne 0 ] || fail "timeout command succeeded"
pass "bounded timeout returns nonzero"

make_env
common_env
make_command
export WITH_ATTIC_BUILD_TIMEOUT=0
if with-attic-cache -- "$bin/build-command" 2> "$root/knob.err"; then
  fail "invalid timeout accepted"
fi
assert_file_contains "positive number validation" "$root/knob.err" 'WITH_ATTIC_BUILD_TIMEOUT must be canonical positive'

make_env
common_env
make_command
export WITH_ATTIC_BUILD_TIMEOUT=00
if with-attic-cache -- "$bin/build-command" 2> "$root/zero.err"; then
  fail "all-zero timeout accepted"
fi
assert_file_contains "all-zero rejected" "$root/zero.err" 'canonical positive'

make_env
common_env
make_command
export WITH_ATTIC_BUILD_TIMEOUT=08
if with-attic-cache -- "$bin/build-command" 2> "$root/octal.err"; then
  fail "leading-zero timeout accepted"
fi
assert_file_contains "leading zero rejected" "$root/octal.err" 'canonical positive'

make_env
common_env
make_command
export NIX_CONFIG='post-build-hook = /already/configured'
if with-attic-cache -- "$bin/build-command" 2> "$root/hook.err"; then
  fail "existing hook accepted"
fi
assert_file_contains "existing hook refused" "$root/hook.err" 'existing NIX_CONFIG post-build-hook'

make_env
common_env
make_command
unset NIX_CONFIG
export NIX_CONFIGURED_HOOK=1
if with-attic-cache -- "$bin/build-command" 2> "$root/config-hook.err"; then
  fail "configured hook accepted"
fi
assert_file_contains "configured hook refused" "$root/config-hook.err" 'existing Nix post-build-hook'
unset NIX_CONFIGURED_HOOK

make_env
common_env
make_command
export NIX_CONFIG_FAIL=1
if with-attic-cache -- "$bin/build-command" 2> "$root/config-fail.err"; then
  fail "nix config failure ignored"
fi
unset NIX_CONFIG_FAIL
pass "nix config failure is fatal"

make_env
common_env
make_command
export WITH_ATTIC_ENDPOINT='https://cache.example/"bad"'
if with-attic-cache -- "$bin/build-command" 2> "$root/quote.err"; then
  fail "unsafe endpoint accepted"
fi
assert_file_contains "unsafe endpoint rejected" "$root/quote.err" 'unsupported quote or newline'
unset WITH_ATTIC_ENDPOINT

make_env
common_env
make_signal_command
export WITH_ATTIC_BUILD_TIMEOUT=30
export WITH_ATTIC_DRAIN_TIMEOUT=5
with-attic-cache -- "$bin/build-command" &
wrapper=$!
i=0
while ! grep -q 'upload .*/signal-out' "$log" && [ "$i" -lt 20 ]; do
  sleep 0.2
  i=$((i + 1))
done
kill -TERM "$wrapper"
set +e
wait "$wrapper"
status=$?
set -e
[ "$status" -eq 143 ] || fail "TERM status $status, expected 143"
assert_file_contains "TERM drains queued output" "$log" 'upload .*/signal-out'
if [ -f "$root/build-grandchild.pid" ] && kill -0 "$(cat "$root/build-grandchild.pid")" 2>/dev/null; then
  fail "build grandchild survived TERM cleanup"
fi
pass "TERM cleanup kills build descendants"

make_env
common_env
make_command
export ATTIC_HANG=1
export WITH_ATTIC_DRAIN_TIMEOUT=1
export WITH_ATTIC_UPLOAD_TIMEOUT=1
export WITH_ATTIC_UPLOAD_RETRIES=1
if with-attic-cache -- "$bin/build-command"; then
  fail "hung attic returned success"
fi
if [ -f "$root/attic-grandchild.pid" ]; then
  child=$(cat "$root/attic-grandchild.pid")
  i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    fail "attic grandchild survived worker cleanup"
  fi
fi
pass "hung attic descendants cleaned"
unset ATTIC_HANG

make_env
common_env
real_setsid=$(command -v setsid)
printf '#!%s\n' "$test_shell" > "$bin/setsid"
cat >> "$bin/setsid" <<EOS
if [ "\${2:-}" = --worker ]; then
  exit 42
fi
exec "$real_setsid" "\$@"
EOS
chmod +x "$bin/setsid"
export WITH_ATTIC_SETSID="$bin/setsid"
set +e
with-attic-cache -- true
status=$?
set -e
[ "$status" -eq 70 ] || fail "worker startup failure was lost: $status"
pass "worker startup failure propagates even with an empty queue"
unset WITH_ATTIC_SETSID
