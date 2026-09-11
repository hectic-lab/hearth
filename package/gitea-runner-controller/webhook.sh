#!/bin/dash
# One-shot HTTP handler for Gitea workflow_job webhooks.
# Invoked per connection by socat; request on stdin, response on stdout.

RESPONSE_CODE=204
RESPONSE_BODY=""

gcr_respond() {
    code="$1"; body="${2:-}"
    reason=""
    case "$code" in
        200) reason="OK" ;;
        202) reason="Accepted" ;;
        204) reason="No Content" ;;
        400) reason="Bad Request" ;;
        403) reason="Forbidden" ;;
        413) reason="Payload Too Large" ;;
        *)   reason="No Content" ;;
    esac
    printf 'HTTP/1.1 %s %s\r\n' "$code" "$reason"
    printf 'Content-Type: text/plain\r\n'
    printf 'Content-Length: %s\r\n' "$(printf '%s' "$body" | wc -c)"
    printf 'Connection: close\r\n\r\n'
    [ -n "$body" ] && printf '%s\n' "$body"
}

gcr_read_request() {
    request_line=""
    gcr_hdr_event_type=""
    gcr_hdr_delivery=""
    gcr_hdr_signature=""
    content_length=0

    # Correctness depends on dash reading stdin byte-by-byte (no lookahead
    # buffer); body bytes must remain unconsumed for `head -c` below.
    IFS= read -r request_line || return 1

    while :; do
        IFS= read -r line || break
        line="$(printf '%s' "$line" | tr -d '\r')"
        [ -z "$line" ] && break
        name="$(printf '%s' "$line" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
        value="$(printf '%s' "${line#*:}" | sed 's/^ *//')"
        case "$name" in
            x-gitea-event-type) gcr_hdr_event_type="$value" ;;
            x-gitea-delivery)   gcr_hdr_delivery="$value" ;;
            x-gitea-signature)  gcr_hdr_signature="$value" ;;
            content-length)     content_length="$value" ;;
        esac
    done

    case "$request_line" in
        "POST "*" HTTP/"*) ;;
        *) return 1 ;;
    esac

    case "$content_length" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$content_length" -le 65536 ] || { gcr_respond 413 "payload too large"; exit 0; }

    gcr_body="$(head -c "$content_length")"
}

gcr_verify_signature() {
    test -r "${GITEA_WEBHOOK_SECRET_FILE:-}" || {
        gcr_log error --ns=webhook "GITEA_WEBHOOK_SECRET_FILE missing"
        return 1
    }
    secret="$(cat "$GITEA_WEBHOOK_SECRET_FILE")"
    expected="$(printf '%s' "$gcr_body" \
        | openssl dgst -sha256 -hmac "$secret" -hex \
        | awk '{print $NF}')"
    # NOTE(yukkop): shell string compare is not constant-time; acceptable here
    # because the secret is high-entropy and bodies are signed, not encrypted.
    [ "$expected" = "$gcr_hdr_signature" ]
}

