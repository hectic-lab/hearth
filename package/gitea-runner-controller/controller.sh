#!/bin/dash
# Reconcile loop for gitea-runner-controller.
# Owns: TTL sweep, orphan-VM sweep, deferred-job retry, stale-runner dereg,
# startup convergence. Runs forever under systemd; webhook service is separate.

gcr_record_age_sec() {
    created_at="$(gcr_record_field "$1" created_at)"
    now="$(gcr_now_epoch)"
    case "$created_at" in
        ''|*[!0-9]*) printf '%s' 999999 ;;
        *) printf '%s' "$((now - created_at))" ;;
    esac
}

gcr_sweep_ttl() {
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        status="$(gcr_record_field "$rec" status)"
        job_id="$(gcr_record_field "$rec" job_id)"
        attempt="$(gcr_record_field "$rec" run_attempt)"

        if [ "$status" = "idle_vm" ]; then
            gcr_lock_acquire idle-pool || continue
            rec="$(gcr_record_get "$job_id" "$attempt")"
            if [ -z "$rec" ] || [ "$(gcr_record_field "$rec" status)" != "idle_vm" ]; then
                gcr_lock_release idle-pool
                continue
            fi
            if gcr_idle_record_unexpired "$rec"; then
                gcr_lock_release idle-pool
                continue
            fi

            vm_id="$(gcr_record_field "$rec" vm_id)"
            if gcr_record_vm_owned_elsewhere "$vm_id" "$job_id" "$attempt"; then
                gcr_log warn --ns=sweep "removing superseded idle record job=$job_id vm=$vm_id"
                gcr_record_del "$job_id" "$attempt"
                gcr_lock_release idle-pool
                continue
            fi
            gcr_log info --ns=sweep "idle slot expired job=$job_id vm=$vm_id"
            if [ -n "$vm_id" ] && [ "$vm_id" != "null" ] && [ "$vm_id" != "0" ]; then
                gcr_vm_destroy "$vm_id" || true
                gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"idle-expired\"}"
            fi
            gcr_record_del "$job_id" "$attempt"
            gcr_lock_release idle-pool
            continue
        fi

        [ "$status" = "vm_active" ] || [ "$status" = "pending_vm" ] || continue
        ttl_min="$(gcr_record_field "$rec" ttl_min)"
        case "$ttl_min" in ''|*[!0-9]*) continue ;; esac

        max_sec="$((ttl_min * 60))"
        age="$(gcr_record_age_sec "$rec")"
        if [ "$age" -ge "$max_sec" ]; then
            key="$(gcr_alloc_key "$job_id" "$attempt")"
            gcr_lock_acquire "$key" || continue
            rec="$(gcr_record_get "$job_id" "$attempt")"
            case "$(gcr_record_field "$rec" status)" in
                pending_vm|vm_active) ;;
                *) gcr_lock_release "$key"; continue ;;
            esac
            ttl_min="$(gcr_record_field "$rec" ttl_min)"
            case "$ttl_min" in
                ''|*[!0-9]*) gcr_lock_release "$key"; continue ;;
            esac
            max_sec="$((ttl_min * 60))"
            age="$(gcr_record_age_sec "$rec")"
            if [ "$age" -lt "$max_sec" ]; then
                gcr_lock_release "$key"
                continue
            fi

            vm_id="$(gcr_record_field "$rec" vm_id)"
            gcr_log warn --ns=sweep "TTL exceeded job=$job_id age=${age}s max=${max_sec}s"
            if [ -n "$vm_id" ] && [ "$vm_id" != "null" ] && [ "$vm_id" != "0" ]; then
                ip="$(gcr_vm_public_ip "$vm_id" || true)"
                gcr_vm_collect_diagnostics "$vm_id" "$ip" "$job_id" ttl || true
                gcr_vm_destroy "$vm_id" || true
                gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"ttl\"}"
            fi
            gcr_event "job-ttl-expired" "$job_id" "{\"age\":$age}"
            gcr_record_del "$job_id" "$attempt"
            gcr_lock_release "$key"
        fi
    done
}

