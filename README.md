# git-utils

Standalone shell scripts for Git and GitHub tasks I keep having to do manually.

These scripts exist because I got tired of:
- Scanning directories for dirty repos by hand
- Clicking through Dependabot alerts repo-by-repo
- Toggling "require signed commits" across dozens of repos via the UI

They're plain bash — no dependencies beyond what they advertise. Run them, pipe them, throw them in a cron job.

## Quick reference

| Script | What it does | Jump to |
|--------|-------------|---------|
| `find-dirty-git.sh` | Recursively find repos with uncommitted changes | [→](#script-find-dirty-git) |
| `gh/dependabot-alerts-by-repo.sh` | Generate a Dependabot alert report across repos | [→](#script-dependabot-alerts) |
| `gh/require-signed-commits.sh` | Enable required signed commits on default branches | [→](#script-require-signed-commits) |

## Scripts

<a name="script-find-dirty-git"></a>
### `find-dirty-git.sh`

Recursively finds Git repositories with uncommitted changes under a directory. Useful when you have a workspace with dozens of cloned repos and need to know which ones need attention before a commit/push sweep.

```bash
# Default: scan current directory with live progress
./find-dirty-git.sh

# Scan a specific directory
./find-dirty-git.sh ~/projects

# Quiet mode: suppress progress, get clean paths for piping
./find-dirty-git.sh --quiet ~/projects | xargs -I{} sh -c 'cd "{}" && git status'

# Full pipeline: find dirty repos, show their diffs
./find-dirty-git.sh --quiet | while read -r repo; do
  echo "=== $repo ==="
  git -C "$repo" diff --stat
done
```

The quiet mode is the most useful — it prints one path per line to stdout so you can pipe into `xargs`, `while read`, or whatever. Progress and the summary block go to stderr, so they don't interfere.

It handles:
- Normal repos with staged/unstaged changes
- Empty repos (no commits yet — git status --porcelain returns nothing for these)
- Inaccessible or broken `.git` directories (counted as skipped, not a crash)
- No repos found at all (prints a note, exits 0)

<a name="script-dependabot-alerts"></a>
### `gh/dependabot-alerts-by-repo.sh`

Scans all repositories owned by a user or organization and generates a Dependabot alert report. It doesn't just give you a count — it produces a structured report with alert URLs, severities, package names, and manifest paths, organized by repo.

```bash
# Scan your own repos (default: open alerts)
./gh/dependabot-alerts-by-repo.sh

# Scan an organization's repos
./gh/dependabot-alerts-by-repo.sh my-org

# Include all alert states (open, fixed, dismissed), public repos only
./gh/dependabot-alerts-by-repo.sh --state all --visibility public

# Limit scan depth (stops after 50 repos)
./gh/dependabot-alerts-by-repo.sh --limit 50
```

Output looks like:

```
# Dependabot Alert Report
# Owner: hugobatista
# Filters: state=open, visibility=all
# Generated: 2026-05-13T10:30:00Z

## hugobatista/kuma-scout (2 alerts)
  - urllib3 (pip) — high severity
    URL: https://github.com/hugobatista/kuma-scout/security/dependabot/42
    Summary: urllib3's proxy-authorization request header isn't stripped during cross-origin redirects
    Manifest: requirements.txt (runtime)

  - django (pip) — critical severity
    URL: https://github.com/hugobatista/kuma-scout/security/dependabot/43
    Summary: Potential account takeover via password reset flow
    Manifest: requirements.txt (runtime)

---

Scanned 47 repos | 12 alerts across 5 repos
```

The report goes to stdout — redirect it to a file if you want to save it:

```bash
./gh/dependabot-alerts-by-repo.sh --state all > report-$(date +%F).md
```

Environment variables (`STATE`, `VISIBILITY`, `LIMIT`) serve as defaults that command-line flags override. This is handy if you run it in a cron job where the filters don't change much.

Requires `gh` (authenticated) and `jq`.

<a name="script-require-signed-commits"></a>
### `gh/require-signed-commits.sh`

Enables "require signed commits" branch protection on the default branch across repositories. This is something you want enabled for anything production-facing, but setting it up repo-by-repo through the GitHub UI gets old fast.

Three modes:

**Direct mode** — target specific repos by name:

```bash
./gh/require-signed-commits.sh hugobatista/kuma-scout hugobatista/some-other-repo
```

If you omit the owner prefix, it defaults to the authenticated user (or the org set via `--org`):

```bash
./gh/require-signed-commits.sh --org my-org repo-a repo-b
```

**Flag mode** — select repos by criteria, non-interactive:

```bash
# All your own public non-fork repos
./gh/require-signed-commits.sh --mine --public --source

# All private repos in an organization
./gh/require-signed-commits.sh --org my-org --private

# All your repos, no filters
./gh/require-signed-commits.sh --mine
```

**Interactive mode** — no args, no flags. It walks you through filter choices (ownership, visibility, fork status), shows you the matching repos, and asks for confirmation before making any changes:

```bash
./gh/require-signed-commits.sh
```

In all modes, the script:
1. Fetches the repo list based on the filters
2. Checks each repo's current signed-commit status (what's already enabled, what needs changing, what's inaccessible or archived)
3. Shows you the breakdown before applying
4. Asks for confirmation
5. Creates a permissive branch protection rule if none exists, then enables signed commits

Archived repos and repos without admin access are skipped gracefully — counted in the summary, not a fatal error.

Requires `gh` authenticated with `repo` and `admin:repo_hook` scopes.

## Prerequisites

| Script | Requires |
|---|---|
| `find-dirty-git.sh` | `git` |
| `gh/dependabot-alerts-by-repo.sh` | `gh` (authenticated), `jq` |
| `gh/require-signed-commits.sh` | `gh` (authenticated, `repo` + `admin:repo_hook` scopes) |

## Conventions

All scripts follow the same patterns (documented in [AGENTS.md](AGENTS.md) for reference):

- `#!/usr/bin/env bash` with `set -euo pipefail`
- `--help` works even when prerequisites aren't met
- Progress on stderr, data on stdout (piping-friendly)
- Color output when connected to a terminal (ANSI codes at the top of each script)
- Non-fatal errors are counted and reported, not allowed to crash the whole run

## Why not use a proper tool?

For some of these, there are higher-level tools. `gh` itself has `gh search` and `gh alert` subcommands. But I found myself building the same pipeline repeatedly (list repos → filter → check state → report/apply), and one-offs never covered edge cases. These scripts encapsulate the patterns I actually use, with error handling and output formatting baked in.

If you only need to do something once, use `gh` directly. If you do it weekly, use these.

## License

MIT