gcr_alloc() {
    job_id="$1"; attempt="$2"; repo="$3"; labels_json="$4"

    label="$(printf '%s' "$labels_json" | jq -r '.[0] // ""')"
    label_count="$(printf '%s' "$labels_json" | jq 'length')"

    existing="$(gcr_record_get "$job_id" "$attempt")"
    if [ -n "$existing" ]; then
        gcr_log debug --ns=alloc "duplicate delivery for $(gcr_alloc_key "$job_id" "$attempt")"
        RESPONSE_CODE=204
        return 0
    fi

    key="$(gcr_alloc_key "$job_id" "$attempt")"
    if ! gcr_lock_acquire "$key"; then
        RESPONSE_CODE=204
        return 0
    fi
    existing="$(gcr_record_get "$job_id" "$attempt")"
    if [ -n "$existing" ]; then
        gcr_lock_release "$key"
        RESPONSE_CODE=204
        return 0
    fi

    if [ "$label_count" -ne 1 ]; then
        gcr_lock_release "$key"
        gcr_event "refused" "$job_id" "{\"repo\":\"$repo\",\"label_count\":$label_count}"
        RESPONSE_CODE=202; RESPONSE_BODY="refused: exactly one label required"
        return 0
    fi

    if ! profile="$(gcr_decide "$label" "$repo")"; then
        gcr_lock_release "$key"
        gcr_event "refused" "$job_id" "{\"repo\":\"$repo\",\"label\":\"$label\"}"
        RESPONSE_CODE=202; RESPONSE_BODY="refused: repo or label not allowed"
        return 0
    fi

    set -- $profile
    server_type="$1"; ttl_min="$2"

    if ! gcr_lock_acquire admission; then
        rec="$(jq -n --arg j "$job_id" --arg a "$attempt" --arg r "$repo" \
            --arg l "$label" --arg t "$(gcr_now_epoch)" \
            '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
              created_at:$t, ttl_min:null, vm_id:"", vm_name:"",
              status:"deferred"}')"
        gcr_record_put "$job_id" "$attempt" "$rec"
        gcr_lock_release "$key"
        gcr_event "deferred" "$job_id" "{\"reason\":\"admission-busy\"}"
        RESPONSE_CODE=202; RESPONSE_BODY="deferred: admission busy"
        return 0
    fi

    active="$(gcr_count_active)"
    repo_active="$(gcr_count_active_repo "$repo")"
    if [ "$active" -ge "${GCR_CONCURRENCY_CAP:-2}" ] \
        || [ "$repo_active" -ge "${GCR_PER_REPO_CAP:-1}" ]; then
        rec="$(jq -n --arg j "$job_id" --arg a "$attempt" --arg r "$repo" \
            --arg l "$label" --arg t "$(gcr_now_epoch)" \
            '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
              created_at:$t, ttl_min:null, vm_id:"", vm_name:"",
              status:"deferred"}')"
        gcr_record_put "$job_id" "$attempt" "$rec"
        gcr_lock_release admission
        gcr_lock_release "$key"
        gcr_event "deferred" "$job_id" "{\"active\":$active,\"repo_active\":$repo_active}"
        RESPONSE_CODE=202; RESPONSE_BODY="deferred: capacity"
        return 0
    fi

    claim_status=0
    gcr_claim_idle "$job_id" "$attempt" "$repo" "$label" || claim_status="$?"
    if [ "$claim_status" -eq 0 ]; then
        reused="$(gcr_record_get "$job_id" "$attempt")"
        vm_id="$(gcr_record_field "$reused" vm_id)"
        vm_name="$(gcr_record_field "$reused" vm_name)"
        if gcr_vm_runner_service "$vm_id" start \
            && gcr_vm_runner_service "$vm_id" health \
            && gcr_gitea_runner_disabled "$repo" "$vm_name" false; then
            reused="$(gcr_record_get "$job_id" "$attempt")"
            reused="$(printf '%s' "$reused" | jq -c '.bootstrapped = true | del(.reused_vm)')"
            gcr_record_put "$job_id" "$attempt" "$reused"
        else
            gcr_gitea_runner_disabled "$repo" "$vm_name" true || true
            gcr_event "vm-reuse-start-failed" "$job_id" "{\"vm_id\":$vm_id}"
        fi
        gcr_lock_release admission
        gcr_lock_release "$key"
        gcr_event "vm-reused" "$job_id" "{\"vm_id\":$vm_id,\"label\":\"$label\"}"
        RESPONSE_CODE=202; RESPONSE_BODY="reused $vm_name"
        return 0
    fi
    if [ "$claim_status" -eq 2 ]; then
        rec="$(jq -n --arg j "$job_id" --arg a "$attempt" --arg r "$repo" \
            --arg l "$label" --arg t "$(gcr_now_epoch)" \
            '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
              created_at:$t, ttl_min:null, vm_id:"", vm_name:"",
              status:"deferred"}')"
        gcr_record_put "$job_id" "$attempt" "$rec"
        gcr_lock_release admission
        gcr_lock_release "$key"
        gcr_event "deferred" "$job_id" "{\"reason\":\"idle-pool-busy\"}"
        RESPONSE_CODE=202; RESPONSE_BODY="deferred: idle pool busy"
        return 0
    fi

    reg_token="$(gcr_gitea_registration_token "$repo")" || {
        gcr_record_del "$job_id" "$attempt"
        gcr_lock_release admission
        gcr_lock_release "$key"
        gcr_event "token-error" "$job_id" "{}"
        RESPONSE_CODE=202; RESPONSE_BODY="registration token unavailable"
        return 0
    }

    vm_name="gcr-${job_id}-${attempt}"
    created_at="$(gcr_now_epoch)"
    create_status=0
    created="$(gcr_vm_create "$vm_name" "$label" "$server_type" "$ttl_min" \
        "$reg_token" "$job_id" "$attempt" "$repo")" || create_status="$?"
    if [ "$create_status" -ne 0 ]; then
        if [ "$create_status" -eq 2 ]; then
            gcr_event "vm-create-ambiguous" "$job_id" "{}"
            RESPONSE_CODE=202; RESPONSE_BODY="VM creation pending recovery"
        else
            gcr_record_del "$job_id" "$attempt"
            gcr_event "vm-create-failed" "$job_id" "{}"
            RESPONSE_CODE=202; RESPONSE_BODY="VM creation failed"
        fi
        gcr_lock_release admission
        gcr_lock_release "$key"
        return 0
    fi
    set -- $created
    vm_id="$1"; actual_server_type="$2"; actual_rate="$3"
    if ! gcr_vm_record_created "$job_id" "$attempt" "$repo" "$label" \
        "$created_at" "$vm_id" "$vm_name" "$ttl_min" \
        "$actual_server_type" "$actual_rate"; then
        gcr_lock_release admission
        gcr_lock_release "$key"
        RESPONSE_CODE=202; RESPONSE_BODY="VM state write failed"
        return 0
    fi
    gcr_lock_release admission
    gcr_lock_release "$key"
    gcr_event "vm-created" "$job_id" "{\"vm_id\":$vm_id,\"label\":\"$label\",\"ttl_min\":$ttl_min}"

    RESPONSE_CODE=202; RESPONSE_BODY="allocated $vm_name"
}

