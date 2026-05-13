# git-utils

Collection of standalone shell scripts for Git/GitHub operational tasks.

## Files

- `find-dirty-git.sh` — Recursively finds Git repos with uncommitted changes under a given root (defaults to `pwd`). Features:
  - **Default mode**: `./find-dirty-git.sh [dir]` — scans given dir (or pwd) with colored progress and summary.
  - **Quiet mode**: `./find-dirty-git.sh --quiet [dir]` — suppress progress; dirty paths on stdout for piping.
  - `--help` works without git.
- `gh/dependabot-alerts-by-repo.sh` — Scans Dependabot alerts across repos owned by a user/org. Env: `STATE`, `VISIBILITY`, `LIMIT`. Requires `gh` + `jq`.
- `gh/require-signed-commits.sh` — Enables required signed commits on default branch for one or more repos. Requires `gh` with `repo` + `admin:repo_hook` scopes. Three modes:
  - **CLI mode**: `./require-signed-commits.sh repo1 repo2` — applies to specified repos.
  - **Interactive mode**: `./require-signed-commits.sh` (no args) — guided TUI to filter repos by visibility, fork type, and access level; shows matching repos before applying.
  - **Flag mode**: `./require-signed-commits.sh --mine --public --source` — non-interactive API-based selection.
  - Flags: `--mine`, `--org <name>`, `--public`, `--private`, `--source`, `--forks`
  - `--help` works without gh auth.

## Conventions

All scripts in this repository follow these conventions:

### Script structure
- **Shebang**: `#!/usr/bin/env bash` (portable across systems).
- **Strict mode**: `set -euo pipefail` immediately after the shebang.
- **Header block**: A comment block at the top describing purpose, usage, requirements, and modes.
- **`--help`**: Always supported. Must be checked **before** prerequisite validation so `--help` works even when dependencies are missing. Check the first argument only as a fast path.

### Terminal output
- **ANSI colors** defined at the top: `BOLD`, `RED`, `GREEN`, `YELLOW`, `CYAN`, `RESET`.
- **Progress on stderr**, data on stdout. This lets stdout be piped (e.g. `script.sh | xargs ...`) while the user still sees progress.
- **Summary block** at the end showing counts (success/skip/fail).
- **Inline progress** uses `printf '\r...'` for live-updating counts on a single line.

### Argument parsing
- `while [ $# -gt 0 ]; do case "$1" in` loop — standard and robust.
- Known flags matched explicitly (`--quiet`, `--mine`, etc.).
- Unknown flags produce an error, show usage, and `exit 1`.
- Remainder (non-flag positional args) consumed in the `*)` branch.
- Single positional arg expected; multiple produce an error.

### Prerequisite checks
- Each required CLI checked early with a clear error directing the user to install it.
- `gh` scripts additionally verify `gh auth status` and resolve `ACTOR` before proceeding.

### Input validation
- Validate directories exist, limit values are positive integers, enums match known values, etc.
- Produce a clear error message and `exit 1` on invalid input.

### Safety and cleanup
- **`trap`** used when scripts create temp directories: `trap 'rm -rf "$tmpdir"' EXIT`.
- **Process substitution** (`< <(command)`) preferred over pipes into `while read` to avoid subshell scoping of variables.
- **`git -C "$repo"`** used instead of `cd "$repo"` to avoid directory state management.

### Error handling
- `set -e` handles most failures; explicit `||` or `$?` checks used where recovery is needed.
- Non-fatal errors (e.g. inaccessible repos during a scan) are counted and reported in the summary, not allowed to abort the whole script.

### Exit codes
- `0` — success (even if no work was needed, or dirty repos found — "success" means the script ran correctly).
- `1` — error (prerequisite missing, invalid input, operation failure).

### No build/test/lint tooling
Plain bash, run directly.
