#!/bin/dash
# Hetzner Cloud API wrappers for gitea-runner-controller.
# Requires: HCLOUD_TOKEN_FILE, GCR_HETZNER_LOCATION, GCR_IMAGE_ID,
#           GCR_ACT_RUNNER_VERSION, GCR_ACT_RUNNER_SHA256, GCR_NIX_VERSION,
#           GCR_NIX_TARBALL_SHA256, GCR_GITEA_URL
# All VMs carry the tag pair gitea-runner-controller=managed plus gcr.* metadata.

GCR_API="https://api.hetzner.cloud/v1"

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
    if [ -n "$body" ]; then
        code="$(printf '%s' "$body" | curl -sS -X "$method" \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            -o "$GCR_LAST_BODY" \
            -w '%{http_code}' \
            "$GCR_API$path")"
    else
        code="$(curl -sS -X "$method" \
            -H "Authorization: Bearer $token" \
            -o "$GCR_LAST_BODY" \
            -w '%{http_code}' \
            "$GCR_API$path")"
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

gcr_vm_build_userdata() {
    vm_name="$1"; label="$2"; reg_token="$3"

    nix_conf='accept-flake-config = true
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gW4x6l1xP+GxgH0r7u+f6p1VFlr0= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
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

    # NOTE(yukkop): token reaches only this VM's Hetzner metadata service;
    # ephemeral registration makes it useless after the single job exits.
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
      Description=Gitea ephemeral Actions runner
      After=network-online.target gcr-bootstrap.service
      Requires=gcr-bootstrap.service

      [Service]
      Type=simple
      Environment=GITEA_INSTANCE_URL=$GCR_GITEA_URL
      Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$reg_token
      ExecStart=/usr/local/bin/act_runner daemon --ephemeral --config /etc/gitea-runner/config.yaml
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
# Prints new server id.
gcr_vm_create() {
    vm_name="$1"; label="$2"; server_type="$3"; ttl_min="$4"
    reg_token="$5"; job_id="$6"; attempt="$7"; repo="$8"

    test -n "${GCR_IMAGE_ID:-}" || {
        gcr_log error --ns=hcloud "GCR_IMAGE_ID not set; refusing VM creation"
        return 1
    }

    userdata="$(gcr_vm_build_userdata "$vm_name" "$label" "$reg_token")"
    payload="$(jq -n \
        --arg name "$vm_name" \
        --arg stype "$server_type" \
        --arg image "$GCR_IMAGE_ID" \
        --arg loc "${GCR_HETZNER_LOCATION:-nbg1}" \
        --arg udata "$userdata" \
        --arg jid "$job_id" \
        --arg att "$attempt" \
        --arg repo "$repo" \
        --arg label "$label" \
        --arg ts "$(date -u '+%s')" \
        --arg ttl "$ttl_min" \
        --arg repo_safe "$(printf '%s' "$repo" | tr '/:' '--')" \
        '{name:$name, server_type:$stype, image:$image, location:$loc,
          start_after_create:true,
          labels:{
            "gitea-runner-controller":"managed",
            "gcr.job-id":$jid, "gcr.run-attempt":$att,
            "gcr.repo":$repo_safe, "gcr.label":$label,
            "gcr.created-at":$ts, "gcr.ttl-min":$ttl}}')"

    # Hetzner placement is occasionally transient (resource_unavailable);
    # retry a few times before giving up. NOTE: userdata/cloud-init is NOT
    # used — bootstrap happens over SSH from the controller (see
    # gcr_vm_bootstrap_ssh); MicroOS snapshot's Hetzner datasource cannot
    # fetch user-data (DHCP Exception on this image lineage).
    attempt_n=0
    while :; do
        attempt_n=$((attempt_n + 1))
        if gcr_hcloud_req POST /servers "$payload"; then
            jq -r '.server.id' "$GCR_LAST_BODY"
            return 0
        fi
        gcr_log warn --ns=hcloud "create attempt=$attempt_n failed"
        [ "$attempt_n" -ge 3 ] && return 1
        sleep $((attempt_n * 10))
    done
}

# gcr_vm_destroy SERVER_ID — idempotent best-effort destroy.
gcr_vm_destroy() {
    if ! gcr_hcloud_req DELETE "/servers/$1"; then
        gcr_log warn --ns=hcloud "destroy failed or already gone: server $1"
        return 1
    fi
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
substituters = https://cache.nixos.org https://cache.hectic-lab.com/hectic
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gW4x6l1xP+GxgH0r7u+f6p1VFlr0= hectic:KMQsKow4SoA9K2vOJlOljmx7/Zpf91Yy+5qEtxDDCzA=
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
Description=Gitea ephemeral Actions runner
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
if [ "$label" = "nix" ]; then
  curl -fsSL "https://releases.nixos.org/nix/nix-$GCR_NIX_VERSION/nix-$GCR_NIX_VERSION-x86_64-linux.tar.xz" -o /tmp/nix.tar.xz
  printf '%s  /tmp/nix.tar.xz\n' "$GCR_NIX_TARBALL_SHA256" | sha256sum -c -
  tar -xJf /tmp/nix.tar.xz -C /tmp
  /tmp/nix-$GCR_NIX_VERSION-x86_64-linux/install --no-daemon
  rm -rf /tmp/nix*
fi
curl -fsSL "https://dl.gitea.com/gitea-runner/$GCR_ACT_RUNNER_VERSION/gitea-runner-$GCR_ACT_RUNNER_VERSION-linux-amd64" -o /usr/local/bin/gitea-runner
printf '%s  /usr/local/bin/gitea-runner\n' "$GCR_ACT_RUNNER_SHA256" | sha256sum -c -
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
