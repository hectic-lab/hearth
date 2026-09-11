#!/bin/dash
# Hetzner Cloud API wrappers for gitea-runner-controller.
# Requires: HCLOUD_TOKEN_FILE, GCR_HETZNER_LOCATION, GCR_IMAGE_ID,
#           GCR_ACT_RUNNER_VERSION, GCR_ACT_RUNNER_SHA256, GCR_NIX_VERSION,
#           GCR_NIX_TARBALL_SHA256, GCR_GITEA_URL
# All VMs carry the tag pair gitea-runner-controller=managed plus gcr.* metadata.

GCR_API="https://api.hetzner.cloud/v1"

gcr_image_id_for_arch() {
    arch="$1"; label="${2:-}"
    nix_image=0
    case "$label" in nix|gross-nix-*) nix_image=1 ;; esac
    case "$arch:$nix_image" in
        amd64:0) [ -n "${GCR_IMAGE_ID:-}" ] && printf '%s' "$GCR_IMAGE_ID" ;;
        arm64:0) [ -n "${GCR_ARM_IMAGE_ID:-}" ] && printf '%s' "$GCR_ARM_IMAGE_ID" ;;
        amd64:1) [ -n "${GCR_NIX_IMAGE_ID:-}" ] && printf '%s' "$GCR_NIX_IMAGE_ID" ;;
        arm64:1) [ -n "${GCR_ARM_NIX_IMAGE_ID:-}" ] && printf '%s' "$GCR_ARM_NIX_IMAGE_ID" ;;
        *) return 1 ;;
    esac
}

gcr_hcloud_token() {
    test -n "${HCLOUD_TOKEN_FILE:-}" && test -r "$HCLOUD_TOKEN_FILE" || {
        gcr_log error --ns=hcloud "HCLOUD_TOKEN_FILE missing or unreadable"
        return 1
    }
    tr -d '\n' < "$HCLOUD_TOKEN_FILE"
}

# All request state flows through files/exit codes, never command substitution
# ($( ) runs in a subshell and would strand GCR_REQ_FAILED/GCR_LAST_HTTP).
gcr_hcloud_req() {
    # gcr_hcloud_req METHOD PATH [JSON_BODY]
    # Body written to $GCR_LAST_BODY; exit 0 only on HTTP 2xx.
    method="$1"; path="$2"; body="${3:-}"
    token="$(gcr_hcloud_token)" || return 1
    GCR_LAST_BODY="$(mktemp "${TMPDIR:-/tmp}/gcr-resp.XXXXXX")"
    curl_status=0
    if [ -n "$body" ]; then
        code="$(printf '%s' "$body" | curl -sS -X "$method" \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            -o "$GCR_LAST_BODY" \
            -w '%{http_code}' \
            "$GCR_API$path")" || curl_status="$?"
    else
        code="$(curl -sS -X "$method" \
            -H "Authorization: Bearer $token" \
            -o "$GCR_LAST_BODY" \
            -w '%{http_code}' \
            "$GCR_API$path")" || curl_status="$?"
    fi
    case "$code" in ''|*[!0-9]*) code=000 ;; esac
    GCR_LAST_CURL_STATUS="$curl_status"
    GCR_LAST_HTTP="$code"
    if [ "$curl_status" -ne 0 ]; then
        gcr_log warn --ns=hcloud "transport failed path=$path curl=$curl_status http=$code"
        return 1
    fi
    case "$code" in 2??) return 0 ;; esac
    gcr_log warn --ns=hcloud "request failed path=$path http=$code body=$(head -c 200 "$GCR_LAST_BODY" | gcr_redact)"
    return 1
}

gcr_vm_list_managed() {
    if gcr_hcloud_req GET "/servers?label_selector=gitea-runner-controller%3Dmanaged&per_page=50"; then
        jq -S '.servers' "$GCR_LAST_BODY"
    fi
}

