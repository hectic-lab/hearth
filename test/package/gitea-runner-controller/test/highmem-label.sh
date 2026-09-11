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
export GCR_ALLOWED_REPOS='hectic-lab/util.nix'
export GCR_IMAGE_ID='313131'
export GCR_NIX_IMAGE_ID='424242'

test "$(gcr_label_ttl ubuntu-latest)" = '180'
test "$(gcr_label_ttl nix)" = '480'
test "$(gcr_decide ubuntu-latest hectic-lab/util.nix)" = 'cx23 180 0.004'
test "$(gcr_decide nix hectic-lab/util.nix)" = 'cx23 480 0.004'
standard_candidates='cx23 nbg1 amd64
cx23 fsn1 amd64
cx23 hel1 amd64
cx33 nbg1 amd64
cx33 fsn1 amd64
cx33 hel1 amd64
cx43 nbg1 amd64
cx43 fsn1 amd64
cx43 hel1 amd64
cx53 nbg1 amd64
cx53 fsn1 amd64
cx53 hel1 amd64'
test "$(gcr_label_candidates ubuntu-latest)" = "$standard_candidates"
test "$(gcr_label_candidates nix)" = "$standard_candidates"
test "$(gcr_image_id_for_arch amd64 ubuntu-latest)" = '313131'
test "$(gcr_image_id_for_arch amd64 nix)" = '424242'

profile="$(gcr_decide gross-nix-x86-highmem hectic-lab/util.nix)"
test "$profile" = 'ccx53 480 0.8550'
test "$(gcr_label_ttl gross-nix-x86-highmem)" = '480'

candidates="$(gcr_label_candidates gross-nix-x86-highmem)"
expected='ccx53 nbg1 amd64
ccx53 fsn1 amd64
ccx53 hel1 amd64'
test "$candidates" = "$expected"

if printf '%s\n' "$candidates" | grep -Eq '(^| )c[axp]x| cx[0-9]'; then
  printf 'highmem candidates must not downgrade from ccx53\n' >&2
  exit 1
fi
if printf '%s\n' "$candidates" | grep -Evq '^ccx53 (nbg1|fsn1|hel1) amd64$'; then
  printf 'highmem candidates must be ccx53 amd64 in allowed regions only\n' >&2
  exit 1
fi

export GCR_BUDGET_EUR_MONTHLY='6.83'
if gcr_budget_can_add 0.8550 480; then
  printf 'highmem full-TTL reservation must obey budget cap\n' >&2
  exit 1
fi
if gcr_budget_write "$GCR_STATE_DIR/missing/budget" 1 2>/dev/null; then
  printf 'budget writes must propagate failures\n' >&2
  exit 1
fi
rm -f "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"
export GCR_BUDGET_EUR_MONTHLY='10'

calls="$GCR_STATE_DIR/hcloud-calls"
sleep() { :; }
gcr_hcloud_token() { printf token; }
gcr_hcloud_req() {
  method="$1"; path="$2"; body="${3:-}"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  if [ "$method" = GET ]; then
    printf '{"servers":[]}\n' > "$GCR_LAST_BODY"
    GCR_LAST_HTTP=200
    return 0
  fi
  test "$path" = /servers
  printf '%s\n' "$body" | jq -c . >> "$calls"
  count="$(wc -l < "$calls" | tr -d ' ')"
  case "$count" in
    1|2) GCR_LAST_HTTP=412; return 1 ;;
    3) GCR_LAST_HTTP=201; printf '{"server":{"id":9001}}\n' > "$GCR_LAST_BODY"; return 0 ;;
    *) return 1 ;;
  esac
}

