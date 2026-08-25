# Gitea Runner Infrastructure Runbook

## Scope

This directory is the repo-owned boundary for the first Gitea Actions runner
pool. Task 1 only establishes the scaffold and immutable decision contract;
downstream tasks will add OpenTofu backend/provider files, Kubernetes manifests,
and a Nix-capable runner image under the existing subdirectories.

The target service is `https://gitea.hectic-lab.com` for the Gitea organization
`hectic-lab`. The first pool is fixed-size and trusted-only. "Ephemeral" means
workflow job containers are ephemeral, while each runner pod keeps its runner
identity in per-pod `/data/.runner` storage backed by a StatefulSet PVC.

## Immutable decisions

- Infrastructure is managed with OpenTofu command examples only, using the
  `tofu` CLI.
- Cloud provider is Hetzner; cluster bootstrap uses kube-hetzner.
- Remote state uses the S3 backend bucket `gitea-runner-hectic-lab`.
- Runner implementation is the non-Enterprise `gitea/runner`.
- Runner registration uses a Gitea organization-scoped token for `hectic-lab`.
- Runtime token delivery is SOPS-backed and mounted into the runner pod as a
  file read through `GITEA_RUNNER_REGISTRATION_TOKEN_FILE`; plaintext token
  environment variables are not the contract.
- Kubernetes runner lifecycle uses a StatefulSet with one PVC per pod for
  `/data`, including `/data/.runner`.
- Container builds run through privileged rootful DinD inside trusted runner
  pods; host Docker socket mounting is not an implementation path.
- The active runner label is `ubuntu-latest`. The `nix` label is not live until
  the Nix-capable image has been pushed and a concrete registry-reported digest
  is added to the runner ConfigMap.
- First scope is trusted internal workflows only, with no untrusted fork or PR
  workflow support.
- First scope has no autoscaling, no KEDA, and no dynamic runner controller.

## Lifecycle boundaries

- `infra/gitea-runners/opentofu/`: downstream OpenTofu stack for the S3 backend
  contract, Hetzner provider configuration, and kube-hetzner module wiring.
- `infra/gitea-runners/k8s/`: downstream namespace, ConfigMap, Secret mount,
  StatefulSet, PVC, DinD sidecar, cleanup, and operational manifest work.
- `infra/gitea-runners/image/`: downstream notes or sources for the runner image
  handoff; package or flake output changes are outside Task 1.
- `infra/gitea-runners/runbook.md`: this contract plus later operational
  commands, rollback notes, and acceptance evidence references.

## Guardrails

- Enterprise ARC/actions-runner-controller are rejected alternatives and must
  not be implemented here. Do not add ARC custom resources, controller install
  instructions, or GitHub Actions ARC assumptions.
- Untrusted fork/PR workflows are out of first scope; privileged DinD is only
  acceptable for trusted internal jobs.
- Autoscaling/KEDA is out of first scope; start with a fixed-size StatefulSet
  runner pool.
- No actual secrets are committed: no kubeconfig, runner token, Hetzner token,
  S3 credentials, decrypted SOPS files, or SOPS age keys.
- OpenTofu must not manage plaintext Kubernetes Secrets containing the Gitea
  runner token; Kubernetes receives the token as a mounted file secret instead.
- Do not use `localhost` or `127.0.0.1` as the Gitea URL inside job containers;
  jobs must reach the public HTTPS service.

## Initial acceptance commands

Run from the repository root:

```sh
test -d infra/gitea-runners/opentofu && test -d infra/gitea-runners/k8s && test -d infra/gitea-runners/image
test -f infra/gitea-runners/runbook.md
grep -n "OpenTofu\|kube-hetzner\|StatefulSet\|DinD\|SOPS\|trusted" infra/gitea-runners/runbook.md
grep -R "[E]nterprise ARC\|[a]ctions-runner-controller" infra/gitea-runners
grep -R "[t]erraform " infra/gitea-runners || true
grep -R "[D]ECISION NEEDED" infra/gitea-runners || true
```

Expected outcomes: the directory and file checks exit 0; the architecture-term
grep shows this contract; ARC references appear only in the rejected-alternative
guardrail above; there are no forbidden CLI command examples and no unresolved
decision placeholders.

## Downstream placeholders

- Task 2: add OpenTofu backend/provider files and verify S3 state safety.
- Task 3: add SOPS secret contract and runtime token delivery details.
- Task 4: define or package the Nix-capable runner image for the `nix` label.
- Task 5+: provision kube-hetzner, add Kubernetes resources, verify workflows,
  and document cleanup, rollback, and scaling operations.

## Runner lifecycle cleanup