gcr_deallocate() {
    job_id="$1"; attempt="$2"; new_status="$3"

    key="$(gcr_alloc_key "$job_id" "$attempt")"
    gcr_lock_acquire "$key" || return 0

    rec="$(gcr_record_get "$job_id" "$attempt")"
    if [ -z "$rec" ]; then
        gcr_lock_release "$key"
        return 0
    fi

    case "$(gcr_record_field "$rec" status)" in
        pending_vm|vm_active) ;;
        *)
            gcr_lock_release "$key"
            return 0
            ;;
    esac

    finish_status=0
    gcr_vm_finish_terminal "$job_id" "$attempt" "$rec" "$new_status" webhook \
        || finish_status="$?"
    gcr_lock_release "$key"
    case "$finish_status" in
        0|2) return 0 ;;
        *) return "$finish_status" ;;
    esac
}

gcr_mark_in_progress() {
    job_id="$1"; attempt="$2"
    key="$(gcr_alloc_key "$job_id" "$attempt")"
    gcr_lock_acquire "$key" || return 0
    rec="$(gcr_record_get "$job_id" "$attempt")"
    case "$(gcr_record_field "$rec" status)" in
        pending_vm|vm_active)
            rec="$(printf '%s' "$rec" | jq -c '.status = "vm_active"')"
            gcr_record_put "$job_id" "$attempt" "$rec"
            ;;
    esac
    gcr_lock_release "$key"
}

gcr_handle_webhook() {
    gcr_read_request || { gcr_respond 400 ""; exit 0; }

    [ "$gcr_hdr_event_type" = "workflow_job" ] || {
        gcr_log debug --ns=webhook "ignored event type: $gcr_hdr_event_type"
        gcr_respond 204 ""; exit 0
    }

    gcr_verify_signature || {
        gcr_log warn --ns=webhook "invalid signature, delivery=$gcr_hdr_delivery"
        gcr_respond 403 "invalid signature"; exit 0
    }

    action="$(printf '%s' "$gcr_body" | jq -r '.action // ""')"
    job_id="$(printf '%s' "$gcr_body" | jq -r '.workflow_job.id // ""')"
    attempt="$(printf '%s' "$gcr_body" | jq -r '.workflow_job.run_attempt // ""')"
    conclusion="$(printf '%s' "$gcr_body" | jq -r '.workflow_job.conclusion // ""')"
    repo="$(printf '%s' "$gcr_body" | jq -r '.repository.full_name // ""')"
    labels_json="$(printf '%s' "$gcr_body" | jq -c '.workflow_job.labels // []')"

    [ -n "$action" ] || { gcr_respond 400 "malformed payload"; exit 0; }
    case "$job_id:$attempt" in
        *[!0-9:]*|:*|*::*|*:|0:*)
            gcr_respond 400 "malformed payload"; exit 0
            ;;
    esac

    case "$action" in
        queued)
            gcr_alloc "$job_id" "$attempt" "$repo" "$labels_json"
            gcr_log info --ns=alloc "queued job=$job_id repo=$repo code=$RESPONSE_CODE $RESPONSE_BODY"
            ;;
        in_progress)
            gcr_mark_in_progress "$job_id" "$attempt"
            RESPONSE_CODE=204
            ;;
        completed)
            gcr_deallocate "$job_id" "$attempt" "completed:${conclusion:-unknown}"
            RESPONSE_CODE=204
            ;;
        *)
            gcr_log debug --ns=webhook "unhandled action: $action"
            RESPONSE_CODE=204
            ;;
    esac

    gcr_respond "$RESPONSE_CODE" "$RESPONSE_BODY"
}