created="$(gcr_vm_create gcr-9001-1 gross-nix-x86-highmem ccx53 480 reg-token 9001 1 hectic-lab/util.nix)"
test "$created" = '9001 ccx53 0.8550'
test "$(wc -l < "$calls" | tr -d ' ')" = '3'
jq -e 'select(.server_type == "ccx53" and .location == "nbg1" and .labels["gcr.arch"] == "amd64" and .labels["gcr.label"] == "gross-nix-x86-highmem" and .labels["gcr.ttl-min"] == "480")' "$calls" >/dev/null
jq -e 'select(.server_type == "ccx53" and .location == "fsn1" and .labels["gcr.arch"] == "amd64")' "$calls" >/dev/null
jq -e 'select(.server_type == "ccx53" and .location == "hel1" and .labels["gcr.arch"] == "amd64")' "$calls" >/dev/null
if jq -e 'select(.server_type != "ccx53" or .labels["gcr.arch"] != "amd64")' "$calls" >/dev/null; then
  printf 'highmem VM creation attempted non-ccx53 or non-amd64 candidate\n' >&2
  exit 1
fi

# Standard allocation charges actual fallback type after cx23 capacity failures.
rm -f "$calls" "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"
export GCR_BUDGET_EUR_MONTHLY='10'
gcr_gitea_registration_token() { printf token; }
gcr_hcloud_req() {
  method="$1"; path="$2"; body="${3:-}"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  if [ "$method" = GET ]; then
    printf 'lookup\n' >> "$GCR_STATE_DIR/lookups"
    printf '{"servers":[]}\n' > "$GCR_LAST_BODY"
    GCR_LAST_HTTP=200
    return 0
  fi
  test "$path" = /servers
  printf '%s\n' "$body" | jq -c . >> "$calls"
  count="$(wc -l < "$calls" | tr -d ' ')"
  case "$count" in
    1|2|3) GCR_LAST_HTTP=412; return 1 ;;
    4) GCR_LAST_HTTP=201; printf '{"server":{"id":9002}}\n' > "$GCR_LAST_BODY"; return 0 ;;
    *) return 1 ;;
  esac
}

gcr_alloc 9002 1 hectic-lab/util.nix '["nix"]'
test "$RESPONSE_CODE" = 202
test "$RESPONSE_BODY" = 'allocated gcr-9002-1'
test "$(wc -l < "$calls" | tr -d ' ')" = '4'
test "$(wc -l < "$GCR_STATE_DIR/lookups" | tr -d ' ')" = '3'
jq -e -s 'map(.server_type) == ["cx23", "cx23", "cx23", "cx33"]' "$calls" >/dev/null
test "$(gcr_server_hourly_rate cx33)" = '0.008'
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0640'

# Ambiguous 5xx response adopts only exact deterministic managed identity.
gcr_record_del 9002 1
rm -f "$calls" "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"
gcr_hcloud_req() {
  method="$1"; body="${3:-}"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  if [ "$method" = POST ]; then
    printf '%s\n' "$body" | jq -c . >> "$calls"
    GCR_LAST_HTTP=000
    return 1
  fi
  GCR_LAST_HTTP=200
  printf '%s\n' '{"servers":[{"id":9010,"name":"gcr-9010-1","server_type":{"name":"cx23"},"labels":{"gitea-runner-controller":"managed","gcr.job-id":"9010","gcr.run-attempt":"1","gcr.label":"nix","gcr.location":"nbg1","gcr.arch":"amd64"}}]}' > "$GCR_LAST_BODY"
}
gcr_alloc 9010 1 hectic-lab/util.nix '["nix"]'
test "$RESPONSE_BODY" = 'allocated gcr-9010-1'
test "$(wc -l < "$calls" | tr -d ' ')" = 1
found_rec="$(gcr_record_get 9010 1)"
test "$(gcr_record_field "$found_rec" status)" = pending_vm
test "$(gcr_record_field "$found_rec" vm_id)" = 9010
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0320'