All lifecycle commands are scoped to the runner namespace:

```sh
kubectl -n gitea-runners get statefulset gitea-runner
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide
```

The scheduled cleanup manifest is dry-run only. It lists the StatefulSet, active
runner pods, runner PVCs, and PVCs whose expected StatefulSet pod is absent. It
does not delete pods, PVCs, Docker data, or Gitea runner registrations.

Run the same inventory on demand without waiting for the schedule:

```sh
kubectl -n gitea-runners create job gitea-runner-cleanup-dry-run-manual --from=cronjob/gitea-runner-cleanup-dry-run
kubectl -n gitea-runners wait --for=condition=complete job/gitea-runner-cleanup-dry-run-manual --timeout=2m
kubectl -n gitea-runners logs job/gitea-runner-cleanup-dry-run-manual -c cleanup-dry-run
```

The cleanup job template has `ttlSecondsAfterFinished: 3600`, so completed
manual dry-run jobs are garbage-collected by Kubernetes instead of requiring an
operator to remove finished jobs manually.

If a PVC such as `data-gitea-runner-3` is intentionally deleted, the matching
pod loses `/data/.runner`. That runner identity must then be deregistered from
Gitea or the replacement pod must be allowed to re-register intentionally with
the current organization runner token. Do not delete an active runner PVC as a
normal cleanup step.

Non-UI Gitea registration reconciliation uses the Gitea API with a separate
admin token. Store that token outside this repository and pass it as a file; do
not print it:

```sh
kubectl -n gitea-runners create secret generic gitea-runner-admin-token --from-file=token=/secure/path/gitea-admin-token
kubectl -n gitea-runners run gitea-runner-registration-dry-run \
  --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"containers":[{"name":"gitea-runner-registration-dry-run","image":"curlimages/curl:8.10.1","command":["/bin/sh","-ec","umask 077; cfg=$(mktemp); trap '\''rm -f \"$cfg\"'\'' EXIT; { printf '\''header = \"Authorization: token '\''; cat /admin-token/token; printf '\''\"\\n'\''; printf '\''url = \"https://gitea.hectic-lab.com/api/v1/orgs/hectic-lab/actions/runners\"\\n'\''; } > \"$cfg\"; curl -fsS --config \"$cfg\""],"volumeMounts":[{"name":"admin-token","mountPath":"/admin-token","readOnly":true}]}],"volumes":[{"name":"admin-token","secret":{"secretName":"gitea-runner-admin-token","defaultMode":256}}]}}'
kubectl -n gitea-runners logs pod/gitea-runner-registration-dry-run
```

Delete the temporary `gitea-runner-admin-token` Secret only after the dry-run pod
has completed and its logs have been collected. Do not keep this admin token in
the runner namespace longer than the reconciliation window.

Only remove a stale Gitea runner registration after the corresponding pod/PVC
was intentionally deleted or `/data/.runner` was intentionally reset. Prefer a
Gitea CLI/API deletion from the Gitea server or an admin workstation; manual UI
cleanup is a fallback, not the only path. Record the removed runner name and the
Kubernetes PVC/pod deletion that made it stale.

After the dry-run list identifies a stale registration and the PVC/pod deletion
has been recorded, remove that exact Gitea runner by id through the API:

```sh
runner_id='REPLACE_WITH_STALE_RUNNER_ID'
umask 077
curl_config=$(mktemp /tmp/gitea-runner-admin-curl.XXXXXX)
trap 'rm -f "$curl_config"' EXIT
{
  printf 'request = "DELETE"\n'
  printf 'header = "Authorization: token '
  cat /secure/path/gitea-admin-token
  printf '"\n'
  printf 'url = "https://gitea.hectic-lab.com/api/v1/orgs/hectic-lab/actions/runners/%s"\n' "$runner_id"
} > "$curl_config"
curl -fsS --config "$curl_config"
```

Do not run the delete command for a runner that still has an active
`gitea-runner-*` pod or a retained `data-gitea-runner-*` PVC unless that PVC is
being intentionally reset for re-registration.

## Docker-in-Docker storage cleanup

Docker layers live inside each DinD sidecar at `/var/lib/docker`, backed by the
pod-local `docker-graph` `emptyDir`; the host Docker socket is not used. Always
list disk usage before pruning, and run the command only against the `docker`
container in runner pods in `gitea-runners`. Because this storage is pod-local,
loop over pods for pool-wide cleanup:

```sh
for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system df
done

for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system prune --all --force --filter until=24h
done

for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system df
done
```

For one pod, replace the StatefulSet target with the pod name:

