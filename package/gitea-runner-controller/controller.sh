#!/bin/dash
# Reconcile loop for gitea-runner-controller.
# Owns: TTL sweep, orphan-VM sweep, deferred-job retry, stale-runner dereg,
# startup convergence. Runs forever under systemd; webhook service is separate.

gcr_ttl_grace_sec() {
    printf '%s' "$((10 * 60))"
}

gcr_record_age_sec() {
    created_at="$(gcr_record_field "$1" created_at)"
    now="$(date -u '+%s')"
    case "$created_at" in
        ''|*[!0-9]*) printf '%s' 999999 ;;
        *) printf '%s' "$((now - created_at))" ;;
    esac
}

gcr_sweep_ttl() {
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        status="$(gcr_record_field "$rec" status)"
        [ "$status" = "vm_active" ] || [ "$status" = "pending_vm" ] || continue

        job_id="$(gcr_record_field "$rec" job_id)"
        attempt="$(gcr_record_field "$rec" run_attempt)"
        ttl_min="$(gcr_record_field "$rec" ttl_min)"
        case "$ttl_min" in ''|*[!0-9]*) continue ;; esac

        max_sec="$((ttl_min * 60 + $(gcr_ttl_grace_sec)))"
        age="$(gcr_record_age_sec "$rec")"
        if [ "$age" -gt "$max_sec" ]; then
            vm_id="$(gcr_record_field "$rec" vm_id)"
            gcr_log warn --ns=sweep "TTL exceeded job=$job_id age=${age}s max=${max_sec}s"
            if [ -n "$vm_id" ] && [ "$vm_id" != "null" ] && [ "$vm_id" != "0" ]; then
                gcr_vm_destroy "$vm_id" || true
                gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"ttl\"}"
            fi
            gcr_event "job-ttl-expired" "$job_id" "{\"age\":$age}"
            gcr_record_del "$job_id" "$attempt"
            gcr_lock_release "$(gcr_alloc_key "$job_id" "$attempt")"
        fi
    done
}

gcr_sweep_orphan_vms() {
    vms_json="$(gcr_vm_list_managed)" || return 0
    count="$(printf '%s' "$vms_json" | jq 'length')"
    i=0
    while [ "$i" -lt "$count" ]; do
        vm="$(printf '%s' "$vms_json" | jq -c ".[$i]")"
        vm_id="$(printf '%s' "$vm" | jq -r '.id')"
        jid="$(printf '%s' "$vm" | jq -r '.labels["gcr.job-id"] // ""')"
        att="$(printf '%s' "$vm" | jq -r '.labels["gcr.run-attempt"] // ""')"

        known=""
        if [ -n "$jid" ] && [ -n "$att" ]; then
            rec="$(gcr_record_get "$jid" "$att")"
            [ -n "$rec" ] && known=1
        fi

        if [ -z "$known" ]; then
            gcr_log warn --ns=sweep "orphan VM $vm_id job=$jid attempt=$att -> destroy"
            gcr_vm_destroy "$vm_id" || true
            gcr_event "orphan-vm-destroyed" "${jid:-unknown}" "{\"vm_id\":$vm_id}"
        fi
        i=$((i + 1))
    done
}

gcr_alloc_deferred() {
    job_id="$1"; attempt="$2"

    rec="$(gcr_record_get "$job_id" "$attempt")"
    [ -n "$rec" ] || return 0
    [ "$(gcr_record_field "$rec" status)" = "deferred" ] || return 0

    repo="$(gcr_record_field "$rec" repo)"
    label="$(gcr_record_field "$rec" label)"

    profile="$(gcr_label_profile "$label")" || return 0
    set -- $profile
    server_type="$1"; ttl_min="$2"; rate="$3"

    active="$(gcr_count_active)"
    repo_active="$(gcr_count_active_repo "$repo")"
    [ "$active" -ge "${GCR_CONCURRENCY_CAP:-2}" ] && return 0
    [ "$repo_active" -ge "${GCR_PER_REPO_CAP:-1}" ] && return 0

    gcr_budget_add "$rate" "$ttl_min" || return 0
    reg_token="$(gcr_gitea_registration_token)" || return 0

    key="$(gcr_alloc_key "$job_id" "$attempt")"
    gcr_lock_acquire "$key" || return 0

    vm_name="gcr-${job_id}-${attempt}"
    vm_id="$(gcr_vm_create "$vm_name" "$label" "$server_type" "$ttl_min" \
        "$reg_token" "$job_id" "$attempt" "$repo")" && [ -n "$vm_id" ] || {
        gcr_lock_release "$key"
        return 0
    }

    rec="$(jq -n --arg j "$job_id" --arg a "$attempt" --arg r "$repo" \
        --arg l "$label" --arg t "$(date -u '+%s')" --arg v "$vm_id" \
        --arg vn "$vm_name" --arg ttl "$ttl_min" \
        '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
          created_at:$t, ttl_min:($ttl|tonumber), vm_id:($v|tonumber),
          vm_name:$vn, bootstrapped:false, status:"pending_vm"}')"
    gcr_record_put "$job_id" "$attempt" "$rec"
    gcr_lock_release "$key"
    gcr_event "vm-created" "$job_id" "{\"vm_id\":$vm_id,\"label\":\"$label\",\"ttl_min\":$ttl_min,\"via\":\"deferred-retry\"}"
    gcr_log info --ns=alloc "deferred job=$job_id allocated vm=$vm_id"
}

