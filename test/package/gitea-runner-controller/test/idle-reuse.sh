#!/bin/dash
set -eu

. "$LOG_SH"
. "$STATE_SH"
. "$DECIDE_SH"
. "$HCLOUD_SH"
. "$GITEA_SH"
. "$CONTROLLER_SH"
. "$WEBHOOK_SH"

gcr_state_init
export GCR_ALLOWED_REPOS='hinterland/hearth'
export GCR_CONCURRENCY_CAP=2
export GCR_PER_REPO_CAP=1
NOW=2800
gcr_now_epoch() { printf '%s' "$NOW"; }

calls="$GCR_STATE_DIR/calls"
gcr_budget_add() { printf 'budget\n' >> "$calls"; }
gcr_gitea_registration_token() { printf 'token'; printf 'token\n' >> "$calls"; }
gcr_vm_create() {
  printf 'create\n' >> "$calls"
  gcr_budget_add 0.032 180
  printf '99 cx53 0.032'
}
gcr_vm_destroy() { printf 'destroy vm=%s\n' "$1" >> "$calls"; }
gcr_vm_runner_service() { printf 'runner %s vm=%s\n' "$2" "$1" >> "$calls"; }
gcr_gitea_runner_disabled() { printf 'runner-disabled %s %s\n' "$2" "$3" >> "$calls"; }

original='{"job_id":"301","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":1000,"ttl_min":480,"vm_id":71,"vm_name":"gcr-301-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 301 1 "$original"
gcr_deallocate 301 1 completed:success
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 4600)' \
  "$(gcr_record_path 301 1)" >/dev/null
idle_once="$(gcr_record_get 301 1)"
NOW=3000
gcr_deallocate 301 1 completed:success
test "$(gcr_record_get 301 1)" = "$idle_once"
NOW=2800

# Exact elapsed hours keep current boundary instead of extending another hour.
exact='{"job_id":"300","run_attempt":"1","repo":"hinterland/hearth","label":"gross-x86","created_at":1000,"ttl_min":180,"vm_id":70,"vm_name":"gcr-300-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 300 1 "$exact"
NOW=4600
gcr_deallocate 300 1 completed:success
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 4600)' \
  "$(gcr_record_path 300 1)" >/dev/null
gcr_record_del 300 1
NOW=2800
gcr_deallocate 301 1 completed:success
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 4600)' \
  "$(gcr_record_path 301 1)" >/dev/null

# Exact billing boundary must expire now, not roll into another paid hour.
NOW=4600
boundary='{"job_id":"302","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":1000,"ttl_min":480,"vm_id":74,"vm_name":"gcr-302-1","bootstrapped":true,"status":"vm_active"}'
test "$(gcr_record_idle_json "$boundary" | jq -r '.idle_expires_at')" = 4600
NOW=2800

gcr_alloc 302 1 hinterland/hearth '["gross-nix-x86-perf"]'
test "$RESPONSE_BODY" = 'reused gcr-301-1'
test ! -e "$(gcr_record_path 301 1)"
jq -e 'select(.job_id == "302" and .vm_id == 71 and
  .vm_name == "gcr-301-1" and .status == "pending_vm" and
  .created_at == 1000 and .assigned_at == 2800)' \
  "$(gcr_record_path 302 1)" >/dev/null
test "$(grep -Ec '^(budget|token|create)$' "$calls" || true)" = 0

# Failed post-start health check keeps runner disabled and record retryable.
retry_idle='{"job_id":"315","run_attempt":"1","repo":"hinterland/hearth","label":"gross-arm","created_at":1000,"ttl_min":180,"vm_id":79,"vm_name":"gcr-315-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":4600}'
gcr_record_put 315 1 "$retry_idle"
export GCR_PER_REPO_CAP=2
FAIL_HEALTH=1
gcr_vm_runner_service() {
  printf 'runner %s vm=%s\n' "$2" "$1" >> "$calls"
  [ "$2" = health ] && [ "$FAIL_HEALTH" = 1 ] && return 1
  return 0
}
gcr_alloc 316 1 hinterland/hearth '["gross-arm"]'
retry_rec="$(gcr_record_get 316 1)"
test "$(gcr_record_field "$retry_rec" bootstrapped)" = false
test "$(gcr_record_field "$retry_rec" reused_vm)" = true
grep -q '^runner start vm=79$' "$calls"
grep -q '^runner health vm=79$' "$calls"
grep -q '^runner-disabled gcr-315-1 true$' "$calls"
if grep -q '^runner-disabled gcr-315-1 false$' "$calls"; then
  printf 'unhealthy reused runner must never become schedulable\n' >&2
  exit 1
