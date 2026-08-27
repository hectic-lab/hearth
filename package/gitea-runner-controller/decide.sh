#!/bin/dash
# Allocation decision for gitea-runner-controller.
# Fail-closed: anything not explicitly allowed here is refused.
#
# gcr_decide LABEL REPO -> prints "<server_type> <ttl_min> <rate_eur_h>" and
# returns 0 when allowed; returns 1 with reason on stderr otherwise.

gcr_label_profile() {
    case "$1" in
        nix)           printf 'cx33 180 0.008' ;;
        ubuntu-latest) printf 'cx33 60 0.008'  ;;
        *) return 1 ;;
    esac
}

gcr_repo_allowed() {
    repo="$1"
    oldIFS="$IFS"
    IFS=,
    for allowed in ${GCR_ALLOWED_REPOS:-}; do
        if [ "$allowed" = "$repo" ]; then
            IFS="$oldIFS"
            return 0
        fi
    done
    IFS="$oldIFS"
    return 1
}

gcr_decide() {
    label="$1"; repo="$2"

    if ! gcr_repo_allowed "$repo"; then
        gcr_log warn --ns=decide "repo not allowed: $repo" 
        return 1
    fi

    # Multi-label jobs are out of MVP scope: ambiguous VM profile mapping.
    if ! profile="$(gcr_label_profile "$label")"; then
        gcr_log warn --ns=decide "unknown or unsupported label: $label"
        return 1
    fi

    printf '%s\n' "$profile"
}

gcr_count_active() {
    count=0
    for f in $(gcr_active_records); do
        status="$(gcr_record_field "$(cat "$f")" status)"
        case "$status" in
            pending_vm|vm_active) count=$((count + 1)) ;;
        esac
    done
    printf '%s' "$count"
}

gcr_count_active_repo() {
    repo="$1"
    count=0
    for f in $(gcr_active_records); do
        rec="$(cat "$f")"
        case "$(gcr_record_field "$rec" status)" in
            pending_vm|vm_active) ;;
            *) continue ;;
        esac
        [ "$(gcr_record_field "$rec" repo)" = "$repo" ] && count=$((count + 1))
    done
    printf '%s' "$count"
}
