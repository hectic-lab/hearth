#!/bin/dash
set -eu

. "$LOG_SH"
. "$STATE_SH"
. "$DECIDE_SH"
. "$HCLOUD_SH"
. "$GITEA_SH"
. "$WEBHOOK_SH"

gcr_state_init
calls="$GCR_STATE_DIR/calls"
gcr_now_epoch() { printf '1800'; }

gcr_vm_public_ip() {
  printf '192.0.2.%s' "$1"
}

gcr_vm_collect_diagnostics() {
  printf 'diag vm=%s ip=%s job=%s reason=%s\n' "$1" "$2" "$3" "$4" >> "$calls"
}

gcr_vm_destroy() {
  printf 'destroy vm=%s\n' "$1" >> "$calls"
}

gcr_vm_runner_service() {
  printf 'runner %s vm=%s\n' "$2" "$1" >> "$calls"
}

gcr_gitea_runner_disabled() {
  printf 'disabled runner=%s value=%s\n' "$2" "$3" >> "$calls"
}

record_success='{"job_id":"201","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"0","ttl_min":480,"vm_id":51,"vm_name":"gcr-201-1","bootstrapped":true,"status":"vm_active"}'
record_failure='{"job_id":"202","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":52,"vm_name":"gcr-202-1","bootstrapped":true,"status":"vm_active"}'

gcr_record_put 201 1 "$record_success"
gcr_record_put 202 1 "$record_failure"
gcr_deallocate 201 1 completed:success
gcr_deallocate 202 1 completed:failure

grep -q 'diag vm=52 ip=192.0.2.52 job=202 reason=completed:failure' "$calls"
grep -q 'runner health vm=52' "$calls"
grep -q 'disabled runner=gcr-202-1 value=true' "$calls"
grep -q 'runner stop vm=52' "$calls"
test "$(grep -E '^(diag vm=52|runner health vm=52|disabled runner=gcr-202-1|runner stop vm=52)' "$calls")" = 'diag vm=52 ip=192.0.2.52 job=202 reason=completed:failure
runner health vm=52
disabled runner=gcr-202-1 value=true
runner stop vm=52'
if grep -q 'diag vm=51' "$calls"; then
  printf 'success webhook should not collect diagnostics\n' >&2
  exit 1
fi

if grep -q 'destroy vm=51' "$calls"; then
  printf 'successful webhook VM should remain idle until billing boundary\n' >&2
  exit 1
fi
if grep -q 'destroy vm=52' "$calls"; then
  printf 'failed bootstrapped webhook VM should remain idle until billing boundary\n' >&2
  exit 1
fi
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 3600)' \
  "$(gcr_record_path 201 1)" >/dev/null
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 3601)' \
  "$(gcr_record_path 202 1)" >/dev/null
gcr_idle_record_usable "$(gcr_record_get 202 1)"
idle_once="$(gcr_record_get 201 1)"
gcr_record_del 201 1
gcr_lock_acquire "$(gcr_alloc_key 205 1)"
gcr_claim_idle 205 1 hinterland/hearth gross-nix-x86-perf
gcr_lock_release "$(gcr_alloc_key 205 1)"
jq -e 'select(.job_id == "205" and .vm_id == 52 and .status == "pending_vm" and .reused_vm == true)' \
  "$(gcr_record_path 205 1)" >/dev/null
gcr_record_del 205 1
gcr_record_put 201 1 "$idle_once"
gcr_deallocate 201 1 completed:success
test "$(gcr_record_get 201 1)" = "$idle_once"

# Cancelled terminal jobs use same retention policy without failure diagnostics.
record_cancelled='{"job_id":"207","run_attempt":"1","repo":"hinterland/hearth","label":"nix","created_at":"1","ttl_min":480,"vm_id":57,"vm_name":"gcr-207-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 207 1 "$record_cancelled"
gcr_deallocate 207 1 completed:cancelled
test "$(gcr_record_field "$(gcr_record_get 207 1)" status)" = idle_vm
if grep -q 'diag vm=57' "$calls" || grep -q 'destroy vm=57' "$calls"; then
  printf 'healthy cancelled VM must be retained without failure diagnostics\n' >&2
  exit 1
fi

calls_ip_fail="$GCR_STATE_DIR/calls-ip-fail"
calls="$calls_ip_fail"
record_ip_fail='{"job_id":"203","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":53,"vm_name":"gcr-203-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 203 1 "$record_ip_fail"