# Ambiguous POST plus failed lookup retains reservation and blocks fallback;
# reconciler adopts a later exact identity without deleting or refunding it.
gcr_record_del 9010 1
rm -f "$calls" "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')" "$GCR_STATE_DIR/lookups"
gcr_hcloud_req() {
  method="$1"; body="${3:-}"
  if [ "$method" = POST ]; then
    printf '%s\n' "$body" | jq -c . >> "$calls"
    GCR_LAST_HTTP=500
    return 1
  fi
  printf 'lookup-failed\n' >> "$GCR_STATE_DIR/lookups"
  GCR_LAST_HTTP=503
  return 1
}
gcr_alloc 9012 1 hectic-lab/util.nix '["nix"]'
test "$RESPONSE_BODY" = 'VM creation pending recovery'
test "$(wc -l < "$calls" | tr -d ' ')" = 1
ambiguous_rec="$(gcr_record_get 9012 1)"
test "$(gcr_record_field "$ambiguous_rec" status)" = create_ambiguous
test "$(gcr_record_field "$ambiguous_rec" budget_rate)" = 0.004
test "$(gcr_count_active)" = 1
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0320'
gcr_sweep_create_ambiguous
test "$(gcr_record_field "$(gcr_record_get 9012 1)" status)" = create_ambiguous
test "$(wc -l < "$calls" | tr -d ' ')" = 1

gcr_hcloud_req() {
  test "$1" = GET
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  GCR_LAST_HTTP=200
  printf '%s\n' '{"servers":[{"id":9012,"name":"gcr-9012-1","server_type":{"name":"cx23"},"labels":{"gitea-runner-controller":"managed","gcr.job-id":"9012","gcr.run-attempt":"1","gcr.label":"nix","gcr.location":"nbg1","gcr.arch":"amd64"}}]}' > "$GCR_LAST_BODY"
}
gcr_vm_destroy() { printf 'unexpected-destroy %s\n' "$1" >> "$GCR_STATE_DIR/ambiguity-destroys"; return 1; }
gcr_sweep_create_ambiguous
recovered_rec="$(gcr_record_get 9012 1)"
test "$(gcr_record_field "$recovered_rec" status)" = pending_vm
test "$(gcr_record_field "$recovered_rec" vm_id)" = 9012
test "$(gcr_record_field "$recovered_rec" server_type)" = cx23
test "$(gcr_record_field "$recovered_rec" budget_rate)" = 0.004
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0320'
test ! -e "$GCR_STATE_DIR/ambiguity-destroys"
gcr_record_del 9012 1
rm -f "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"

# Fallback candidates exceeding remaining budget never reach Hetzner.
rm -f "$calls" "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"
export GCR_BUDGET_EUR_MONTHLY='0.05'
gcr_hcloud_req() {
  method="$1"; path="$2"; body="${3:-}"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  if [ "$method" = GET ]; then
    printf '{"servers":[]}\n' > "$GCR_LAST_BODY"
    GCR_LAST_HTTP=200
    return 0
  fi
  test "$path" = /servers
  printf '%s\n' "$body" | jq -c . >> "$calls"
  GCR_LAST_HTTP=412
  return 1
}
gcr_alloc 9003 1 hectic-lab/util.nix '["nix"]'
test "$RESPONSE_BODY" = 'VM creation failed'
test "$(wc -l < "$calls" | tr -d ' ')" = '3'
jq -e -s 'all(.server_type == "cx23")' "$calls" >/dev/null
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0000'

