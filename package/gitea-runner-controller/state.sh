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

# mkdir(2) atomicity guard. Owner metadata lets a new controller process
# recover locks stranded by a crashed webhook or reconciler process.
gcr_lock_takeover() {
    gcr_takeover_dir="$1"
    gcr_takeover_old="$gcr_takeover_dir.reclaim.$$"
    # Rename is atomic: exactly one reclaimer can move the observed stale
    # directory. Never rm -rf the active lock pathname during recovery.
    mv "$gcr_takeover_dir" "$gcr_takeover_old" 2>/dev/null || return 1
    if mkdir "$gcr_takeover_dir" 2>/dev/null; then
        printf '%s %s\n' "$$" "$(gcr_now_epoch)" > "$gcr_takeover_dir/owner"
        rm -rf "$gcr_takeover_old"
        return 0
    fi
    rm -rf "$gcr_takeover_old"
    return 1
}

gcr_lock_acquire() {
    gcr_lock_key="$1"
    gcr_lock_dir="$(printf '%s/jobs/.lock.%s' "$GCR_STATE_DIR" "$gcr_lock_key")"
    if mkdir "$gcr_lock_dir" 2>/dev/null; then
        printf '%s %s\n' "$$" "$(gcr_now_epoch)" > "$gcr_lock_dir/owner"
        return 0
    fi

    gcr_lock_owner="$(cat "$gcr_lock_dir/owner" 2>/dev/null || true)"
    if [ -z "$gcr_lock_owner" ]; then
        # A crash between mkdir and owner write leaves no PID. Give a live
        # creator a short initialization window, then unblock hard TTL work.
        gcr_lock_mtime="$(stat -c %Y "$gcr_lock_dir" 2>/dev/null || true)"
        gcr_lock_now="$(gcr_now_epoch)"
        case "$gcr_lock_mtime:$gcr_lock_now" in
            *[!0-9:]*|:*|*::*|*:) return 1 ;;
        esac
        [ "$((gcr_lock_now - gcr_lock_mtime))" -ge 30 ] || return 1
        gcr_lock_takeover "$gcr_lock_dir"
        return "$?"
    fi
    set -- $gcr_lock_owner
    gcr_lock_pid="${1:-}"
    case "$gcr_lock_pid" in ''|*[!0-9]*) return 1 ;; esac
    if kill -0 "$gcr_lock_pid" 2>/dev/null; then
        return 1
    fi

    # Dead PID means a process crash, not live contention. Atomically take
    # over its directory; concurrent recovery cannot erase a new lock.
    gcr_lock_takeover "$gcr_lock_dir"
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
    printf '%s' "$1" | jq -r --arg f "$2" 'if has($f) then .[$f] else "" end'
}

gcr_now_epoch() {
    date -u '+%s'
}

# Successful VMs remain reusable until next billing-hour boundary, but never
# beyond profile hard TTL. Prints updated idle record when retention is safe.
gcr_record_idle_json() {
    gcr_idle_rec="$1"
    [ "$(gcr_record_field "$gcr_idle_rec" bootstrapped)" = "true" ] || return 1

    gcr_idle_vm_id="$(gcr_record_field "$gcr_idle_rec" vm_id)"
    gcr_idle_created="$(gcr_record_field "$gcr_idle_rec" created_at)"
    gcr_idle_ttl="$(gcr_record_field "$gcr_idle_rec" ttl_min)"
    case "$gcr_idle_vm_id:$gcr_idle_created:$gcr_idle_ttl" in
        *[!0-9:]*|0:*|:*|*::*|*:) return 1 ;;
    esac

    gcr_idle_now="$(gcr_now_epoch)"
    gcr_idle_hard_expires="$((gcr_idle_created + gcr_idle_ttl * 60))"
    [ "$gcr_idle_now" -lt "$gcr_idle_hard_expires" ] || return 1

    gcr_idle_age="$((gcr_idle_now - gcr_idle_created))"
    [ "$gcr_idle_age" -ge 0 ] || gcr_idle_age=0
    gcr_idle_slots="$((gcr_idle_age / 3600))"
    [ "$((gcr_idle_age % 3600))" -eq 0 ] || gcr_idle_slots=$((gcr_idle_slots + 1))
    [ "$gcr_idle_slots" -gt 0 ] || gcr_idle_slots=1
    gcr_idle_expires="$((gcr_idle_created + gcr_idle_slots * 3600))"
    [ "$gcr_idle_expires" -le "$gcr_idle_hard_expires" ] \
        || gcr_idle_expires="$gcr_idle_hard_expires"

    printf '%s' "$gcr_idle_rec" | jq -c \
        --arg now "$gcr_idle_now" --arg expires "$gcr_idle_expires" \
        '.status = "idle_vm"
         | .idle_since = ($now | tonumber)
         | .idle_expires_at = ($expires | tonumber)'
}

