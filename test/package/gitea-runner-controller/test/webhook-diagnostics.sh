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

gcr_vm_public_ip() {
  printf '192.0.2.%s' "$1"
}

gcr_vm_collect_diagnostics() {
  printf 'diag vm=%s ip=%s job=%s reason=%s\n' "$1" "$2" "$3" "$4" >> "$calls"
}

gcr_vm_destroy() {
  printf 'destroy vm=%s\n' "$1" >> "$calls"
}

record_success='{"job_id":"201","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":51,"vm_name":"gcr-201-1","bootstrapped":true,"status":"vm_active"}'
record_failure='{"job_id":"202","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":52,"vm_name":"gcr-202-1","bootstrapped":true,"status":"vm_active"}'

gcr_record_put 201 1 "$record_success"
gcr_record_put 202 1 "$record_failure"
gcr_deallocate 201 1 completed:success
gcr_deallocate 202 1 completed:failure

grep -q 'destroy vm=51' "$calls"
grep -q 'destroy vm=52' "$calls"
grep -q 'diag vm=52 ip=192.0.2.52 job=202 reason=completed:failure' "$calls"
if grep -q 'diag vm=51' "$calls"; then
  printf 'success webhook should not collect diagnostics\n' >&2
  exit 1
fi

test ! -e "$(gcr_record_path 201 1)"
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
