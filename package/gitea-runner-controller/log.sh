#!/bin/dash
# Log helper for gitea-runner-controller.
# Verbosity via GCR_LOG env: "<level>[;<ns>=<level>]..." e.g. "info;alloc=debug".

MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
WHITE='\033[0;37m'
NC='\033[0m'

gcr_log_enabled() {
    level="$1"
    ns="${2:-core}"
    conf="${GCR_LOG:-info}"
    ns_level=""
    default_level=""
    oldIFS="$IFS"
    IFS=';'
    for pair in $conf; do
        case "$pair" in
            *=*) ns_name="${pair%%=*}"; ns_level="${pair#*=}"
                 [ "$ns_name" = "$ns" ] && { IFS="$oldIFS"; echo "$ns_level"; return 0; } ;;
            *)   default_level="$pair" ;;
        esac
    done
    IFS="$oldIFS"
    echo "${default_level:-info}"
}

gcr_log_level_rank() {
    case "$1" in
        trace)  echo 0 ;;
        debug)  echo 1 ;;
        info)   echo 2 ;;
        notice) echo 3 ;;
        warn)   echo 4 ;;
        error)  echo 5 ;;
        panic)  echo 6 ;;
        *)      echo 7 ;;
    esac
}

gcr_log() {
    level="$1"; shift
    ns="core"
    case "$1" in
        --ns=*) ns="${1#--ns=}"; shift ;;
    esac

    want="$(gcr_log_enabled "$level" "$ns")"
    [ "$(gcr_log_level_rank "$level")" -ge "$(gcr_log_level_rank "$want")" ] || return 0

    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    msg="$1"
    case "$level" in
        trace)  color="$WHITE"   ;;
        debug)  color="$BLUE"    ;;
        info)   color="$GREEN"   ;;
        notice) color="$CYAN"    ;;
        warn)   color="$YELLOW"  ;;
        error)  color="$RED"     ;;
        panic)  color="$MAGENTA" ;;
        *)      color="$WHITE"   ;;
    esac
    printf '%b\n' "${color}${ts} ${level}[${ns}]${NC} $msg" >&2
}

# Security: keep credential values out of logs; keys containing TOKEN/SECRET
# and Authorization token headers are rewritten to <redacted>.
gcr_redact() {
    sed -E \
        -e 's/([A-Za-z0-9_]*(TOKEN|SECRET)[A-Za-z0-9_]*)(=|: ?"?)[^ "]+/\1\3<redacted>/g' \
        -e 's/(Authorization: *token )[^ ]+/\1<redacted>/g'
}