gcr_idle_record_unexpired() {
    gcr_idle_rec="$1"
    [ "$(gcr_record_field "$gcr_idle_rec" status)" = "idle_vm" ] || return 1
    [ "$(gcr_record_field "$gcr_idle_rec" bootstrapped)" = "true" ] || return 1

    gcr_idle_now="$(gcr_now_epoch)"
    gcr_idle_vm_id="$(gcr_record_field "$gcr_idle_rec" vm_id)"
    gcr_idle_vm_name="$(gcr_record_field "$gcr_idle_rec" vm_name)"
    gcr_idle_expires="$(gcr_record_field "$gcr_idle_rec" idle_expires_at)"
    gcr_idle_created="$(gcr_record_field "$gcr_idle_rec" created_at)"
    gcr_idle_ttl="$(gcr_record_field "$gcr_idle_rec" ttl_min)"
    case "$gcr_idle_expires:$gcr_idle_created:$gcr_idle_ttl" in
        *[!0-9:]*|:*|*::*|*:) return 1 ;;
    esac
    case "$gcr_idle_vm_id" in ''|0|*[!0-9]*) return 1 ;; esac
    [ -n "$gcr_idle_vm_name" ] || return 1
    gcr_idle_hard_expires="$((gcr_idle_created + gcr_idle_ttl * 60))"
    [ "$gcr_idle_now" -lt "$gcr_idle_expires" ] \
        && [ "$gcr_idle_now" -lt "$gcr_idle_hard_expires" ]
}

gcr_idle_record_usable() {
    gcr_idle_rec="$1"
    gcr_idle_record_unexpired "$gcr_idle_rec" || return 1
    gcr_idle_min_remaining="${GCR_RECONCILE_INTERVAL_SEC:-60}"
    case "$gcr_idle_min_remaining" in ''|*[!0-9]*) return 1 ;; esac
    [ "$((gcr_idle_expires - gcr_idle_now))" -ge "$gcr_idle_min_remaining" ] \
        && [ "$((gcr_idle_hard_expires - gcr_idle_now))" -ge "$gcr_idle_min_remaining" ]
}

# Caller must hold destination allocation lock. Global pool lock ensures one
# queued job claims an idle VM; destination write precedes source deletion so
# orphan/stale sweeps always see an owner during transfer.
gcr_claim_idle() {
    gcr_claim_job="$1"; gcr_claim_attempt="$2"
    gcr_claim_repo="$3"; gcr_claim_label="$4"
    # Exit 2 means pool is busy; callers must defer instead of charging for a
    # new VM without knowing whether matching paid capacity is available.
    gcr_lock_acquire idle-pool || return 2

    for gcr_claim_file in $(gcr_active_records); do
        gcr_claim_rec="$(cat "$gcr_claim_file")"
        [ "$(gcr_record_field "$gcr_claim_rec" status)" = "idle_vm" ] || continue
        [ "$(gcr_record_field "$gcr_claim_rec" repo)" = "$gcr_claim_repo" ] || continue
        [ "$(gcr_record_field "$gcr_claim_rec" label)" = "$gcr_claim_label" ] || continue
        gcr_idle_record_usable "$gcr_claim_rec" || continue

        gcr_claim_old_job="$(gcr_record_field "$gcr_claim_rec" job_id)"
        gcr_claim_old_attempt="$(gcr_record_field "$gcr_claim_rec" run_attempt)"
        gcr_claim_vm_id="$(gcr_record_field "$gcr_claim_rec" vm_id)"
        gcr_record_vm_owned_elsewhere "$gcr_claim_vm_id" \
            "$gcr_claim_old_job" "$gcr_claim_old_attempt" && continue
        gcr_claim_now="$(gcr_now_epoch)"
        gcr_claim_new="$(printf '%s' "$gcr_claim_rec" | jq -c \
            --arg job "$gcr_claim_job" --arg attempt "$gcr_claim_attempt" \
            --arg repo "$gcr_claim_repo" --arg label "$gcr_claim_label" \
            --arg now "$gcr_claim_now" \
            '.job_id = $job | .run_attempt = $attempt
              | .repo = $repo | .label = $label | .status = "pending_vm"
              | .bootstrapped = false
              | .reused_vm = true
             | .assigned_at = ($now | tonumber)
             | del(.idle_since, .idle_expires_at)')"
        if ! gcr_record_put "$gcr_claim_job" "$gcr_claim_attempt" "$gcr_claim_new"; then
            gcr_lock_release idle-pool
            return 1
        fi
        gcr_record_del "$gcr_claim_old_job" "$gcr_claim_old_attempt"
        gcr_lock_release idle-pool
        return 0
    done

    gcr_lock_release idle-pool
    return 1
}