```sh
kubectl -n gitea-runners exec pod/gitea-runner-0 -c docker -- docker system df
kubectl -n gitea-runners exec pod/gitea-runner-0 -c docker -- docker system prune --all --force --filter until=24h
```

Do not run host-level Docker cleanup commands and do not mount or prune a host
Docker socket. If a pod is deleted, its `emptyDir` Docker graph is removed by
Kubernetes; the `/data` PVC remains and still controls runner identity.

## Token rotation

Rotate the Gitea organization runner token without printing decrypted values:

```sh
sops sus/gitea-runners.yaml
umask 077
token_file=$(mktemp /tmp/gitea-runner-token.XXXXXX)
trap 'rm -f "$token_file"' EXIT
sops -d --extract '["gitea"]["hectic-lab"]["org-runner-registration-token"]' sus/gitea-runners.yaml > "$token_file"
kubectl -n gitea-runners create secret generic gitea-runner-token \
  --from-file=token="$token_file" \
  --dry-run=client \
  -o yaml | kubectl -n gitea-runners apply -f -
kubectl -n gitea-runners rollout restart statefulset/gitea-runner
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200 | grep -Eq 'token|GITEA_RUNNER_REGISTRATION_TOKEN' && exit 1 || true
```

The `rollout restart` command above is the controlled restart path for this
StatefulSet. Observe the rollout and each ordinal until all replacement pods are
Ready; do not delete runner pods directly as part of normal token rotation:

```sh
kubectl -n gitea-runners wait --for=condition=Ready pod/gitea-runner-0 --timeout=5m
kubectl -n gitea-runners wait --for=condition=Ready pod/gitea-runner-1 --timeout=5m
kubectl -n gitea-runners wait --for=condition=Ready pod/gitea-runner-2 --timeout=5m
kubectl -n gitea-runners wait --for=condition=Ready pod/gitea-runner-3 --timeout=5m
kubectl -n gitea-runners wait --for=condition=Ready pod/gitea-runner-4 --timeout=5m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
```

Verification must confirm the token file mount remains present while the token
value never appears in logs or evidence:

```sh
kubectl -n gitea-runners describe pod gitea-runner-0 | grep -n '/runner-secrets\|gitea-runner-token'
kubectl -n gitea-runners logs pod/gitea-runner-0 -c runner --tail=200 | grep -Eq 'token|GITEA_RUNNER_REGISTRATION_TOKEN' && exit 1 || true
```

## Deploy and status

These commands are executable only when the external inputs are available:

- `TF_VAR_hcloud_token`
- `TF_VAR_ssh_public_key`
- `TF_VAR_ssh_private_key`
- S3 backend credentials and endpoint access
- a matching SOPS age identity for `sus/gitea-runners.yaml`
- `kubectl` access to the target cluster
- a concrete digest for the pushed Nix-capable runner image, if enabling the
  `nix` label

If any input is missing, stop before `tofu apply`. Do not guess values or reuse
stale kubeconfig files.

Before production Kubernetes apply or rollout, satisfy both manifest gates:

1. Create or update the `gitea-runner-token` Secret from SOPS. The active
   Kustomize overlay intentionally does not include a placeholder Secret, but
   the StatefulSet still mounts `secretName: gitea-runner-token` as
   `/runner-secrets/token` for `GITEA_RUNNER_REGISTRATION_TOKEN_FILE`.
2. Keep the active ConfigMap on `ubuntu-latest` only unless the Nix-capable
   image has been pushed successfully. Enable the `nix` label only by adding a
   digest-pinned `docker://` mapping with the exact registry-reported sha256
   digest from that push.

Use the same SOPS materialization pattern as token rotation before applying the
Kubernetes overlay. Applying the namespace alone is allowed so the Secret has a
target namespace; the full overlay remains gated on the Secret and digest
decisions:

```sh
kubectl apply -f infra/gitea-runners/k8s/namespace.yaml
umask 077
token_file=$(mktemp /tmp/gitea-runner-token.XXXXXX)
trap 'rm -f "$token_file"' EXIT
sops -d --extract '["gitea"]["hectic-lab"]["org-runner-registration-token"]' sus/gitea-runners.yaml > "$token_file"
kubectl -n gitea-runners create secret generic gitea-runner-token \
  --from-file=token="$token_file" \
  --dry-run=client \
  -o yaml | kubectl -n gitea-runners apply -f -
```

Do not run `kubectl apply -k infra/gitea-runners/k8s` until the Secret command
above succeeds. Do not claim or enable the `nix` runner label until the image
publication step has produced the concrete digest.