# Deferred allocation keeps cleanup ownership and reservation across failed
# DELETE, failed post-DELETE state update, and cleanup-owned 404 retry.
rm -f "$calls" "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')"
export GCR_BUDGET_EUR_MONTHLY='10'
deferred='{"job_id":"9005","run_attempt":"1","repo":"hectic-lab/util.nix","label":"nix","created_at":"0","ttl_min":null,"vm_id":"","vm_name":"","status":"deferred"}'
printf '%s\n' "$deferred" > "$GCR_STATE_DIR/jobs/9005-1.json"
gcr_gitea_job_state() { printf queued; }
record_put_count="$GCR_STATE_DIR/record-put-count"
gcr_record_put() {
  count="$(cat "$record_put_count" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$record_put_count"
  case "$count" in 1|3|5|8) return 1 ;; esac
  tmp="$(mktemp "$(dirname "$(gcr_record_path "$1" "$2")")/.tmp.XXXXXX")"
  printf '%s\n' "$3" > "$tmp"
  mv -f "$tmp" "$(gcr_record_path "$1" "$2")"
}
gcr_hcloud_req() {
  test "$1" = POST
  printf '%s\n' "$3" | jq -c . >> "$calls"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  printf '{"server":{"id":9005}}\n' > "$GCR_LAST_BODY"
}
gcr_vm_destroy() {
  printf 'destroy-failed %s\n' "$1" >> "$GCR_STATE_DIR/destroy-calls"
  return 1
}
gcr_alloc_deferred 9005 1
cleanup_rec="$(gcr_record_get 9005 1)"
test "$(gcr_record_field "$cleanup_rec" status)" = cleanup_pending
test "$(gcr_record_field "$cleanup_rec" vm_id)" = 9005
test "$(gcr_record_field "$cleanup_rec" budget_rate)" = 0.004
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0320'

gcr_vm_destroy() { printf 'deleted %s\n' "$1" >> "$GCR_STATE_DIR/destroy-calls"; }
gcr_sweep_cleanup_pending
cleanup_rec="$(gcr_record_get 9005 1)"
test "$(gcr_record_field "$cleanup_rec" status)" = cleanup_pending
test "$(gcr_record_field "$cleanup_rec" cleanup_vm_destroyed)" = false
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0320'
gcr_vm_destroy() {
  printf 'absent %s\n' "$1" >> "$GCR_STATE_DIR/destroy-calls"
  GCR_LAST_HTTP=404
  return 1
}
gcr_sweep_cleanup_pending
cleanup_rec="$(gcr_record_get 9005 1)"
test "$(gcr_record_field "$cleanup_rec" cleanup_vm_destroyed)" = true
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0000'
gcr_sweep_cleanup_pending
test ! -e "$(gcr_record_path 9005 1)"
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0000'
grep -q '^destroy-failed 9005$' "$GCR_STATE_DIR/destroy-calls"
grep -q '^deleted 9005$' "$GCR_STATE_DIR/destroy-calls"
grep -q '^absent 9005$' "$GCR_STATE_DIR/destroy-calls"
test "$(grep -c '^absent 9005$' "$GCR_STATE_DIR/destroy-calls")" = 1

# Confirmed ambiguous absence uses same monotonic refund claim. Failed state
# persistence after credit cannot make retry subtract reservation twice.
gcr_budget_add 0.004 480
ambiguous_absent='{"job_id":"9013","run_attempt":"1","repo":"hectic-lab/util.nix","label":"nix","created_at":"0","ttl_min":480,"vm_id":"","vm_name":"gcr-9013-1","server_type":"cx23","budget_rate":"0.004","candidate_location":"nbg1","candidate_arch":"amd64","bootstrapped":false,"status":"create_ambiguous"}'
printf '%s\n' "$ambiguous_absent" > "$GCR_STATE_DIR/jobs/9013-1.json"
gcr_hcloud_req() {
  test "$1" = GET
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  GCR_LAST_HTTP=200
  printf '{"servers":[]}\n' > "$GCR_LAST_BODY"
}
gcr_sweep_create_ambiguous
absence_rec="$(gcr_record_get 9013 1)"
test "$(gcr_record_field "$absence_rec" status)" = cleanup_pending
test "$(gcr_record_field "$absence_rec" cleanup_vm_destroyed)" = true
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0000'
gcr_sweep_cleanup_pending
test ! -e "$(gcr_record_path 9013 1)"
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '0.0000'

# Reservation write failure aborts before any Hetzner request.
rm -f "$calls"
rm -rf "$GCR_STATE_DIR/budget"
printf 'not-a-directory\n' > "$GCR_STATE_DIR/budget"
gcr_alloc 9006 1 hectic-lab/util.nix '["nix"]'
test "$RESPONSE_BODY" = 'VM creation failed'
test ! -e "$calls"
test ! -e "$(gcr_record_path 9006 1)"