# Exact deterministic create identity. Exit 0 = one match (prints id),
# 1 = confirmed absent, 2 = lookup failed or identity invariant violated.
gcr_vm_find_created() {
    find_name="$1"; find_job="$2"; find_attempt="$3"; find_label="$4"
    find_type="$5"; find_location="$6"; find_arch="$7"
    if ! gcr_hcloud_req GET "/servers?name=$find_name"; then
        return 2
    fi
    find_matches="$(jq -c \
        --arg name "$find_name" --arg job "$find_job" --arg attempt "$find_attempt" \
        --arg label "$find_label" --arg type "$find_type" \
        --arg location "$find_location" --arg arch "$find_arch" \
        '[.servers[] | select(
          .name == $name
          and .labels["gitea-runner-controller"] == "managed"
          and .labels["gcr.job-id"] == $job
          and .labels["gcr.run-attempt"] == $attempt
          and .labels["gcr.label"] == $label
          and .labels["gcr.location"] == $location
          and .labels["gcr.arch"] == $arch
          and ((.server_type.name // .server_type) == $type))]' \
        "$GCR_LAST_BODY")" || return 2
    find_count="$(printf '%s' "$find_matches" | jq 'length')" || return 2
    case "$find_count" in
        0) return 1 ;;
        1) printf '%s' "$find_matches" | jq -r '.[0].id' ;;
        *) return 2 ;;
    esac
}

gcr_create_explicitly_rejected() {
    case "$1" in
        400|401|403|404|405|409|412|422|423) return 0 ;;
        *) return 1 ;;
    esac
}

gcr_vm_record_create_ambiguous() {
    ambiguous_name="$1"; ambiguous_label="$2"; ambiguous_ttl="$3"
    ambiguous_job="$4"; ambiguous_attempt="$5"; ambiguous_repo="$6"
    ambiguous_type="$7"; ambiguous_rate="$8"; ambiguous_location="$9"
    shift 9; ambiguous_arch="$1"; ambiguous_http="$2"; ambiguous_curl="$3"
    ambiguous_rec="$(jq -n --arg j "$ambiguous_job" --arg a "$ambiguous_attempt" \
        --arg r "$ambiguous_repo" --arg l "$ambiguous_label" \
        --arg t "$(gcr_now_epoch)" --arg vn "$ambiguous_name" \
        --arg ttl "$ambiguous_ttl" --arg st "$ambiguous_type" \
        --arg rate "$ambiguous_rate" --arg loc "$ambiguous_location" \
        --arg arch "$ambiguous_arch" --arg http "$ambiguous_http" \
        --arg curl "$ambiguous_curl" \
        '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
          created_at:$t, ttl_min:($ttl|tonumber), vm_id:"", vm_name:$vn,
          server_type:$st, budget_rate:$rate, candidate_location:$loc,
          candidate_arch:$arch, create_http:$http, create_curl_status:$curl,
          bootstrapped:false,
          status:"create_ambiguous"}')"
    gcr_record_put "$ambiguous_job" "$ambiguous_attempt" "$ambiguous_rec"
}