```sh
tofu -chdir=infra/gitea-runners/opentofu init
tofu -chdir=infra/gitea-runners/opentofu validate
tofu -chdir=infra/gitea-runners/opentofu plan -out=.sisyphus/evidence/task-12-deploy.plan
tofu -chdir=infra/gitea-runners/opentofu apply .sisyphus/evidence/task-12-deploy.plan
export KUBECONFIG="$(tofu -chdir=infra/gitea-runners/opentofu output -raw kubeconfig_path)"
kubectl config current-context
kubectl get nodes -o wide
kubectl get sc
kubectl apply -k infra/gitea-runners/k8s
kubectl -n gitea-runners get statefulset gitea-runner
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get events --sort-by=.lastTimestamp | tail -n 50
kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200
```

Expected status after deploy:

- `kubectl config current-context` names the runner cluster context.
- `kubectl get nodes -o wide` shows all expected Hetzner nodes Ready.
- `kubectl get sc` shows the Hetzner CSI storage class used by runner PVCs.
- `kubectl -n gitea-runners get statefulset gitea-runner` shows 5 desired and 5 ready replicas.
- `kubectl -n gitea-runners get pvc` shows 5 Bound PVCs.
- `kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200` shows the runner daemon started and no token value.

## Scale 5 to 10 to 5

Scaling is a temporary capacity exercise, not the steady-state setting. Scale up,
wait for readiness, run the concurrent smoke jobs, then scale back down to 5.

```sh
kubectl -n gitea-runners scale statefulset/gitea-runner --replicas=10
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide

# Run the concurrent smoke workflows now.

kubectl -n gitea-runners scale statefulset/gitea-runner --replicas=1
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide
```

After scaling back down, inspect the cleanup dry-run and deregister any stale
runner registrations only for pods or PVCs that were intentionally removed.

## Cleanup and stale runner deregistration

Use the dry-run cleanup job to list the StatefulSet, active pods, PVCs, and any
PVC candidates whose pod is gone. It must not delete active resources.

```sh
kubectl -n gitea-runners create job gitea-runner-cleanup-dry-run-manual --from=cronjob/gitea-runner-cleanup-dry-run
kubectl -n gitea-runners wait --for=condition=complete job/gitea-runner-cleanup-dry-run-manual --timeout=2m
kubectl -n gitea-runners logs job/gitea-runner-cleanup-dry-run-manual -c cleanup-dry-run
```

Pool-wide DinD storage checks and cleanup:

```sh
for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system df
done

for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system prune --all --force --filter until=24h
done

for pod in $(kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n gitea-runners exec "pod/${pod}" -c docker -- docker system df
done
```

If a PVC such as `data-gitea-runner-3` is intentionally deleted, the matching
pod loses `/data/.runner`. Deregister that runner from Gitea, or let the
replacement pod re-register intentionally with the current organization token.
Never delete an active runner PVC as routine cleanup.

Non-UI Gitea registration reconciliation uses an admin token stored outside this
repository:

```sh
kubectl -n gitea-runners create secret generic gitea-runner-admin-token --from-file=token=/secure/path/gitea-admin-token
kubectl -n gitea-runners run gitea-runner-registration-dry-run \
  --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"containers":[{"name":"gitea-runner-registration-dry-run","image":"curlimages/curl:8.10.1","command":["/bin/sh","-ec","umask 077; cfg=$(mktemp); trap '\''rm -f \"$cfg\"'\'' EXIT; { printf '\''header = \"Authorization: token '\''; cat /admin-token/token; printf '\''\"\\n'\''; printf '\''url = \"https://gitea.hectic-lab.com/api/v1/orgs/hectic-lab/actions/runners\"\\n'\''; } > \"$cfg\"; curl -fsS --config \"$cfg\""],"volumeMounts":[{"name":"admin-token","mountPath":"/admin-token","readOnly":true}]}],"volumes":[{"name":"admin-token","secret":{"secretName":"gitea-runner-admin-token","defaultMode":256}}]}}'
kubectl -n gitea-runners logs pod/gitea-runner-registration-dry-run
```

Delete the temporary `gitea-runner-admin-token` Secret only after the dry-run
pod has completed and its logs have been collected.

After the dry-run list identifies a stale registration and the PVC or pod
deletion has been recorded, remove that exact Gitea runner by id through the
API:

```sh
runner_id='REPLACE_WITH_STALE_RUNNER_ID'
umask 077
curl_config=$(mktemp /tmp/gitea-runner-admin-curl.XXXXXX)
trap 'rm -f "$curl_config"' EXIT
{
  printf 'request = "DELETE"\n'
  printf 'header = "Authorization: token '
  cat /secure/path/gitea-admin-token
  printf '"\n'
  printf 'url = "https://gitea.hectic-lab.com/api/v1/orgs/hectic-lab/actions/runners/%s"\n' "$runner_id"
} > "$curl_config"
curl -fsS --config "$curl_config"
```