fi
FAIL_HEALTH=0
gcr_record_del 316 1

# Expired idle capacity is never claimed; normal allocation then charges once.
expired='{"job_id":"303","run_attempt":"1","repo":"hinterland/hearth","label":"gross-x86","created_at":1000,"ttl_min":180,"vm_id":72,"vm_name":"gcr-303-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":2800}'
gcr_record_put 303 1 "$expired"
NOW=2800
export GCR_PER_REPO_CAP=2
gcr_alloc 304 1 hinterland/hearth '["gross-x86"]'
test "$RESPONSE_BODY" = 'allocated gcr-304-1'
jq -e 'select(.vm_id == 99 and .status == "pending_vm")' \
  "$(gcr_record_path 304 1)" >/dev/null
test "$(grep -c '^budget$' "$calls")" = 1
test "$(grep -c '^token$' "$calls")" = 1
test "$(grep -c '^create$' "$calls")" = 1

gcr_sweep_ttl
grep -q 'destroy vm=72' "$calls"
test ! -e "$(gcr_record_path 303 1)"

# Busy pool lock defers instead of racing into paid allocation.
export GCR_CONCURRENCY_CAP=3
export GCR_PER_REPO_CAP=3
gcr_lock_acquire idle-pool
gcr_alloc 305 1 hinterland/hearth '["gross-arm"]'
test "$RESPONSE_BODY" = 'deferred: idle pool busy'
test "$(gcr_record_field "$(gcr_record_get 305 1)" status)" = deferred
test "$(grep -c '^create$' "$calls")" = 1
gcr_lock_release idle-pool

# Claim needs at least one reconcile interval before slot and hard expiry.
export GCR_RECONCILE_INTERVAL_SEC=60
near_expiry='{"job_id":"313","run_attempt":"1","repo":"hinterland/hearth","label":"gross-mixed-econ","created_at":1000,"ttl_min":180,"vm_id":78,"vm_name":"gcr-313-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":2860}'
gcr_record_put 313 1 "$near_expiry"
NOW=2801
gcr_lock_acquire "$(gcr_alloc_key 314 1)"
if gcr_claim_idle 314 1 hinterland/hearth gross-mixed-econ; then
  printf 'near-expiry VM must not be reused\n' >&2
  exit 1
fi
gcr_lock_release "$(gcr_alloc_key 314 1)"
test -e "$(gcr_record_path 313 1)"
test ! -e "$(gcr_record_path 314 1)"
gcr_record_del 313 1
NOW=2800

# Two concurrent claims transfer one VM once; original labels/name stay safe.
race_idle='{"job_id":"306","run_attempt":"1","repo":"hinterland/hearth","label":"gross-arm","created_at":1000,"ttl_min":180,"vm_id":73,"vm_name":"gcr-306-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":4600}'
gcr_record_put 306 1 "$race_idle"
claim_script="$GCR_STATE_DIR/claim.sh"
cat > "$claim_script" <<'EOF'
#!/bin/dash
set -eu
. "$STATE_SH"
gcr_now_epoch() { printf '2800'; }
key="$(gcr_alloc_key "$1" 1)"
gcr_lock_acquire "$key"
if gcr_claim_idle "$1" 1 hinterland/hearth gross-arm; then
  printf 'reused\n' > "$GCR_STATE_DIR/result-$1"
else
  printf 'missed\n' > "$GCR_STATE_DIR/result-$1"
fi
gcr_lock_release "$key"
EOF
dash "$claim_script" 307 & first=$!
dash "$claim_script" 308 & second=$!
wait "$first"
wait "$second"
reused_count=0
for result in "$GCR_STATE_DIR"/result-*; do
  [ "$(cat "$result")" = reused ] && reused_count=$((reused_count + 1))