gcr_vm_public_ip() {
  return 1
}
gcr_vm_runner_service() {
  printf 'runner %s vm=%s\n' "$2" "$1" >> "$calls"
  return 1
}

gcr_deallocate 203 1 completed:failure

grep -q 'diag vm=53 ip= job=203 reason=completed:failure' "$calls_ip_fail"
grep -q 'runner health vm=53' "$calls_ip_fail"
grep -q 'destroy vm=53' "$calls_ip_fail"
test ! -e "$(gcr_record_path 203 1)"
if grep -q 'disabled runner=gcr-203-1' "$calls_ip_fail"; then
  printf 'unhealthy terminal runner must not enter idle shutdown path\n' >&2
  exit 1
fi

# Runner teardown failure destroys and retains ownership until DELETE succeeds.
record_delete_fail='{"job_id":"204","run_attempt":"1","repo":"hinterland/hearth","label":"nix","created_at":"1","ttl_min":480,"vm_id":54,"vm_name":"gcr-204-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 204 1 "$record_delete_fail"
gcr_vm_destroy() {
  printf 'destroy-failed vm=%s\n' "$1" >> "$calls_ip_fail"
  return 1
}
gcr_vm_runner_service() {
  printf 'runner %s vm=%s\n' "$2" "$1" >> "$calls"
  [ "$2" != stop ]
}
gcr_deallocate 204 1 completed:failure
cleanup_rec="$(gcr_record_get 204 1)"
test "$(gcr_record_field "$cleanup_rec" status)" = cleanup_pending
test "$(gcr_count_active)" = 1
test "$(gcr_count_active_repo hinterland/hearth)" = 1

gcr_vm_destroy() { printf 'destroy-retry vm=%s\n' "$1" >> "$calls_ip_fail"; }
key="$(gcr_alloc_key 204 1)"
gcr_lock_acquire "$key"
gcr_vm_cleanup_pending 204 1 "$(gcr_record_get 204 1)"
gcr_lock_release "$key"
test ! -e "$(gcr_record_path 204 1)"
test "$(gcr_count_active)" = 0
grep -q '^destroy-failed vm=54$' "$calls_ip_fail"
grep -q '^destroy-retry vm=54$' "$calls_ip_fail"

# Unbootstrapped terminal VMs are never retained.
gcr_vm_runner_service() { printf 'unexpected-runner %s\n' "$1" >> "$calls_ip_fail"; }
gcr_vm_destroy() { printf 'destroy-unbootstrapped vm=%s\n' "$1" >> "$calls_ip_fail"; }
record_unbootstrapped='{"job_id":"206","run_attempt":"1","repo":"hinterland/hearth","label":"nix","created_at":"1","ttl_min":480,"vm_id":56,"vm_name":"gcr-206-1","bootstrapped":false,"status":"pending_vm"}'
gcr_record_put 206 1 "$record_unbootstrapped"
gcr_deallocate 206 1 completed:failure
grep -q '^destroy-unbootstrapped vm=56$' "$calls_ip_fail"
test ! -e "$(gcr_record_path 206 1)"
if grep -q '^unexpected-runner 56$' "$calls_ip_fail"; then
  printf 'unbootstrapped VM must bypass idle teardown\n' >&2
  exit 1
fi

# Gitea emits zero-based run_attempt values for initial workflow jobs.
gcr_read_request() {
  gcr_hdr_event_type=workflow_job
  gcr_hdr_delivery=test-delivery
  gcr_hdr_signature=test-signature
  gcr_body='{"action":"queued","workflow_job":{"id":331,"run_attempt":0,"labels":["nix"]},"repository":{"full_name":"hinterland/hearth"}}'
}
gcr_verify_signature() { :; }
gcr_alloc() {
  printf '%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" > "$GCR_STATE_DIR/allocation"
  RESPONSE_CODE=202
  RESPONSE_BODY=allocated
}
gcr_respond() { printf '%s:%s\n' "$1" "$2" > "$GCR_STATE_DIR/response"; }

gcr_handle_webhook
test "$(cat "$GCR_STATE_DIR/allocation")" = '331:0:hinterland/hearth:["nix"]'
test "$(cat "$GCR_STATE_DIR/response")" = '202:allocated'
