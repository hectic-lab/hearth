# Documentation

- [Using the `hectic` Attic Cache](./attic-cache.md)

## Gitea runner labels

Common labels for controller-managed zero-idle runners:

- `ubuntu-latest` — zero-idle alias for `gross-x86`
- `nix` — zero-idle Nix alias with 480-minute TTL
- `gross-x86` — x86 fallback chain `cx53` / `cx43` / `cx33`
- `gross-arm` — ARM fallback chain `cax41` / `cax31` / `cax21`
- `gross-x86-perf` — x86 performance chain `cx53` / `cpx62` / `cpx52`
- `gross-mixed-econ` — mixed chain `cx53` / `cax41` / `cx43`
- `gross-nix-x86` — `gross-x86` + Nix bootstrap
- `gross-nix-arm` — `gross-arm` + Nix bootstrap
- `gross-nix-x86-perf` — `gross-x86-perf` + Nix bootstrap
- `gross-nix-x86-highmem` — CCX53-only Nix runner, 480-minute TTL
- `gross-nix-mixed-econ` — `gross-mixed-econ` + Nix bootstrap

Region order for fallback: `nbg1`, then `fsn1`, then `hel1`.

The legacy Kubernetes persistent pool is disabled (`replicas: 0`) and has no
registered labels. All listed labels are handled by the zero-idle controller.

Operational details: `infra/gitea-runners/runbook.md` and
`package/gitea-runner-controller/decide.sh`.