done
test "$reused_count" = 1
test ! -e "$(gcr_record_path 306 1)"

owner=""
for job in 307 308; do
  rec="$(gcr_record_get "$job" 1)"
  if [ -n "$rec" ]; then
    test "$(gcr_record_field "$rec" vm_id)" = 73
    test "$(gcr_record_field "$rec" vm_name)" = gcr-306-1
    owner="$job"
  fi
done
test -n "$owner"

gcr_vm_list_managed() {
  printf 'list\n' >> "$GCR_STATE_DIR/list-calls"
  printf '[{"id":73,"labels":{"gcr.job-id":"306","gcr.run-attempt":"1"}}]'
}
gcr_gitea_list_runners() { printf '17 gcr-306-1\n'; }
gcr_gitea_delete_runner() { printf 'delete repo=%s runner=%s\n' "$1" "$2" >> "$calls"; }
before_destroy="$(grep -c '^destroy vm=73$' "$calls" || true)"
gcr_lock_acquire admission
gcr_sweep_orphan_vms
test ! -e "$GCR_STATE_DIR/list-calls"
gcr_lock_release admission
gcr_sweep_orphan_vms
test "$(wc -l < "$GCR_STATE_DIR/list-calls" | tr -d ' ')" = 1
gcr_sweep_stale_runners
after_destroy="$(grep -c '^destroy vm=73$' "$calls" || true)"
test "$before_destroy" = "$after_destroy"
if grep -q '^delete repo=.* runner=17$' "$calls"; then
  printf 'reused VM runner registration must not be swept as stale\n' >&2
  exit 1
fi

# Interrupted destination-first transfer leaves duplicate state, never a VM
# deletion: sweep drops superseded idle source and keeps active destination.
duplicate_idle='{"job_id":"309","run_attempt":"1","repo":"hinterland/hearth","label":"gross-arm","created_at":1000,"ttl_min":180,"vm_id":75,"vm_name":"gcr-309-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":2800}'
duplicate_active='{"job_id":"310","run_attempt":"1","repo":"hinterland/hearth","label":"gross-arm","created_at":1000,"ttl_min":180,"vm_id":75,"vm_name":"gcr-309-1","bootstrapped":true,"status":"pending_vm"}'
gcr_record_put 309 1 "$duplicate_idle"
gcr_record_put 310 1 "$duplicate_active"
gcr_sweep_ttl
test ! -e "$(gcr_record_path 309 1)"
test -e "$(gcr_record_path 310 1)"
if grep -q '^destroy vm=75$' "$calls"; then
  printf 'superseded idle record must not destroy reassigned VM\n' >&2
  exit 1
fi

# Delayed old-job in_progress delivery cannot reactivate idle ownership.
late_idle='{"job_id":"311","run_attempt":"1","repo":"hinterland/hearth","label":"gross-arm","created_at":1000,"ttl_min":180,"vm_id":76,"vm_name":"gcr-311-1","bootstrapped":true,"status":"idle_vm","idle_since":2000,"idle_expires_at":4600}'
gcr_record_put 311 1 "$late_idle"
gcr_mark_in_progress 311 1
test "$(gcr_record_field "$(gcr_record_get 311 1)" status)" = idle_vm

# Crash-stranded locks are reclaimed by dead owner PID; live contention remains.
mkdir "$GCR_STATE_DIR/jobs/.lock.stale-test"
if gcr_lock_acquire stale-test; then
  printf 'pre-existing lock must not be reclaimed\n' >&2
  exit 1
fi
rm -rf "$GCR_STATE_DIR/jobs/.lock.stale-test"
mkdir "$GCR_STATE_DIR/jobs/.lock.crashed-test"
printf '999999 1\n' > "$GCR_STATE_DIR/jobs/.lock.crashed-test/owner"
gcr_lock_acquire crashed-test
gcr_lock_release crashed-test

