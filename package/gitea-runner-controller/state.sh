#!/bin/dash
# State primitives for gitea-runner-controller.
# Layout:
#   $GCR_STATE_DIR/jobs/<job_id>.json   allocation records
#   $GCR_STATE_DIR/jobs/.lock.<key>/    mkdir(2) atomicity guards
#   $GCR_STATE_DIR/events.jsonl         append-only audit
#   $GCR_STATE_DIR/budget/<YYYY-MM>     estimated EUR spent this month

gcr_state_init() {
    test -n "${GCR_STATE_DIR:-}" || { echo "GCR_STATE_DIR is not set" >&2; return 1; }
    mkdir -p "$GCR_STATE_DIR/jobs" "$GCR_STATE_DIR/budget"
    touch "$GCR_STATE_DIR/events.jsonl"
}

gcr_alloc_key() {
    printf '%s-%s' "$1" "$2"
}

gcr_record_path() {
    printf '%s/jobs/%s.json' "$GCR_STATE_DIR" "$(gcr_alloc_key "$1" "$2")"
}

# mkdir(2) atomicity guard: succeeds exactly once per key until released.
gcr_lock_acquire() {
    mkdir "$(printf '%s/jobs/.lock.%s' "$GCR_STATE_DIR" "$1")" 2>/dev/null
}

gcr_lock_release() {
    rm -rf "$(printf '%s/jobs/.lock.%s' "$GCR_STATE_DIR" "$1")"
}

gcr_record_get() {
    # Missing record is a normal answer, not an error; must not trip errexit.
    { cat "$(gcr_record_path "$1" "$2")" 2>/dev/null || true; }
}

# mktemp+mv keeps concurrent readers away from partially written records.
gcr_record_put() {
    tmp="$(mktemp "$(dirname "$(gcr_record_path "$1" "$2")")/.tmp.XXXXXX")"
    printf '%s\n' "$3" > "$tmp"
    mv -f "$tmp" "$(gcr_record_path "$1" "$2")"
}

gcr_record_del() {
    rm -f "$(gcr_record_path "$1" "$2")"
}

gcr_record_field() {
    printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // ""'
}

gcr_event() {
    printf '{"ts":"%s","event":"%s","job_id":"%s","detail":%s}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" \
        "$(printf '%s' "$3" | jq -Rs .)" >> "$GCR_STATE_DIR/events.jsonl"
}

# Exit-code contract: 0 = recorded under budget, 1 = would exceed cap.
gcr_budget_add() {
    rate="$1"; ttl_min="$2"
    month="$(date -u '+%Y-%m')"
    file="$GCR_STATE_DIR/budget/$month"
    current="$(cat "$file" 2>/dev/null || echo 0)"
    projected="$(awk -v c="$current" -v r="$rate" -v t="$ttl_min" 'BEGIN {printf "%.4f", c + r * t / 60}')"
    if awk -v p="$projected" -v b="${GCR_BUDGET_EUR_MONTHLY:-15}" 'BEGIN {exit !(p > b)}'; then
        return 1
    fi
    printf '%s\n' "$projected" > "$file"
    return 0
}

gcr_active_records() {
    grep -El '"status"[[:space:]]*:[[:space:]]*"(pending_vm|vm_active|deferred)"' "$GCR_STATE_DIR"/jobs/*.json 2>/dev/null || true
}
