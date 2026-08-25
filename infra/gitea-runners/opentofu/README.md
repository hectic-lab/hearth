# Gitea runner OpenTofu backend contract

This directory defines the safe backend, provider contract, and kube-hetzner
cluster stack for the Gitea runner Kubernetes cluster.

## Required backend

Production state must use the OpenTofu S3 backend in `backend.tf`:

- bucket: `gitea-runner-hectic-lab`
- key: `gitea-runners/kube-hetzner/terraform.tfstate`
- region: `fsn1`, aligned with the target Hetzner location
- encryption: `encrypt = true`
- locking: `use_lockfile = true` where the selected S3-compatible endpoint
  supports it

Before any production `tofu init`, verify the S3-compatible endpoint, credential
source, bucket versioning, encryption behavior, and lockfile support for the
chosen object-storage provider. Keep backend authentication externalized through
environment variables, AWS-compatible shared config, or the production secret
injection path from Task 3. Do not add `access_key`, `secret_key`, Hetzner
tokens, runner tokens, kubeconfig material, or decrypted SOPS data to checked-in
OpenTofu files.

## Local state safety

Production local state is forbidden. Only syntax-only validation/prototyping may
use local state, and it must use backend-disabled initialization:

```sh
tofu -chdir=infra/gitea-runners/opentofu init -backend=false
tofu -chdir=infra/gitea-runners/opentofu validate
```

Fail the run if production local state appears:

```sh
test ! -e infra/gitea-runners/opentofu/terraform.tfstate
test ! -e infra/gitea-runners/opentofu/terraform.tfstate.backup
grep -R 'backend "s3"' infra/gitea-runners/opentofu
```

The `.gitignore` in this directory blocks local state, plans, downloaded
providers/modules, and variable files from being committed. Treat any local
state file as disposable validation residue, never as production state.

## Provider and module pins

`versions.tf` pins the OpenTofu-compatible Hetzner Cloud provider to
`hetznercloud/hcloud` version `1.60.1`. kube-hetzner research for this plan
observed module version `2.19.3`, source `kube-hetzner/kube-hetzner/hcloud`, and
module minimum hcloud provider requirement `>= 1.59.0`; these values are recorded
as locals so Task 5 can wire the module without re-opening the version contract.

`providers.tf` leaves the `hcloud` provider empty so authentication comes from
the provider's external environment/config mechanisms such as `HCLOUD_TOKEN`.
Do not set token values in `.tf` or `.tfvars` files.

## Cluster shape

The default cluster is deliberately fixed-size:

- cluster name: `gitea-runners`
- Hetzner location: `fsn1`
- private network region: `eu-central`
- control plane: one `cpx22` node in pool `control-plane`
- workers: one `cpx22` node in pool `runner-workers`
- storage: Hetzner CSI enabled with expected StorageClass `hcloud-volumes`
- Longhorn: disabled
- autoscaling/KEDA: not enabled in this stack

The default baseline uses one `cpx22` worker to keep the idle bill low while
still supporting trusted internal jobs. To scale toward higher concurrency
later, keep autoscaling disabled and either raise `worker_count` or increase
`worker_server_type`, then run a fresh `tofu plan` and the Task 11 Kubernetes
pressure checks before applying.

Required inputs must come from environment or secret injection, for example
`TF_VAR_hcloud_token`, `TF_VAR_ssh_public_key`, and `TF_VAR_ssh_private_key`.
Set `TF_VAR_firewall_ssh_source` and `TF_VAR_firewall_kube_api_source` explicitly
to trusted CIDR ranges before planning; the cluster must not expose SSH or port
6443 to `0.0.0.0/0`.
If the public key is already registered in Hetzner, set
`TF_VAR_hcloud_ssh_key_id` to reuse it instead of creating a duplicate key.
Do not commit `.tfvars` files. kube-hetzner v2.19.3 writes the generated
kubeconfig to `./<cluster_name>_kubeconfig.yaml` when `create_kubeconfig` is
enabled; this path is ignored as operational secret material.

## Known state caveat

kube-hetzner may thread `hcloud_token` into Kubernetes secrets/state through its
internal `kube_system_secrets` handling. This task does not claim that risk is
solved. Task 5 must verify the generated plan and state before production apply
and prove that Hetzner tokens, S3 credentials, runner tokens, kubeconfig private
keys, and decrypted secrets are absent from committed files and unsafe state
evidence.
