#!/bin/dash
set -eu

. "$LOG_SH"
. "$STATE_SH"
. "$DECIDE_SH"
. "$HCLOUD_SH"
. "$GITEA_SH"
. "$CONTROLLER_SH"

gcr_state_init
calls="$GCR_STATE_DIR/calls"
gcr_now_epoch() { printf '1800'; }

gcr_gitea_job_state() {
  case "$2" in
    101) printf 'completed:success' ;;
    102) printf 'completed:failure' ;;
    *) return 1 ;;
  esac
}

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

record_success='{"job_id":"101","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"0","ttl_min":480,"vm_id":41,"vm_name":"gcr-101-1","bootstrapped":true,"status":"vm_active"}'
record_failure='{"job_id":"102","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":42,"vm_name":"gcr-102-1","bootstrapped":true,"status":"vm_active"}'

gcr_record_put 101 1 "$record_success"
gcr_record_put 102 1 "$record_failure"
gcr_reap_finished_jobs

grep -q 'destroy vm=42' "$calls"
grep -q 'diag vm=42 ip=192.0.2.42 job=102 reason=completed:failure' "$calls"
if grep -q 'diag vm=41' "$calls"; then
  printf 'success job should not collect diagnostics\n' >&2
  exit 1
fi

if grep -q 'destroy vm=41' "$calls"; then
  printf 'successful job VM should remain idle until billing boundary\n' >&2
  exit 1
fi
jq -e 'select(.status == "idle_vm" and .idle_expires_at == 3600)' \
  "$(gcr_record_path 101 1)" >/dev/null
idle_once="$(gcr_record_get 101 1)"
gcr_reap_finished_jobs
test "$(gcr_record_get 101 1)" = "$idle_once"
test ! -e "$(gcr_record_path 102 1)"

# Reaper keeps cleanup ownership after DELETE failure and retries next sweep.
record_delete_fail='{"job_id":"104","run_attempt":"1","repo":"hinterland/hearth","label":"nix","created_at":"1","ttl_min":480,"vm_id":44,"vm_name":"gcr-104-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 104 1 "$record_delete_fail"
gcr_gitea_job_state() {
  case "$2" in
    104) printf 'completed:failure' ;;
    *) return 1 ;;
  esac
}
gcr_vm_destroy() {
  printf 'destroy-failed vm=%s\n' "$1" >> "$calls"
  return 1
}
gcr_reap_finished_jobs
test "$(gcr_record_field "$(gcr_record_get 104 1)" status)" = cleanup_pending
test "$(gcr_count_active)" = 1

gcr_vm_destroy() { printf 'destroy-retry vm=%s\n' "$1" >> "$calls"; }
gcr_sweep_cleanup_pending
test ! -e "$(gcr_record_path 104 1)"
grep -q '^destroy-failed vm=44$' "$calls"
grep -q '^destroy-retry vm=44$' "$calls"

calls_ip_fail="$GCR_STATE_DIR/calls-ip-fail"
calls="$calls_ip_fail"
record_ip_fail='{"job_id":"103","run_attempt":"1","repo":"hinterland/hearth","label":"gross-nix-x86-perf","created_at":"1","ttl_min":480,"vm_id":43,"vm_name":"gcr-103-1","bootstrapped":true,"status":"vm_active"}'
gcr_record_put 103 1 "$record_ip_fail"

gcr_gitea_job_state() {
  case "$2" in
    103) printf 'completed:failure' ;;
    *) return 1 ;;
  esac
}

gcr_vm_public_ip() {
  return 1
}

gcr_vm_destroy() {
  printf 'destroy vm=%s\n' "$1" >> "$calls"
}

gcr_reap_finished_jobs

grep -q 'diag vm=43 ip= job=103 reason=completed:failure' "$calls_ip_fail"
grep -q 'destroy vm=43' "$calls_ip_fail"
test ! -e "$(gcr_record_path 103 1)"
