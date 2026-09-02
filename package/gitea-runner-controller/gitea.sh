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

# gcr_gitea_list_runners — prints "id name" lines for org hectic-lab.
gcr_gitea_list_runners() {
    token="$(gcr_gitea_admin_token)" || return 1
    curl -fsS -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/orgs/hectic-lab/actions/runners?per_page=50" \
        | jq -r '.entries[] | "\(.id) \(.name)"'
}

gcr_gitea_delete_runner() {
    id="$1"
    token="$(gcr_gitea_admin_token)" || return 1
    curl -fsS -X DELETE -H "Authorization: token $token" \
        "$GCR_GITEA_URL/api/v1/orgs/hectic-lab/actions/runners/$id"
}