gcr_record_exists_for_vm_id() {
    gcr_lookup="$1"
    for gcr_lookup_file in $(gcr_active_records); do
        [ "$(gcr_record_field "$(cat "$gcr_lookup_file")" vm_id)" = "$gcr_lookup" ] \
            && return 0
    done
    return 1
}

gcr_record_exists_for_vm_name() {
    gcr_lookup="$1"
    for gcr_lookup_file in $(gcr_active_records); do
        [ "$(gcr_record_field "$(cat "$gcr_lookup_file")" vm_name)" = "$gcr_lookup" ] \
            && return 0
    done
    return 1
}

gcr_record_vm_owned_elsewhere() {
    gcr_lookup_vm="$1"; gcr_lookup_job="$2"; gcr_lookup_attempt="$3"
    for gcr_lookup_file in $(gcr_active_records); do
        gcr_lookup_rec="$(cat "$gcr_lookup_file")"
        [ "$(gcr_record_field "$gcr_lookup_rec" vm_id)" = "$gcr_lookup_vm" ] || continue
        if [ "$(gcr_record_field "$gcr_lookup_rec" job_id)" != "$gcr_lookup_job" ] \
            || [ "$(gcr_record_field "$gcr_lookup_rec" run_attempt)" != "$gcr_lookup_attempt" ]; then
            return 0
        fi
    done
    return 1
}

gcr_event() {
    printf '{"ts":"%s","event":"%s","job_id":"%s","detail":%s}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" \
        "$(printf '%s' "$3" | jq -Rs .)" >> "$GCR_STATE_DIR/events.jsonl"
}

# Exit-code contract: 0 = remains under budget, 1 = would exceed cap.
gcr_budget_can_add() {
    rate="$1"; ttl_min="$2"
    month="$(date -u '+%Y-%m')"
    file="$GCR_STATE_DIR/budget/$month"
    current="$(cat "$file" 2>/dev/null || echo 0)"
    projected="$(awk -v c="$current" -v r="$rate" -v t="$ttl_min" 'BEGIN {printf "%.4f", c + r * t / 60}')"
    if awk -v p="$projected" -v b="${GCR_BUDGET_EUR_MONTHLY:-15}" 'BEGIN {exit !(p > b)}'; then
        return 1
    fi
    return 0
}

# Caller holds admission lock and has already checked gcr_budget_can_add.
gcr_budget_add() {
    rate="$1"; ttl_min="$2"
    month="$(date -u '+%Y-%m')"
    file="$GCR_STATE_DIR/budget/$month"
    current="$(cat "$file" 2>/dev/null || echo 0)"
    projected="$(awk -v c="$current" -v r="$rate" -v t="$ttl_min" 'BEGIN {printf "%.4f", c + r * t / 60}')"
    printf '%s\n' "$projected" > "$file"
    return 0
}

gcr_active_records() {
    grep -El '"status"[[:space:]]*:[[:space:]]*"(pending_vm|vm_active|idle_vm|deferred)"' "$GCR_STATE_DIR"/jobs/*.json 2>/dev/null || true
}
