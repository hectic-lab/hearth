# Documentation

- [Using the `hectic` Attic Cache](./attic-cache.md)

## Gitea runner labels

Common labels for zero-idle runners:

- `ubuntu-latest` — persistent Ubuntu 24.04 `cx23` worker
- `nix` — persistent Nix-capable Ubuntu `cx23` worker
- `gross-x86` — x86 fallback chain `cx53` / `cx43` / `cx33`
- `gross-arm` — ARM fallback chain `cax41` / `cax31` / `cax21`
- `gross-x86-perf` — x86 performance chain `cx53` / `cpx62` / `cpx52`
- `gross-mixed-econ` — mixed chain `cx53` / `cax41` / `cx43`
- `gross-nix-x86` — `gross-x86` + Nix bootstrap
- `gross-nix-arm` — `gross-arm` + Nix bootstrap
- `gross-nix-x86-perf` — `gross-x86-perf` + Nix bootstrap
- `gross-nix-mixed-econ` — `gross-mixed-econ` + Nix bootstrap

Region order for fallback: `nbg1`, then `fsn1`, then `hel1`.

`nix` and `ubuntu-latest` are persistent workers; only `gross-*` labels use
zero-idle ephemeral VMs.

Operational details: `infra/gitea-runners/runbook.md` and
`package/gitea-runner-controller/decide.sh`.