gcr_sweep_orphan_vms() {
    gcr_lock_acquire admission || return 0
    vms_json="$(gcr_vm_list_managed)" || {
        gcr_lock_release admission
        return 0
    }
    if ! gcr_lock_acquire idle-pool; then
        gcr_lock_release admission
        return 0
    fi
    count="$(printf '%s' "$vms_json" | jq 'length')"
    i=0
    while [ "$i" -lt "$count" ]; do
        vm="$(printf '%s' "$vms_json" | jq -c ".[$i]")"
        vm_id="$(printf '%s' "$vm" | jq -r '.id')"
        jid="$(printf '%s' "$vm" | jq -r '.labels["gcr.job-id"] // ""')"
        att="$(printf '%s' "$vm" | jq -r '.labels["gcr.run-attempt"] // ""')"

        if ! gcr_record_exists_for_vm_id "$vm_id"; then
            gcr_log warn --ns=sweep "orphan VM $vm_id job=$jid attempt=$att -> destroy"
            gcr_vm_destroy "$vm_id" || true
            gcr_event "orphan-vm-destroyed" "${jid:-unknown}" "{\"vm_id\":$vm_id}"
        fi
        i=$((i + 1))
    done
    gcr_lock_release idle-pool
    gcr_lock_release admission
}

gcr_alloc_deferred() {
    job_id="$1"; attempt="$2"

    key="$(gcr_alloc_key "$job_id" "$attempt")"
    gcr_lock_acquire "$key" || return 0
    rec="$(gcr_record_get "$job_id" "$attempt")"
    if [ -z "$rec" ] || [ "$(gcr_record_field "$rec" status)" != "deferred" ]; then
        gcr_lock_release "$key"
        return 0
    fi

    repo="$(gcr_record_field "$rec" repo)"
    label="$(gcr_record_field "$rec" label)"

    state="$(gcr_gitea_job_state "$repo" "$job_id")" || {
        gcr_lock_release "$key"
        return 0
    }
    case "$state" in
        completed:*)
            gcr_log info --ns=alloc "deferred job=$job_id already terminal ($state), dropping record"
            gcr_record_del "$job_id" "$attempt"
            gcr_lock_release "$key"
            return 0
            ;;
    esac

    profile="$(gcr_label_profile "$label")" || {
        gcr_lock_release "$key"
        return 0
    }
    set -- $profile
    server_type="$1"; ttl_min="$2"; rate="$3"

    gcr_lock_acquire admission || {
        gcr_lock_release "$key"
        return 0
    }
    active="$(gcr_count_active)"
    repo_active="$(gcr_count_active_repo "$repo")"
    if [ "$active" -ge "${GCR_CONCURRENCY_CAP:-2}" ] \
        || [ "$repo_active" -ge "${GCR_PER_REPO_CAP:-1}" ]; then
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    fi

    claim_status=0
    gcr_claim_idle "$job_id" "$attempt" "$repo" "$label" || claim_status="$?"
    if [ "$claim_status" -eq 0 ]; then
        reused="$(gcr_record_get "$job_id" "$attempt")"
        vm_id="$(gcr_record_field "$reused" vm_id)"
        if gcr_vm_runner_service "$vm_id" start \
            && gcr_gitea_runner_disabled "$repo" "$(gcr_record_field "$reused" vm_name)" false; then
            reused="$(gcr_record_get "$job_id" "$attempt")"
            reused="$(printf '%s' "$reused" | jq -c '.bootstrapped = true | del(.reused_vm)')"
            gcr_record_put "$job_id" "$attempt" "$reused"
        else
            gcr_gitea_runner_disabled "$repo" "$(gcr_record_field "$reused" vm_name)" true || true
            gcr_event "vm-reuse-start-failed" "$job_id" "{\"vm_id\":$vm_id,\"via\":\"deferred-retry\"}"
        fi
        gcr_lock_release admission
        gcr_lock_release "$key"
        gcr_event "vm-reused" "$job_id" "{\"vm_id\":$vm_id,\"label\":\"$label\",\"via\":\"deferred-retry\"}"
        gcr_log info --ns=alloc "deferred job=$job_id reused vm=$vm_id"
        return 0
    fi
    if [ "$claim_status" -eq 2 ]; then
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    fi

    gcr_budget_can_add "$rate" "$ttl_min" || {
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    }
    reg_token="$(gcr_gitea_registration_token "$repo")" || {
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    }

    vm_name="gcr-${job_id}-${attempt}"
    created_at="$(gcr_now_epoch)"
    vm_id="$(gcr_vm_create "$vm_name" "$label" "$server_type" "$ttl_min" \
        "$reg_token" "$job_id" "$attempt" "$repo")" && [ -n "$vm_id" ] || {
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    }

    gcr_budget_add "$rate" "$ttl_min"

    rec="$(jq -n --arg j "$job_id" --arg a "$attempt" --arg r "$repo" \
        --arg l "$label" --arg t "$created_at" --arg v "$vm_id" \
        --arg vn "$vm_name" --arg ttl "$ttl_min" \
        '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
          created_at:$t, ttl_min:($ttl|tonumber), vm_id:($v|tonumber),
          vm_name:$vn, bootstrapped:false, status:"pending_vm"}')"
    if ! gcr_record_put "$job_id" "$attempt" "$rec"; then
        gcr_vm_destroy "$vm_id" || true
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    fi
    gcr_lock_release admission
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
    gcr_lock_acquire idle-pool || return 0
    oldIFS="$IFS"
    IFS=,
    for allowed_repo in ${GCR_ALLOWED_REPOS:-}; do
        IFS="$oldIFS"
        case "$allowed_repo" in
            */\*)
                owner="${allowed_repo%/*}"
                repos="$(gcr_gitea_list_org_repos "$owner")" || {
                    IFS=,
                    continue
                }
                ;;
            */*) repos="$allowed_repo" ;;
            *) continue ;;
        esac
        while read -r repo; do
        [ -n "${repo:-}" ] || continue
        gcr_repo_allowed "$repo" || continue
        runners="$(gcr_gitea_list_runners "$repo")" || continue
        # Here-doc instead of pipe: dash runs pipe tails in a subshell, which
        # would strand gcr_event/audit writes from the caller's perspective.
        while read -r rid rname; do
            [ -n "${rid:-}" ] || continue
            case "$rname" in
                gcr-*) ;;
                *) continue ;;
            esac

            # Runner name stays tied to original VM across later job assignments.
            rest="${rname#gcr-}"
            jid="${rest%-*}"
            if ! gcr_record_exists_for_vm_name "$rname"; then
                gcr_log warn --ns=sweep "stale repo=$repo registration id=$rid name=$rname -> delete"
                if gcr_gitea_delete_runner "$repo" "$rid"; then
                    gcr_event "stale-runner-deleted" "${jid:-unknown}" "{\"repo\":\"$repo\",\"runner_id\":$rid,\"name\":\"$rname\"}"
                else
                    gcr_log error --ns=sweep "failed deleting repo=$repo runner id=$rid"
                fi
            fi
        done <<EOF
$runners
EOF
        done <<EOF
$repos
EOF
        IFS=,
    done
    IFS="$oldIFS"
    gcr_lock_release idle-pool
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
        key="$(gcr_alloc_key "$job_id" "$attempt")"
        gcr_lock_acquire "$key" || continue
        rec="$(gcr_record_get "$job_id" "$attempt")"
        if [ "$(gcr_record_field "$rec" status)" != "pending_vm" ] \
            || [ "$(gcr_record_field "$rec" bootstrapped)" = "true" ]; then
            gcr_lock_release "$key"
            continue
        fi
        repo="$(gcr_record_field "$rec" repo)"
        label="$(gcr_record_field "$rec" label)"
        vm_id="$(gcr_record_field "$rec" vm_id)"
        runner_name="$(gcr_record_field "$rec" vm_name)"

        if [ "$(gcr_record_field "$rec" reused_vm)" = "true" ]; then
            if gcr_vm_runner_service "$vm_id" start \
                && gcr_gitea_runner_disabled "$repo" "$runner_name" false; then
                rec="$(printf '%s' "$rec" | jq -c '.bootstrapped = true | del(.reused_vm)')"
                gcr_record_put "$job_id" "$attempt" "$rec"
            else
                gcr_gitea_runner_disabled "$repo" "$runner_name" true || true
            fi
            gcr_lock_release "$key"
            continue
        fi

        state="$(gcr_gitea_job_state "$repo" "$job_id")" || {
            gcr_lock_release "$key"
            continue
        }
        case "$state" in
            completed:*)
                gcr_log info --ns=sweep "pending job=$job_id already terminal ($state), destroying vm=$vm_id"
                if [ -n "$vm_id" ] && [ "$vm_id" != "0" ] && [ "$vm_id" != "null" ]; then
                    case "$state" in
                        completed:success|completed:cancelled|completed:skipped) ;;
                        *)
                            ip="$(gcr_vm_public_ip "$vm_id" || true)"
                            gcr_vm_collect_diagnostics "$vm_id" "$ip" "$job_id" "$state" || true
                            ;;
                    esac
                    gcr_vm_destroy "$vm_id" || true
                    gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"pending-job-completed\",\"state\":\"$state\"}"
                fi
                gcr_record_del "$job_id" "$attempt"
                gcr_lock_release "$key"
                continue
                ;;
        esac

        ip="$(gcr_vm_public_ip "$vm_id")" || {
            gcr_lock_release "$key"
            continue
        }
        if [ -z "$ip" ]; then
            gcr_lock_release "$key"
            continue
        fi

        reg_token="$(gcr_gitea_registration_token "$repo")" || {
            gcr_lock_release "$key"
            continue
        }
        ttl_min="$(gcr_record_field "$rec" ttl_min)"

        gcr_log info --ns=alloc "bootstrapping vm=$vm_id ip=$ip job=$job_id"
        if gcr_vm_bootstrap_ssh "$ip" "$label" "$reg_token" "$runner_name"; then
            rec="$(printf '%s' "$rec" | jq -c '.bootstrapped = true | .ip = $ip' --arg ip "$ip")"
            gcr_record_put "$job_id" "$attempt" "$rec"
            gcr_event "vm-bootstrapped" "$job_id" "{\"vm_id\":$vm_id,\"ip\":\"$ip\"}"
        else
            gcr_log warn --ns=alloc "bootstrap failed vm=$vm_id (retry next tick)"
        fi
        gcr_lock_release "$key"
    done
}

# Reap terminal jobs even when completed webhook path lags or is absent.
gcr_reap_finished_jobs() {
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        case "$(gcr_record_field "$rec" status)" in
            pending_vm|vm_active) ;;
            *) continue ;;
        esac

        job_id="$(gcr_record_field "$rec" job_id)"
        attempt="$(gcr_record_field "$rec" run_attempt)"
        repo="$(gcr_record_field "$rec" repo)"
        vm_id="$(gcr_record_field "$rec" vm_id)"

        state="$(gcr_gitea_job_state "$repo" "$job_id")" || continue
        case "$state" in
            completed:*)
                key="$(gcr_alloc_key "$job_id" "$attempt")"
                gcr_lock_acquire "$key" || continue
                rec="$(gcr_record_get "$job_id" "$attempt")"
                if [ -z "$rec" ]; then
                    gcr_lock_release "$key"
                    continue
                fi
                case "$(gcr_record_field "$rec" status)" in
                    pending_vm|vm_active) ;;
                    *) gcr_lock_release "$key"; continue ;;
                esac
                vm_id="$(gcr_record_field "$rec" vm_id)"
                if [ "$state" = "completed:success" ] \
                    && idle_rec="$(gcr_record_idle_json "$rec")"; then
                    if ! gcr_lock_acquire idle-pool; then
                        gcr_lock_release "$key"
                        continue
                    fi
                    runner_name="$(gcr_record_field "$rec" vm_name)"
                    if ! gcr_gitea_runner_disabled "$repo" "$runner_name" true \
                        || ! gcr_vm_runner_service "$vm_id" stop; then
                        gcr_lock_release idle-pool
                        gcr_vm_destroy "$vm_id" || true
                        gcr_record_del "$job_id" "$attempt"
                        gcr_lock_release "$key"
                        gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"idle-stop-failed\",\"via\":\"reconcile\"}"
                        continue
                    fi
                    gcr_record_put "$job_id" "$attempt" "$idle_rec"
                    idle_expires="$(gcr_record_field "$idle_rec" idle_expires_at)"
                    gcr_lock_release idle-pool
                    gcr_lock_release "$key"
                    gcr_event "vm-idle" "$job_id" "{\"vm_id\":$vm_id,\"expires_at\":$idle_expires,\"via\":\"reconcile\"}"
                    gcr_log info --ns=sweep "job=$job_id succeeded, retaining vm=$vm_id until $idle_expires"
                    continue
                fi

                gcr_log info --ns=sweep "job=$job_id terminal ($state), destroying vm=$vm_id"
                if [ -n "$vm_id" ] && [ "$vm_id" != "0" ] && [ "$vm_id" != "null" ]; then
                    case "$state" in
                        completed:success|completed:cancelled|completed:skipped) ;;
                        *)
                            ip="$(gcr_vm_public_ip "$vm_id" || true)"
                            gcr_vm_collect_diagnostics "$vm_id" "$ip" "$job_id" "$state" || true
                            ;;
                    esac
                    gcr_vm_destroy "$vm_id" || true
                    gcr_event "vm-destroyed" "$job_id" "{\"vm_id\":$vm_id,\"reason\":\"job-completed\",\"state\":\"$state\"}"
                fi
                gcr_record_del "$job_id" "$attempt"
                gcr_lock_release "$key"
                ;;
        esac
    done
}

gcr_tick() {
    gcr_sweep_ttl
    gcr_reap_finished_jobs
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
