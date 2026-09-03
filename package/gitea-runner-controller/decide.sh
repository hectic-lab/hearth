#!/bin/dash
# Allocation decision for gitea-runner-controller.
# Fail-closed: anything not explicitly allowed here is refused.
#
# gcr_decide LABEL REPO -> prints "<server_type> <ttl_min> <rate_eur_h>" and
# returns 0 when allowed; returns 1 with reason on stderr otherwise.

gcr_server_hourly_rate() {
    case "$1" in
        cx23)  printf '0.004' ;;
        cx33)  printf '0.008' ;;
        cx43)  printf '0.016' ;;
        cx53)  printf '0.032' ;;
        cax21) printf '0.003' ;;
        cax31) printf '0.006' ;;
        cax41) printf '0.012' ;;
        cpx52) printf '0.036' ;;
        cpx62) printf '0.072' ;;
        *) return 1 ;;
    esac
}

gcr_label_ttl() {
    case "$1" in
        ubuntu-latest)   printf '60'  ;;
        nix)             printf '180' ;;
        gross-x86)       printf '180' ;;
        gross-arm)       printf '180' ;;
        gross-x86-perf)  printf '180' ;;
        gross-mixed-econ) printf '180' ;;
        gross-nix-x86) printf '180' ;;
        gross-nix-arm) printf '180' ;;
        gross-nix-x86-perf) printf '180' ;;
        gross-nix-mixed-econ) printf '180' ;;
        *) return 1 ;;
    esac
}

# gcr_label_candidates LABEL -> lines: "<server_type> <location> <arch>"
gcr_label_candidates() {
    label="$1"
    case "$label" in
        ubuntu-latest)
            printf '%s\n' 'cx33 nbg1 amd64' 'cx33 fsn1 amd64' 'cx33 hel1 amd64'
            ;;
        nix)
            printf '%s\n' 'cx33 nbg1 amd64' 'cx33 fsn1 amd64' 'cx33 hel1 amd64'
            ;;
        gross-x86)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cx43 nbg1 amd64' 'cx43 fsn1 amd64' 'cx43 hel1 amd64' \
                'cx33 nbg1 amd64' 'cx33 fsn1 amd64' 'cx33 hel1 amd64'
            ;;
        gross-arm)
            printf '%s\n' \
                'cax41 nbg1 arm64' 'cax41 fsn1 arm64' 'cax41 hel1 arm64' \
                'cax31 nbg1 arm64' 'cax31 fsn1 arm64' 'cax31 hel1 arm64' \
                'cax21 nbg1 arm64' 'cax21 fsn1 arm64' 'cax21 hel1 arm64'
            ;;
        gross-x86-perf)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cpx62 nbg1 amd64' 'cpx62 fsn1 amd64' 'cpx62 hel1 amd64' \
                'cpx52 nbg1 amd64' 'cpx52 fsn1 amd64' 'cpx52 hel1 amd64'
            ;;
        gross-mixed-econ)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cax41 nbg1 arm64' 'cax41 fsn1 arm64' 'cax41 hel1 arm64' \
                'cx43 nbg1 amd64' 'cx43 fsn1 amd64' 'cx43 hel1 amd64'
            ;;
        gross-nix-x86)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cx43 nbg1 amd64' 'cx43 fsn1 amd64' 'cx43 hel1 amd64' \
                'cx33 nbg1 amd64' 'cx33 fsn1 amd64' 'cx33 hel1 amd64'
            ;;
        gross-nix-arm)
            printf '%s\n' \
                'cax41 nbg1 arm64' 'cax41 fsn1 arm64' 'cax41 hel1 arm64' \
                'cax31 nbg1 arm64' 'cax31 fsn1 arm64' 'cax31 hel1 arm64' \
                'cax21 nbg1 arm64' 'cax21 fsn1 arm64' 'cax21 hel1 arm64'
            ;;
        gross-nix-x86-perf)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cpx62 nbg1 amd64' 'cpx62 fsn1 amd64' 'cpx62 hel1 amd64' \
                'cpx52 nbg1 amd64' 'cpx52 fsn1 amd64' 'cpx52 hel1 amd64'
            ;;
        gross-nix-mixed-econ)
            printf '%s\n' \
                'cx53 nbg1 amd64' 'cx53 fsn1 amd64' 'cx53 hel1 amd64' \
                'cax41 nbg1 arm64' 'cax41 fsn1 arm64' 'cax41 hel1 arm64' \
                'cx43 nbg1 amd64' 'cx43 fsn1 amd64' 'cx43 hel1 amd64'
            ;;
        *) return 1 ;;
    esac
}

gcr_label_profile() {
    label="$1"
    ttl="$(gcr_label_ttl "$label")" || return 1
    first="$(gcr_label_candidates "$label" | head -n1)" || return 1
    set -- $first
    rate="$(gcr_server_hourly_rate "$1")" || return 1
    printf '%s %s %s' "$1" "$ttl" "$rate"
}

gcr_repo_allowed() {
    repo="$1"
    oldIFS="$IFS"
    IFS=,
    for allowed in ${GCR_ALLOWED_REPOS:-}; do
        suffix="${allowed#*/}"
        if [ "$suffix" = "*" ]; then
            prefix="${allowed%/*}/"
            case "$repo" in
                "$prefix"*) IFS="$oldIFS"; return 0 ;;
            esac
        elif [ "$allowed" = "$repo" ]; then
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