gcr_retry_deferred() {
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        [ "$(gcr_record_field "$rec" status)" = "deferred" ] || continue
        gcr_alloc_deferred \
            "$(gcr_record_field "$rec" job_id)" \
            "$(gcr_record_field "$rec" run_attempt)"
    done
}

gcr_sweep_stale_runners() {
    runners="$(gcr_gitea_list_runners)" || return 0
    # Here-doc instead of pipe: dash runs pipe tails in a subshell, which
    # would strand gcr_event/audit writes from the caller's perspective.
    while read -r rid rname; do
        [ -n "${rid:-}" ] || continue
        case "$rname" in
            gcr-*) ;;
            *) continue ;;
        esac

        # gcr-<job>-<attempt>: alive iff a matching active/pending record exists.
        rest="${rname#gcr-}"
        jid="${rest%-*}"
        att="${rest##*-}"
        rec=""
        case "$jid" in *[!0-9]*|"") rec="" ;;
            *) case "$att" in *[!0-9]*|"") rec="" ;;
                   *) rec="$(gcr_record_get "$jid" "$att")" ;;
               esac ;;
        esac

        if [ -z "$rec" ]; then
            gcr_log warn --ns=sweep "stale runner registration id=$rid name=$rname -> delete"
            if gcr_gitea_delete_runner "$rid"; then
                gcr_event "stale-runner-deleted" "${jid:-unknown}" "{\"runner_id\":$rid,\"name\":\"$rname\"}"
            else
                gcr_log error --ns=sweep "failed deleting runner id=$rid"
            fi
        fi
    done <<EOF
$runners
EOF
}

gcr_vm_public_ip() {
    # gcr_vm_public_ip SERVER_ID -> ipv4 or empty
    if gcr_hcloud_req GET "/servers/$1"; then
        jq -r '.server.public_net.ipv4.ip // ""' "$GCR_LAST_BODY"
    fi
}

# Runs SSH-push bootstrap for VMs that were created but not yet provisioned.
# Registration token is fetched fresh per attempt (short-lived usefulness).
gcr_bootstrap_pending() {
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        [ "$(gcr_record_field "$rec" status)" = "pending_vm" ] || continue
        [ "$(gcr_record_field "$rec" bootstrapped)" = "true" ] && continue

        job_id="$(gcr_record_field "$rec" job_id)"
        attempt="$(gcr_record_field "$rec" run_attempt)"
        label="$(gcr_record_field "$rec" label)"
        vm_id="$(gcr_record_field "$rec" vm_id)"
        runner_name="$(gcr_record_field "$rec" vm_name)"

        ip="$(gcr_vm_public_ip "$vm_id")"
        [ -n "$ip" ] || continue

        reg_token="$(gcr_gitea_registration_token)" || continue
        ttl_min="$(gcr_record_field "$rec" ttl_min)"

        gcr_log info --ns=alloc "bootstrapping vm=$vm_id ip=$ip job=$job_id"
        if gcr_vm_bootstrap_ssh "$ip" "$label" "$reg_token" "$runner_name"; then
            rec="$(printf '%s' "$rec" | jq -c '.bootstrapped = true | .ip = $ip' --arg ip "$ip")"
            gcr_record_put "$job_id" "$attempt" "$rec"
            gcr_event "vm-bootstrapped" "$job_id" "{\"vm_id\":$vm_id,\"ip\":\"$ip\"}"
        else
            gcr_log warn --ns=alloc "bootstrap failed vm=$vm_id (retry next tick)"
        fi
    done
}

gcr_tick() {
    gcr_sweep_ttl
    gcr_sweep_orphan_vms
    gcr_retry_deferred
    gcr_bootstrap_pending
    gcr_sweep_stale_runners
}

gcr_main() {
    : "${GCR_RECONCILE_INTERVAL_SEC:=60}"
    gcr_state_init

    gcr_log info --ns=core "controller starting, interval=${GCR_RECONCILE_INTERVAL_SEC}s state=$GCR_STATE_DIR"
    gcr_tick

    while :; do
        sleep "$GCR_RECONCILE_INTERVAL_SEC"
        if ! gcr_tick; then
            gcr_log error --ns=core "tick failed, retrying next interval"
        fi
    done
}