gcr_vm_build_userdata() {
    vm_name="$1"; label="$2"; reg_token="$3"

nix_conf='accept-flake-config = true
experimental-features = nix-command flakes
http2 = false
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
sandbox = false'

    runner_config="log:
  level: info
runner:
  file: /var/lib/gitea-runner/.runner
  capacity: 1
  timeout: $(printf '%s' "$(gcr_label_profile "$label")" | awk '{print $2}')m
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s
labels:
  - \"$label:host\""

    ssh_key_block=""
    if [ -n "${GCR_DEBUG_SSH_PUBKEY:-}" ]; then
        ssh_key_block="  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    content: |
      $GCR_DEBUG_SSH_PUBKEY"
    fi

    # NOTE(yukkop): token reaches only this VM's Hetzner metadata service and
    # is used for initial registration, not for later idle-slot assignments.
    printf '%s' "#cloud-config
write_files:
$ssh_key_block
  - path: /etc/ssh/sshd_config.d/99-gcr-root.conf
    permissions: '0644'
    content: |
      PermitRootLogin prohibit-password
      PubkeyAuthentication yes
  - path: /etc/nix/nix.conf
    content: |
$(printf '%s\n' "$nix_conf" | sed 's/^/      /')
  - path: /etc/gitea-runner/config.yaml
    content: |
$(printf '%s\n' "$runner_config" | sed 's/^/      /')
  - path: /etc/systemd/system/gitea-runner.service
    content: |
      [Unit]
       Description=Gitea on-demand Actions runner
      After=network-online.target gcr-bootstrap.service
      Requires=gcr-bootstrap.service

      [Service]
      Type=simple
      Environment=GITEA_INSTANCE_URL=$GCR_GITEA_URL
      Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$reg_token
       ExecStart=/usr/local/bin/act_runner daemon --config /etc/gitea-runner/config.yaml
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/gcr-bootstrap.service
    content: |
      [Unit]
      Description=Bootstrap gitea-runner for ephemeral CI job
      After=network-online.target
      Wants=network-online.target
      Before=gitea-runner.service

      [Service]
      Type=oneshot
      RemainAfterExit=true
      ExecStart=/usr/local/sbin/gcr-bootstrap

      [Install]
      WantedBy=multi-user.target
  - path: /usr/local/sbin/gcr-bootstrap
    permissions: '0700'
    content: |
      #!/bin/sh
      set -eu
      exec > /var/log/gcr-bootstrap.log 2>&1
      curl -fsSL \"https://nixos.org/releases/nix/$GCR_NIX_VERSION/nix-$GCR_NIX_VERSION-x86_64-linux.tar.xz\" -o /tmp/nix.tar.xz
      printf '%s  /tmp/nix.tar.xz\n' \"$GCR_NIX_TARBALL_SHA256\" | sha256sum -c -
      tar -xJf /tmp/nix.tar.xz -C /tmp
      /tmp/nix-$GCR_NIX_VERSION-x86_64-linux/install --no-daemon
      rm -rf /tmp/nix*
      curl -fsSL \"https://dl.gitea.com/gitea-runner/$GCR_ACT_RUNNER_VERSION/gitea-runner-$GCR_ACT_RUNNER_VERSION-linux-amd64\" -o /usr/local/bin/gitea-runner
      printf '%s  /usr/local/bin/gitea-runner\n' \"$GCR_ACT_RUNNER_SHA256\" | sha256sum -c -
      chmod 0755 /usr/local/bin/gitea-runner
      mkdir -p /var/lib/gitea-runner
runcmd:
  - [ sh, -c, 'systemctl enable --now sshd.service 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true' ]
  - [ sh, -c, 'systemctl restart sshd.service 2>/dev/null || systemctl restart ssh 2>/dev/null || true' ]
  - [ systemctl, enable, --now, gitea-runner.service ]
"
}