Do not run the delete command for a runner that still has an active
`gitea-runner-*` pod or retained `data-gitea-runner-*` PVC unless that PVC is
being intentionally reset for re-registration.

## Application rollback

Rollback the app layer only. Do not use this section to destroy the cluster.

```sh
kubectl -n gitea-runners rollout history statefulset/gitea-runner
kubectl -n gitea-runners rollout undo statefulset/gitea-runner --to-revision=<known-good-revision>
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
kubectl -n gitea-runners get pods -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners get pvc -l app.kubernetes.io/name=gitea-runner -o wide
kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200
```

If a manifest rollback is needed, reapply the repo overlay after checking out the
known-good revision, then re-run the rollout checks:

```sh
kubectl -n gitea-runners apply -k infra/gitea-runners/k8s
kubectl -n gitea-runners rollout status statefulset/gitea-runner --timeout=10m
```

## Full cluster teardown

This destroys Hetzner resources owned by the kube-hetzner stack, including the
`gitea-runners` cluster nodes, the `control-plane` node pool, the
`runner-workers` node pool, the cluster network, load balancer resources,
firewall objects, and any attached Hetzner CSI volumes still managed by the
stack. Do not run teardown unless the destruction is intentional.

```sh
tofu -chdir=infra/gitea-runners/opentofu plan -destroy -out=.sisyphus/evidence/task-12-destroy.plan
tofu -chdir=infra/gitea-runners/opentofu show -no-color .sisyphus/evidence/task-12-destroy.plan
tofu -chdir=infra/gitea-runners/opentofu apply .sisyphus/evidence/task-12-destroy.plan
```

## Partial OpenTofu apply recovery

If `tofu apply` fails after creating some resources, do not destroy blindly.
First reconcile state and inspect what the stack thinks exists:

```sh
tofu -chdir=infra/gitea-runners/opentofu plan -refresh-only -out=.sisyphus/evidence/task-12-refresh.plan
tofu -chdir=infra/gitea-runners/opentofu show -no-color .sisyphus/evidence/task-12-refresh.plan
tofu -chdir=infra/gitea-runners/opentofu state list
```

Then rerun the normal plan path. Use `-target` only as a last resort when a
single resource is stuck and the drift is understood.

## S3 backend recovery

If backend init or state access fails, first verify the bucket and versioning
outside OpenTofu, then reconfigure the backend:

```sh
nix run nixpkgs#awscli2 -- s3api head-bucket --bucket gitea-runner-hectic-lab
nix run nixpkgs#awscli2 -- s3api get-bucket-versioning --bucket gitea-runner-hectic-lab
tofu -chdir=infra/gitea-runners/opentofu init -reconfigure
tofu -chdir=infra/gitea-runners/opentofu plan
```

If the backend reports a stale lock, confirm no `tofu` process is active, then
use `tofu force-unlock <LOCK_ID>` with the lock id from the error. Never force
unlock a live plan or apply.

## Gitea outage troubleshooting

Use the public HTTPS service, not `localhost` or `127.0.0.1` inside job
containers.

```sh
kubectl -n gitea-runners run gitea-outage-probe --rm --restart=Never --image=curlimages/curl:8.10.1 -- curl -fsS https://gitea.hectic-lab.com/api/healthz
kubectl -n gitea-runners logs statefulset/gitea-runner -c runner --tail=200 | grep -E 'connection refused|timeout|tls|certificate|temporary failure' || true
kubectl -n gitea-runners get events --sort-by=.lastTimestamp | tail -n 50
```

If Gitea is down, keep the existing StatefulSet and PVCs intact. Do not delete
`/data/.runner` just because the service is unavailable. Once Gitea returns,
repeat the token rotation or re-registration path if a pod restarted while the
service was unavailable and lost its runner identity.

## Release checklist

Do not release unless the following evidence files exist and are readable:

- `.sisyphus/evidence/task-5-cluster-plan.txt`
- `.sisyphus/evidence/task-5-secret-plan-scan.txt`
- `.sisyphus/evidence/task-9-deploy.txt`
- `.sisyphus/evidence/task-9-secret-mount.txt`
- `.sisyphus/evidence/task-10-ubuntu-workflow.txt`
- `.sisyphus/evidence/task-10-nix-workflow.txt`
- `.sisyphus/evidence/task-11-scale.txt`
- `.sisyphus/evidence/task-11-restart-cleanup.txt`

If any evidence file is missing, stop and collect it before treating the runbook
as complete.