# Concurrent recovery of one dead lock admits exactly one owner.
mkdir "$GCR_STATE_DIR/jobs/.lock.crashed-race"
printf '999999 1\n' > "$GCR_STATE_DIR/jobs/.lock.crashed-race/owner"
reclaim_script="$GCR_STATE_DIR/reclaim.sh"
cat > "$reclaim_script" <<'EOF'
#!/bin/dash
set -eu
. "$STATE_SH"
if gcr_lock_acquire crashed-race; then
  printf 'acquired\n' > "$GCR_STATE_DIR/reclaim-$1"
  sleep 1
  gcr_lock_release crashed-race
else
  printf 'busy\n' > "$GCR_STATE_DIR/reclaim-$1"
fi
EOF
dash "$reclaim_script" first & first=$!
dash "$reclaim_script" second & second=$!
wait "$first"
wait "$second"
test "$(grep -lc '^acquired$' "$GCR_STATE_DIR"/reclaim-* | wc -l | tr -d ' ')" = 1
mkdir "$GCR_STATE_DIR/jobs/.lock.crashed-test"
printf '999999 1\n' > "$GCR_STATE_DIR/jobs/.lock.crashed-test/owner"
gcr_lock_acquire crashed-test
gcr_lock_release crashed-test

for job in 307 308 310 311; do
  gcr_record_del "$job" 1
done
ttl_record='{"job_id":"312","run_attempt":"1","repo":"hinterland/hearth","label":"gross-x86","created_at":1000,"ttl_min":180,"vm_id":77,"vm_name":"gcr-312-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 312 1 "$ttl_record"
gcr_vm_public_ip() { printf '192.0.2.%s' "$1"; }
gcr_vm_collect_diagnostics() {
  printf 'diag vm=%s job=%s reason=%s\n' "$1" "$3" "$4" >> "$calls"
}
NOW=11799
gcr_sweep_ttl
test -e "$(gcr_record_path 312 1)"
NOW=11800
gcr_sweep_ttl
test ! -e "$(gcr_record_path 312 1)"
grep -q '^diag vm=77 job=312 reason=ttl$' "$calls"
grep -q '^destroy vm=77$' "$calls"

# Admission lock serializes cap check and creation across webhook processes.
ADMISSION_STATE="$GCR_STATE_DIR/admission-state"
mkdir "$ADMISSION_STATE"
admission_script="$ADMISSION_STATE/allocate.sh"
cat > "$admission_script" <<'EOF'
#!/bin/dash
set -eu
. "$LOG_SH"
. "$STATE_SH"
. "$DECIDE_SH"
. "$HCLOUD_SH"
. "$WEBHOOK_SH"
gcr_now_epoch() { printf '2000'; }
gcr_budget_add() { printf 'budget %s\n' "$1" >> "$GCR_STATE_DIR/admission-calls"; }
gcr_gitea_registration_token() { printf token; }
gcr_vm_create() {
  sleep 1
  printf 'create %s\n' "$6" >> "$GCR_STATE_DIR/admission-calls"
  gcr_budget_add 0.032 180
  printf '%s cx53 0.032' "$6"
}
gcr_vm_destroy() { :; }
gcr_state_init
gcr_alloc "$1" 1 hinterland/hearth '["gross-x86"]'
EOF
old_state="$GCR_STATE_DIR"
GCR_STATE_DIR="$ADMISSION_STATE" \
GCR_ALLOWED_REPOS=hinterland/hearth \
GCR_CONCURRENCY_CAP=1 \
GCR_PER_REPO_CAP=1 \
dash "$admission_script" 401 & first=$!
GCR_STATE_DIR="$ADMISSION_STATE" \
GCR_ALLOWED_REPOS=hinterland/hearth \
GCR_CONCURRENCY_CAP=1 \
GCR_PER_REPO_CAP=1 \
dash "$admission_script" 402 & second=$!
wait "$first"
wait "$second"
GCR_STATE_DIR="$ADMISSION_STATE"
test "$(grep -c '^create ' "$GCR_STATE_DIR/admission-calls")" = 1
active_count="$(gcr_count_active)"
test "$active_count" = 1
deferred_count="$(grep -El '"status"[[:space:]]*:[[:space:]]*"deferred"' \
  "$GCR_STATE_DIR"/jobs/*.json | wc -l | tr -d ' ')"
test "$deferred_count" = 1
GCR_STATE_DIR="$old_state"