# gcr_vm_create NAME LABEL SERVER_TYPE TTL_MIN REG_TOKEN JOB_ID ATTEMPT REPO
# Caller holds admission lock. Reserves each affordable candidate before its
# create request; prints new server id, actual server type, and reserved rate.
gcr_vm_create() {
    vm_name="$1"; label="$2"; ttl_min="$4"
    reg_token="$5"; job_id="$6"; attempt="$7"; repo="$8"

    ttl_min="$(gcr_label_ttl "$label")" || return 1
    candidates="$(gcr_label_candidates "$label")" || return 1
    candidate_n=0
    while read -r candidate_type candidate_loc candidate_arch; do
        [ -n "${candidate_type:-}" ] || continue
        candidate_n=$((candidate_n + 1))
        candidate_rate="$(gcr_server_hourly_rate "$candidate_type")" || continue
        if ! gcr_budget_can_add "$candidate_rate" "$ttl_min"; then
            gcr_log info --ns=hcloud "skip candidate[$candidate_n] label=$label type=$candidate_type over budget"
            continue
        fi
        if ! gcr_budget_add "$candidate_rate" "$ttl_min"; then
            gcr_log error --ns=hcloud "budget reservation write failed label=$label type=$candidate_type"
            return 1
        fi
        image_id="$(gcr_image_id_for_arch "$candidate_arch" "$label")" || {
            gcr_log warn --ns=hcloud "skip candidate[$candidate_n] label=$label arch=$candidate_arch no image"
            gcr_budget_sub "$candidate_rate" "$ttl_min" || return 1
            continue
        }
        payload="$(jq -n \
            --arg name "$vm_name" \
            --arg stype "$candidate_type" \
            --arg image "$image_id" \
            --arg loc "$candidate_loc" \
            --arg jid "$job_id" \
            --arg att "$attempt" \
            --arg repo "$repo" \
            --arg label "$label" \
            --arg arch "$candidate_arch" \
            --arg ts "$(date -u '+%s')" \
             --arg ttl "$ttl_min" \
             --arg ssh_key_id "${GCR_HCLOUD_SSH_KEY_ID:-}" \
            --arg repo_safe "$(printf '%s' "$repo" | tr '/:' '--')" \
            '{name:$name, server_type:$stype, image:$image, location:$loc,
               start_after_create:true,
               ssh_keys:(if $ssh_key_id == "" then [] else [$ssh_key_id | tonumber] end),
              labels:{
                "gitea-runner-controller":"managed",
                "gcr.job-id":$jid, "gcr.run-attempt":$att,
                "gcr.repo":$repo_safe, "gcr.label":$label,
                "gcr.arch":$arch, "gcr.location":$loc,
                "gcr.created-at":$ts, "gcr.ttl-min":$ttl}}')"
        gcr_log info --ns=hcloud "try candidate[$candidate_n] label=$label type=$candidate_type arch=$candidate_arch loc=$candidate_loc"
        if gcr_hcloud_req POST /servers "$payload"; then
            printf '%s %s %s\n' \
                "$(jq -r '.server.id' "$GCR_LAST_BODY")" "$candidate_type" "$candidate_rate"
            return 0
        fi
        create_http="${GCR_LAST_HTTP:-000}"
        create_curl="${GCR_LAST_CURL_STATUS:-0}"
        find_status=0
        found_vm_id="$(gcr_vm_find_created "$vm_name" "$job_id" "$attempt" \
            "$label" "$candidate_type" "$candidate_loc" "$candidate_arch")" \
            || find_status="$?"
        if [ "$find_status" -eq 0 ]; then
            printf '%s %s %s\n' "$found_vm_id" "$candidate_type" "$candidate_rate"
            return 0
        fi
        if [ "$find_status" -eq 1 ] \
            && gcr_create_explicitly_rejected "$create_http"; then
            if ! gcr_budget_sub "$candidate_rate" "$ttl_min"; then
                gcr_log error --ns=hcloud "budget reservation rollback failed label=$label type=$candidate_type"
                return 1
            fi
        else
            if ! gcr_vm_record_create_ambiguous "$vm_name" "$label" "$ttl_min" \
                "$job_id" "$attempt" "$repo" "$candidate_type" "$candidate_rate" \
                "$candidate_loc" "$candidate_arch" "$create_http" "$create_curl"; then
                gcr_log error --ns=hcloud "cannot persist ambiguous create job=$job_id type=$candidate_type"
            fi
            return 2
        fi
        if [ "$candidate_n" -le 3 ]; then
            sleep 5
        else
            sleep 1
        fi
    done <<EOF
$candidates
EOF
    return 1
}

# gcr_vm_destroy SERVER_ID — success means DELETE returned HTTP 2xx.
gcr_vm_destroy() {
    if ! gcr_hcloud_req DELETE "/servers/$1"; then
        gcr_log warn --ns=hcloud "destroy failed or already gone: server $1"
        return 1
    fi
}

