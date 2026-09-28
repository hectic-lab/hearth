# gitea-kanban-tui

Keyboard-driven Kanban board for native repository Projects in custom Gitea fork.

## Configuration

Required configuration can come from flags or environment variables:

| Flag | Environment | Meaning |
| --- | --- | --- |
| `--url` | `GITEA_URL` | Gitea base URL |
| `--token-file` | `GITEA_TOKEN_FILE` | File containing API token |
| — | `GITEA_TOKEN` | API token fallback when no token file is configured |
| `--project` | `GITEA_PROJECT` | Exact native project name |
| `--project-id` | `GITEA_PROJECT_ID` | Native project ID instead of name |
| positional `OWNER` | `GITEA_OWNER` | Repository owner |
| positional `REPO` | `GITEA_REPO` | Repository name |

Native mode requires an enabled repository Projects unit, project read/write
repository permission, and a token with `read:issue`/`write:issue` scope. Issue
creation/editing follows Gitea issue permissions; deletion requires repository
admin permission in this fork. Token values are sent
only through Gitea's `Authorization` header and are never printed. Token-file
input takes precedence over environment variables. Remote URLs must use HTTPS; plain HTTP is
accepted only for loopback development.

```sh
export GITEA_URL=https://gitea.hectic-lab.com
export GITEA_TOKEN_FILE="$HOME/.config/gitea/token"
cargo run --manifest-path package/gitea-kanban-tui/Cargo.toml -- \
  --project Kanban yukkop util.nix
```

Alternatively:

```sh
nix develop .#ratatui
cargo run --manifest-path package/gitea-kanban-tui/Cargo.toml -- \
  --project-id 1 owner repo
```

## Keys

- Arrow keys or `h`/`j`/`k`/`l`: focus column/card
- `H`/`L`: move focused card left/right
- `r`: refresh project columns and issues
- `?`: toggle help
- `q`: quit

Native mode reads `/projects`, project columns, and each column's issues. Moves
use the issue's global API `id` and destination column `id`; optional sorting is
supported by the server API. Project names are exact, case-sensitive matches;
use `--project-id` when duplicate names exist. Empty native boards render
normally. `n` creates an issue assigned to the selected project, `e` edits the
focused issue title/body, and `d` deletes it after confirmation. In the editor,
`Enter` switches from title to body, `Tab` switches fields, `Ctrl-S` saves, and
`Esc` cancels. Closed projects, archived repositories, disabled Projects units,
unassigned issues, and cross-repository IDs are rejected by the server.


## Development

```sh
nix develop .#ratatui
cargo fmt --manifest-path package/gitea-kanban-tui/Cargo.toml -- --check
cargo clippy --manifest-path package/gitea-kanban-tui/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path package/gitea-kanban-tui/Cargo.toml
nix build .#gitea-kanban-tui
```
