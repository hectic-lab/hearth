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

gcr_gitea_runner_disabled() { :; }

record_success='{"job_id":"201","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"0","ttl_min":480,"vm_id":51,"vm_name":"gcr-201-1","bootstrapped":true,"status":"vm_active"}'
record_failure='{"job_id":"202","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":52,"vm_name":"gcr-202-1","bootstrapped":true,"status":"vm_active"}'

gcr_record_put 201 1 "$record_success"
gcr_record_put 202 1 "$record_failure"
gcr_deallocate 201 1 completed:success
gcr_deallocate 202 1 completed:failure

grep -q 'destroy vm=52' "$calls"
grep -q 'diag vm=52 ip=192.0.2.52 job=202 reason=completed:failure' "$calls"
if grep -q 'diag vm=51' "$calls"; then
  printf 'success webhook should not collect diagnostics\n' >&2
  exit 1
fi

if grep -q 'destroy vm=51' "$calls"; then
  printf 'successful webhook VM should remain idle until billing boundary\n' >&2
  exit 1
fi
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 3600)' \
  "$(gcr_record_path 201 1)" >/dev/null
idle_once="$(gcr_record_get 201 1)"
gcr_deallocate 201 1 completed:success
test "$(gcr_record_get 201 1)" = "$idle_once"
test ! -e "$(gcr_record_path 202 1)"

calls_ip_fail="$GCR_STATE_DIR/calls-ip-fail"
calls="$calls_ip_fail"
record_ip_fail='{"job_id":"203","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":53,"vm_name":"gcr-203-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 203 1 "$record_ip_fail"

gcr_vm_public_ip() {
  return 1
}

gcr_deallocate 203 1 completed:failure

grep -q 'diag vm=53 ip= job=203 reason=completed:failure' "$calls_ip_fail"
grep -q 'destroy vm=53' "$calls_ip_fail"
test ! -e "$(gcr_record_path 203 1)"

# Terminal webhook retains ownership and capacity until DELETE succeeds.
record_delete_fail='{"job_id":"204","run_attempt":"1","repo":"hinterland/hearth","label":"nix","created_at":"1","ttl_min":480,"vm_id":54,"vm_name":"gcr-204-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 204 1 "$record_delete_fail"
gcr_vm_destroy() {
  printf 'destroy-failed vm=%s\n' "$1" >> "$calls_ip_fail"
  return 1
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