# Only cleanup records establish prior ownership, making DELETE 404 a
# confirmed-absent success rather than an ambiguous lookup failure.
gcr_vm_destroy_owned() {
    gcr_vm_destroy "$1" && return 0
    [ "${GCR_LAST_HTTP:-}" = "404" ]
}

# Caller holds the lifecycle path's existing ownership locks.
gcr_vm_cleanup_pending() {
    cleanup_job="$1"; cleanup_attempt="$2"; cleanup_rec="$3"
    cleanup_vm_id="$(gcr_record_field "$cleanup_rec" vm_id)"
    if [ "$(gcr_record_field "$cleanup_rec" cleanup_vm_destroyed)" != "true" ]; then
        gcr_vm_destroy_owned "$cleanup_vm_id" || return 1
        cleanup_rec="$(printf '%s' "$cleanup_rec" | jq -c '.cleanup_vm_destroyed = true')"
        gcr_record_put "$cleanup_job" "$cleanup_attempt" "$cleanup_rec" || return 1
    fi
    if [ "$(gcr_record_field "$cleanup_rec" cleanup_refund_budget)" = "true" ] \
        && [ "$(gcr_record_field "$cleanup_rec" cleanup_budget_released)" != "true" ]; then
        cleanup_rate="$(gcr_record_field "$cleanup_rec" budget_rate)"
        cleanup_ttl="$(gcr_record_field "$cleanup_rec" ttl_min)"
        cleanup_refund_key="$(gcr_alloc_key "$cleanup_job" "$cleanup_attempt")"
        gcr_budget_refund_once "$cleanup_refund_key" "$cleanup_rate" "$cleanup_ttl" \
            || return 1
        cleanup_rec="$(printf '%s' "$cleanup_rec" | jq -c '.cleanup_budget_released = true')"
        gcr_record_put "$cleanup_job" "$cleanup_attempt" "$cleanup_rec" || return 1
    fi
    gcr_record_del "$cleanup_job" "$cleanup_attempt"
}

# Persist intent before DELETE. Normal lifecycle teardown never changes budget;
# failed creation passes REFUND_BUDGET=true to release its unused reservation.
gcr_vm_cleanup_start() {
    cleanup_job="$1"; cleanup_attempt="$2"; cleanup_source="$3"
    cleanup_reason="$4"; cleanup_refund="$5"
    cleanup_rec="$(printf '%s' "$cleanup_source" | jq -c \
        --arg reason "$cleanup_reason" --argjson refund "$cleanup_refund" \
        '.status = "cleanup_pending"
         | .cleanup_reason = $reason
         | .cleanup_refund_budget = $refund
         | .cleanup_vm_destroyed = false
         | .cleanup_budget_released = false')"
    gcr_record_put "$cleanup_job" "$cleanup_attempt" "$cleanup_rec" || return 1
    gcr_vm_cleanup_pending "$cleanup_job" "$cleanup_attempt" "$cleanup_rec"
}

# Caller holds allocation and admission locks. A failed primary write first
# persists cleanup ownership; reservation is released only after destroy.
gcr_vm_record_created() {
    record_job="$1"; record_attempt="$2"; record_repo="$3"; record_label="$4"
    record_created="$5"; record_vm_id="$6"; record_vm_name="$7"
    record_ttl="$8"; record_type="$9"; shift 9; record_rate="$1"
    record_rec="$(jq -n --arg j "$record_job" --arg a "$record_attempt" \
        --arg r "$record_repo" --arg l "$record_label" --arg t "$record_created" \
        --arg v "$record_vm_id" --arg vn "$record_vm_name" --arg ttl "$record_ttl" \
        --arg st "$record_type" --arg rate "$record_rate" \
        '{job_id:$j, run_attempt:$a, repo:$r, label:$l,
          created_at:$t, ttl_min:($ttl|tonumber), vm_id:($v|tonumber),
          vm_name:$vn, server_type:$st, budget_rate:$rate,
          bootstrapped:false, status:"pending_vm"}')"
    gcr_record_put "$record_job" "$record_attempt" "$record_rec" && return 0

    if ! gcr_vm_cleanup_start "$record_job" "$record_attempt" "$record_rec" \
        state-write-failed true; then
        cleanup_rec="$(gcr_record_get "$record_job" "$record_attempt")"
        [ "$(gcr_record_field "$cleanup_rec" status)" = "cleanup_pending" ] && return 1
        gcr_log error --ns=alloc "cannot persist cleanup record job=$record_job vm=$record_vm_id"
        return 1
    fi
    return 1
}

