# git-utils

Collection of standalone shell scripts and GitHub Actions workflows for Git/GitHub operational tasks.

## Files

- `find-dirty-git.sh` — Recursively finds Git repos with uncommitted changes under a given root (defaults to `pwd`). Features:
  - **Default mode**: `./find-dirty-git.sh [dir]` — scans given dir (or pwd) with colored progress and summary.
  - **Quiet mode**: `./find-dirty-git.sh --quiet [dir]` — suppress progress; dirty paths on stdout for piping.
  - `--help` works without git.
- `github/dependabot-alerts-by-repo.sh` — Scans Dependabot alerts across repos owned by a user/org. Env: `STATE`, `VISIBILITY`, `LIMIT`. Requires `gh` + `jq`.
- `github/require-signed-commits.sh` — Enables required signed commits on default branch for one or more repos. Requires `gh` with `repo` + `admin:repo_hook` scopes. Three modes:
  - **CLI mode**: `./require-signed-commits.sh repo1 repo2` — applies to specified repos.
  - **Interactive mode**: `./require-signed-commits.sh` (no args) — guided TUI to filter repos by visibility, fork type, and access level; shows matching repos before applying.
  - **Flag mode**: `./require-signed-commits.sh --mine --public --source` — non-interactive API-based selection.
  - Flags: `--mine`, `--org <name>`, `--public`, `--private`, `--source`, `--forks`
  - `--help` works without gh auth.
- `github/pr-disable-maintainer-edit.sh` — Disables "Allow edits by maintainers" on pull requests authored by a user (defaults to the authenticated user). Requires `gh` + `jq`. Three modes:
  - **Direct mode**: `./pr-disable-maintainer-edit.sh owner/repo/#123` — targets specific PRs.
  - **Interactive mode**: `./pr-disable-maintainer-edit.sh` (no args) — guided TUI to choose author, repo scope, and PR state; shows matching PRs with current status before applying.
  - **Flag mode**: `./pr-disable-maintainer-edit.sh --user octocat --state all` — non-interactive API-based selection.
  - Flags: `--dry-run`, `--user <login>`, `--repo <owner/repo>`, `--state <open|closed|all>`
  - `--help` works without gh auth.
- `github/ide-auto-exec-guard.yml` — GitHub Actions workflow that detects malicious IDE/AI-agent config file changes in PRs. Key details:
  - **Trigger**: `pull_request` on paths matching guarded config directories (`.vscode/`, `.claude/`, `.idea/`, `.cursor/`, `.codeium/`, `.continue/`, `.windsurf/`, `.github/`, `.devcontainer/`) or `workflow_dispatch`.
  - **Critical findings** (exit 1): `runOn: "folderOpen"`, AI agent hooks (`SessionStart`, `PreToolUse`, `PostToolUse`, `SessionBreak`, `"hooks"`), exec/download patterns (`curl`, `wget`, `eval`, `exec`, base64 decode, etc.), symlink-outside-repo, dangling symlinks.
  - **Advisory findings** (comment only, no failure): IDE/agent config directory changes, external URLs, suspicious commit authors.
  - **PR comment**: Upserts a consolidated markdown report via `actions/github-script@v9` — updates on push, never duplicates.
  - **Fork PRs**: Runs checks but skips comment posting (GITHUB_TOKEN is read-only from forks).
  - No external dependencies beyond the `GITHUB_TOKEN` with `pull-requests: write` and `contents: read` permissions.

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

### Workflow conventions
- **Trigger paths**: Narrowly scoped `on.pull_request.paths` to avoid unnecessary runs. Always include both bare directory name (for symlink-replacement detection) and `/**` glob (for content changes).
- **`workflow_dispatch`**: Always supported with a `base_ref` input for manual testing against arbitrary branches.
- **Output discipline**: Progress/debug on stderr (via `echo`), structured data on stdout. Use `GITHUB_OUTPUT` for cross-step values, `GITHUB_ENV` for shared environment.
- **Base64 encoding**: Multi-line findings passed between steps are base64-encoded (`base64 -w0` in shell, `Buffer.from(..., 'base64')` in JS) to avoid injection issues.
- **PR comments**: Use `actions/github-script@v9` with upsert logic — find existing comment by marker text, update if found, create if not.
- **Failure semantics**: Critical findings → exit 1 (blocks merge via branch protection). Advisory findings → comment only, exit 0.
- **Fork safety**: Check `github.event.pull_request.head.repo.fork` before posting comments — skip comment step for fork PRs.
- **No external dependencies**: Workflows should rely only on the `GITHUB_TOKEN` and standard GitHub Actions. No custom actions, no Docker, no secret injection.

### No build/test/lint tooling
Plain bash and YAML workflows, run directly.

## Adding new content

When adding a new script or workflow to this repository, you **must** update these documentation files:

1. **`AGENTS.md`** — Add an entry under the `## Files` section describing the item, its modes, requirements, and key flags/configuration.
2. **`README.md`** — Add a row to the appropriate table (`## Scripts` or `## GitHub Actions`).
3. **Detailed docs** — Add a full section with usage examples, output samples, edge cases, and requirements in the appropriate file:
   - Bash scripts → [`SCRIPTS.md`](SCRIPTS.md)
   - GitHub Actions workflows → a dedicated doc (e.g. [`IDE-AUTO-EXEC-GUARD.md`](IDE-AUTO-EXEC-GUARD.md)) or the relevant existing doc.

Each detailed section should start with an `<a name="...">` anchor tag for deep linking.
