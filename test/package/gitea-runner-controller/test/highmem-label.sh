#!/bin/dash
set -eu

. "$LOG_SH"
. "$STATE_SH"
. "$DECIDE_SH"
. "$HCLOUD_SH"

gcr_state_init
export GCR_ALLOWED_REPOS='hectic-lab/util.nix'
export GCR_IMAGE_ID='313131'
export GCR_NIX_IMAGE_ID='424242'

test "$(gcr_label_ttl ubuntu-latest)" = '180'
test "$(gcr_label_ttl nix)" = '480'
test "$(gcr_decide ubuntu-latest hectic-lab/util.nix)" = 'cx53 180 0.032'
test "$(gcr_decide nix hectic-lab/util.nix)" = 'cx53 480 0.032'
test "$(gcr_label_candidates ubuntu-latest | head -n1)" = 'cx53 nbg1 amd64'
test "$(gcr_label_candidates nix | head -n1)" = 'cx53 nbg1 amd64'
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
export GCR_BUDGET_EUR_MONTHLY='6.84'
gcr_budget_add 0.8550 480
test "$(cat "$GCR_STATE_DIR/budget/$(date -u '+%Y-%m')")" = '6.8400'

calls="$GCR_STATE_DIR/hcloud-calls"
sleep() { :; }
gcr_hcloud_token() { printf token; }
gcr_hcloud_req() {
  method="$1"; path="$2"; body="${3:-}"
  test "$method" = POST
  test "$path" = /servers
  printf '%s\n' "$body" | jq -c . >> "$calls"
  count="$(wc -l < "$calls" | tr -d ' ')"
  GCR_LAST_BODY="$GCR_STATE_DIR/last-body.json"
  case "$count" in
    1|2) return 1 ;;
    3) printf '{"server":{"id":9001}}\n' > "$GCR_LAST_BODY"; return 0 ;;
    *) return 1 ;;
  esac
}

vm_id="$(gcr_vm_create gcr-9001-1 gross-nix-x86-highmem ccx53 480 reg-token 9001 1 hectic-lab/util.nix)"
test "$vm_id" = '9001'
test "$(wc -l < "$calls" | tr -d ' ')" = '3'
jq -e 'select(.server_type == "ccx53" and .location == "nbg1" and .labels["gcr.arch"] == "amd64" and .labels["gcr.label"] == "gross-nix-x86-highmem" and .labels["gcr.ttl-min"] == "480")' "$calls" >/dev/null
jq -e 'select(.server_type == "ccx53" and .location == "fsn1" and .labels["gcr.arch"] == "amd64")' "$calls" >/dev/null
jq -e 'select(.server_type == "ccx53" and .location == "hel1" and .labels["gcr.arch"] == "amd64")' "$calls" >/dev/null
if jq -e 'select(.server_type != "ccx53" or .labels["gcr.arch"] != "amd64")' "$calls" >/dev/null; then
  printf 'highmem VM creation attempted non-ccx53 or non-amd64 candidate\n' >&2
  exit 1
fi