gcr_vm_public_ip() {
    # gcr_vm_public_ip SERVER_ID -> ipv4 or empty
    if gcr_hcloud_req GET "/servers/$1"; then
        jq -r '.server.public_net.ipv4.ip // ""' "$GCR_LAST_BODY"
    fi
}

# Stop idle runners so Gitea cannot schedule work before atomic reuse claim.
# The controller starts the service only after the claim record is written.
gcr_vm_runner_service() {
    vm_id="$1"; action="$2"
    case "$action" in start|stop) ;; *) return 1 ;; esac
    ip="$(gcr_vm_public_ip "$vm_id")" || return 1
    [ -n "$ip" ] || return 1
    test -n "${GCR_SSH_PRIVKEY_FILE:-}" && test -r "$GCR_SSH_PRIVKEY_FILE" || return 1
    key_tmp="$(mktemp "${TMPDIR:-/tmp}/gcr-runner-sshkey.XXXXXX")"
    cat "$GCR_SSH_PRIVKEY_FILE" > "$key_tmp"
    printf '\n' >> "$key_tmp"
    chmod 0600 "$key_tmp"
    ssh_opts="-i $key_tmp -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"
    if timeout 30 ssh $ssh_opts "root@$ip" "systemctl $action gitea-runner.service"; then
        rm -f "$key_tmp"
        return 0
    fi
    rm -f "$key_tmp"
    return 1
}

gcr_vm_collect_diagnostics() {
    vm_id="$1"; ip="$2"; job_id="$3"; reason="$4"

    [ "${GCR_DESTROY_DIAGNOSTICS:-1}" = "1" ] || return 0
    [ -n "$ip" ] || return 0
    test -n "${GCR_SSH_PRIVKEY_FILE:-}" && test -r "$GCR_SSH_PRIVKEY_FILE" || {
        gcr_log warn --ns=hcloud "skip diagnostics vm=$vm_id job=$job_id reason=$reason: SSH key unavailable"
        return 0
    }

    key_tmp="$(mktemp "${TMPDIR:-/tmp}/gcr-diag-sshkey.XXXXXX")"
    cat "$GCR_SSH_PRIVKEY_FILE" > "$key_tmp"
    printf '\n' >> "$key_tmp"
    chmod 0600 "$key_tmp"
    timeout_sec="${GCR_DESTROY_DIAGNOSTICS_TIMEOUT_SEC:-20}"
    ssh_opts="-i $key_tmp -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"
    diag_out="$(mktemp "${TMPDIR:-/tmp}/gcr-diag-out.XXXXXX")"

    gcr_log warn --ns=hcloud "pre-destroy diagnostics begin vm=$vm_id ip=$ip job=$job_id reason=$reason timeout=${timeout_sec}s"
    if timeout -k 5 "$timeout_sec" ssh $ssh_opts "root@$ip" \
        'set +e
         export LC_ALL=C
         printf "== time ==\n"; date -u
         printf "== uptime ==\n"; uptime
         printf "== memory ==\n"; free -h
         printf "== disk ==\n"; df -h / /nix /var/lib 2>/dev/null || df -h
         printf "== pressure ==\n"; cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null
         printf "== kernel failure signals ==\n"; dmesg -T 2>/dev/null | grep -Ei "out of memory|oom-kill|killed process|no space|I/O error|EXT4-fs error|xfs.*error|nvme.*error" | tail -n 80
         printf "== runner service ==\n"; systemctl show gitea-runner.service -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainCode -p NRestarts 2>/dev/null
         printf "== bootstrap service ==\n"; systemctl show gcr-bootstrap.service -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainCode 2>/dev/null
         printf "== process sample ==\n"; ps -eo pid,ppid,stat,etime,comm 2>/dev/null | head -n 80' \
        > "$diag_out" 2>&1; then
        gcr_redact < "$diag_out" >&2
        gcr_log warn --ns=hcloud "pre-destroy diagnostics complete vm=$vm_id job=$job_id reason=$reason"
    else
        gcr_redact < "$diag_out" >&2
        gcr_log warn --ns=hcloud "pre-destroy diagnostics failed vm=$vm_id job=$job_id reason=$reason"
    fi
    rm -f "$key_tmp" "$diag_out"
    return 0
}

