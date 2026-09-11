#!/bin/dash
# Gitea API wrappers for gitea-runner-controller.
# Requires: GCR_GITEA_URL, GITEA_REGISTRATION_TOKEN_FILE, GITEA_ADMIN_TOKEN_FILE

gcr_gitea_registration_token() {
    repo="$1"
    token="$(gcr_gitea_admin_token)" || return 1
    owner="${repo%%/*}"
    name="${repo#*/}"
    curl -fsS -X POST -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/repos/$owner/$name/actions/runners/registration-token" \
        | jq -r '.token'
}

gcr_gitea_admin_token() {
    test -r "${GITEA_ADMIN_TOKEN_FILE:-}" || {
        gcr_log error --ns=gitea "GITEA_ADMIN_TOKEN_FILE missing"
        return 1
    }
    tr -d '\n' < "$GITEA_ADMIN_TOKEN_FILE"
}

# gcr_gitea_list_runners REPO — prints "id name" lines for repo runners.
gcr_gitea_list_runners() {
    repo="$1"
    token="$(gcr_gitea_admin_token)" || return 1
    owner="${repo%%/*}"
    name="${repo#*/}"
    curl -fsS -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/repos/$owner/$name/actions/runners" \
        | jq -r '.runners[]? | "\(.id) \(.name)"'
}

# gcr_gitea_list_org_repos OWNER — prints fully-qualified repository names.
gcr_gitea_list_org_repos() {
    owner="$1"
    token="$(gcr_gitea_admin_token)" || return 1
    page=1
    while :; do
        repos="$(curl -fsS -H "Authorization: token $token" \
            "$GCR_GITEA_URL/api/v1/orgs/$owner/repos?page=$page&limit=50")" || return 1
        printf '%s' "$repos" | jq -r '.[]? | .full_name'
        count="$(printf '%s' "$repos" | jq 'length')" || return 1
        [ "$count" -lt 50 ] && return 0
        page=$((page + 1))
    done
}

# gcr_gitea_job_state REPO JOB_ID — prints "<status>:<conclusion>".
gcr_gitea_job_state() {
    repo="$1"; job_id="$2"
    token="$(gcr_gitea_admin_token)" || return 1
    owner="${repo%%/*}"
    name="${repo#*/}"
    curl -fsS -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/repos/$owner/$name/actions/jobs/$job_id" \
        | jq -r '.status + ":" + (.conclusion // "")'
}

gcr_gitea_delete_runner() {
    repo="$1"; id="$2"
    token="$(gcr_gitea_admin_token)" || return 1
    owner="${repo%%/*}"
    name="${repo#*/}"
    curl -fsS -X DELETE -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/repos/$owner/$name/actions/runners/$id"
}

gcr_gitea_set_runner_disabled() {
    repo="$1"; id="$2"; disabled="$3"
    case "$disabled" in true|false) ;; *) return 1 ;; esac
    token="$(gcr_gitea_admin_token)" || return 1
    owner="${repo%%/*}"
    name="${repo#*/}"
    curl -fsS -X PATCH -H "Authorization: token $token" \
        -H 'Content-Type: application/json' --data "{\"disabled\":$disabled}" \
        "$GCR_GITEA_URL/api/v1/repos/$owner/$name/actions/runners/$id" >/dev/null
}

# gcr_gitea_runner_disabled REPO RUNNER_NAME true|false
gcr_gitea_runner_disabled() {
    repo="$1"; runner_name="$2"; disabled="$3"
    runners="$(gcr_gitea_list_runners "$repo")" || return 1
    while read -r id name; do
        [ "$name" = "$runner_name" ] || continue
        gcr_gitea_set_runner_disabled "$repo" "$id" "$disabled"
        return "$?"
    done <<EOF
$runners
EOF
    return 1
}