# Bootstrap delivery is SSH-push from the controller. The MicroOS snapshot's
# cloud-init cannot fetch user-data (Hetzner datasource DHCP failure), so the
# controller drives provisioning over SSH using GCR_SSH_PRIVKEY_FILE, whose
# public half is authorized on every ephemeral VM (project ssh-key injection).
gcr_bootstrap_script() {
    # gcr_bootstrap_script LABEL REG_TOKEN TTL_MIN RUNNER_NAME -> POSIX sh payload
    label="$1"; reg_token="$2"; ttl_min="$3"; runner_name="$4"
    nix_conf='accept-flake-config = true
experimental-features = nix-command flakes
http2 = false
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
sandbox = false'

    runner_config="log:
  level: info
runner:
  file: /var/lib/gitea-runner/.runner
  capacity: 1
  timeout: ${ttl_min}m
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s
labels:
  - \"$label:host\""

    cat <<BSEOF
exec >/var/log/gcr-bootstrap.log 2>&1
set -eu
mkdir -p /etc/nix /etc/gitea-runner /var/lib/gitea-runner /usr/local/bin
cat > /etc/nix/nix.conf <<'NIXEOF'
$nix_conf
NIXEOF
cat > /etc/gitea-runner/config.yaml <<'CFGEOF'
$runner_config
CFGEOF
cat > /usr/local/sbin/gcr-runner-start <<STARTEOF
#!/bin/sh
set -eu
if [ ! -f /var/lib/gitea-runner/.runner ]; then
  /usr/local/bin/gitea-runner register --no-interactive --instance $GCR_GITEA_URL --token $reg_token --name $runner_name --labels $label:host --config /etc/gitea-runner/config.yaml
fi
exec /usr/local/bin/gitea-runner daemon --config /etc/gitea-runner/config.yaml
STARTEOF
chmod 0700 /usr/local/sbin/gcr-runner-start
cat > /etc/systemd/system/gitea-runner.service <<UNITEOF
[Unit]
Description=Gitea on-demand Actions runner
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/gitea-runner
Environment=HOME=/var/lib/gitea-runner
ExecStart=/usr/local/sbin/gcr-runner-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
cat > /usr/local/sbin/gcr-install <<INSEOF
#!/bin/sh
set -eu
nix_arch=""
nix_sha=""
case "$label" in
  nix|gross-nix-*)
  case "\$(uname -m)" in
    x86_64)
      nix_arch=x86_64-linux
      nix_sha="$GCR_NIX_TARBALL_SHA256"
      ;;
    aarch64|arm64)
      nix_arch=aarch64-linux
      nix_sha="$GCR_ARM_NIX_TARBALL_SHA256"
      ;;
    *)
      echo "unsupported arch for Nix bootstrap: $(uname -m)" >&2
      exit 1
      ;;
  esac
  curl -fsSL "https://releases.nixos.org/nix/nix-$GCR_NIX_VERSION/nix-$GCR_NIX_VERSION-\\\$nix_arch.tar.xz" -o /tmp/nix.tar.xz
  printf '%s  /tmp/nix.tar.xz\n' "\\\$nix_sha" | sha256sum -c -
  tar -xJf /tmp/nix.tar.xz -C /tmp
  mkdir -p /nix
  getent group nixbld >/dev/null 2>&1 || groupadd --system nixbld
  for nixbld_user in 1 2 3 4 5 6 7 8 9 10; do
    if ! id "nixbld\\\$nixbld_user" >/dev/null 2>&1; then
      useradd --system --no-create-home --shell /usr/sbin/nologin \
        --gid nixbld "nixbld\\\$nixbld_user"
    fi
    usermod --append --groups nixbld "nixbld\\\$nixbld_user"
  done
  /tmp/nix-$GCR_NIX_VERSION-\\\$nix_arch/install --no-daemon
  ln -sf /root/.nix-profile/bin/nix /usr/local/bin/nix
  rm -rf /tmp/nix*
  ;;
esac
case "$label" in
  nix|gross-nix-*)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    fi
    ;;
esac
 case "\$(uname -m)" in
   x86_64) runner_arch=amd64 ;;
   aarch64|arm64) runner_arch=arm64 ;;
   *) echo "unsupported arch for runner bootstrap: \$(uname -m)" >&2; exit 1 ;;
 esac
  curl -fsSL "https://dl.gitea.com/gitea-runner/$GCR_ACT_RUNNER_VERSION/gitea-runner-$GCR_ACT_RUNNER_VERSION-linux-\\\$runner_arch" -o /usr/local/bin/gitea-runner
  if [ "\\\$runner_arch" = amd64 ]; then
   printf '%s  /usr/local/bin/gitea-runner\n' "$GCR_ACT_RUNNER_SHA256" | sha256sum -c -
 fi
chmod 0755 /usr/local/bin/gitea-runner
INSEOF
chmod 0700 /usr/local/sbin/gcr-install
/usr/local/sbin/gcr-install
systemctl daemon-reload
systemctl enable --now gitea-runner.service
BSEOF
}

# gcr_vm_bootstrap_ssh IP LABEL REG_TOKEN — blocking; returns ssh exit status.
gcr_vm_bootstrap_ssh() {
    ip="$1"; label="$2"; reg_token="$3"; runner_name="$4"
    test -n "${GCR_SSH_PRIVKEY_FILE:-}" && test -r "$GCR_SSH_PRIVKEY_FILE" || {
        gcr_log error --ns=hcloud "GCR_SSH_PRIVKEY_FILE missing or unreadable"
        return 1
    }
    key_tmp="$(mktemp "${TMPDIR:-/tmp}/gcr-sshkey.XXXXXX")"
    cat "$GCR_SSH_PRIVKEY_FILE" > "$key_tmp"
    printf '\n' >> "$key_tmp"
    chmod 0600 "$key_tmp"
    SSH_OPTS="-i $key_tmp -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"

    waited=0
    until ssh $SSH_OPTS "root@$ip" true 2>/dev/null; do
        waited=$((waited + 5))
        [ "$waited" -ge 900 ] && {
            gcr_log warn --ns=hcloud "sshd never came up on $ip"
            rm -f "$key_tmp"
            return 1
        }
        sleep 5
    done

    ttl_min="$(printf '%s' "$(gcr_label_profile "$label")" | awk '{print $2}')"
    script="$(gcr_bootstrap_script "$label" "$reg_token" "$ttl_min" "$runner_name")"
    if printf '%s' "$script" | ssh $SSH_OPTS "root@$ip" sh -s; then
        rm -f "$key_tmp"
        return 0
    fi
    rm -f "$key_tmp"
    return 1
}
