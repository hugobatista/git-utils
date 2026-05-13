# Script documentation

Detailed usage, examples, and edge cases for the bash scripts in this repo.

---

<a name="script-find-dirty-git"></a>
## `find-dirty-git.sh`

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

### Edge cases handled

- Normal repos with staged/unstaged changes
- Empty repos (no commits yet — `git status --porcelain` returns nothing for these)
- Inaccessible or broken `.git` directories (counted as skipped, not a crash)
- No repos found at all (prints a note, exits 0)

---

<a name="script-dependabot-alerts"></a>
## `github/dependabot-alerts-by-repo.sh`

Scans all repositories owned by a user or organization and generates a Dependabot alert report. It doesn't just give you a count — it produces a structured report with alert URLs, severities, package names, and manifest paths, organized by repo.

```bash
# Scan your own repos (default: open alerts)
./github/dependabot-alerts-by-repo.sh

# Scan an organization's repos
./github/dependabot-alerts-by-repo.sh my-org

# Include all alert states (open, fixed, dismissed), public repos only
./github/dependabot-alerts-by-repo.sh --state all --visibility public

# Limit scan depth (stops after 50 repos)
./github/dependabot-alerts-by-repo.sh --limit 50
```

### Example output

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

The report goes to stdout — redirect to a file if you want to save it:

```bash
./github/dependabot-alerts-by-repo.sh --state all > report-$(date +%F).md
```

### Environment variables

`STATE`, `VISIBILITY`, and `LIMIT` serve as defaults that command-line flags override. Handy if you run this in a cron job where the filters don't change much.

### Requirements

- `gh` (GitHub CLI, authenticated)
- `jq`

---

<a name="script-require-signed-commits"></a>
## `github/require-signed-commits.sh`

Enables "require signed commits" branch protection on the default branch across repositories. Something you want enabled for anything production-facing, but setting it up repo-by-repo through the GitHub UI gets old fast.

### Three modes

**Direct mode** — target specific repos by name:

```bash
./github/require-signed-commits.sh hugobatista/kuma-scout hugobatista/some-other-repo
```

If you omit the owner prefix, it defaults to the authenticated user (or the org set via `--org`):

```bash
./github/require-signed-commits.sh --org my-org repo-a repo-b
```

**Flag mode** — select repos by criteria, non-interactive:

```bash
# All your own public non-fork repos
./github/require-signed-commits.sh --mine --public --source

# All private repos in an organization
./github/require-signed-commits.sh --org my-org --private

# All your repos, no filters
./github/require-signed-commits.sh --mine
```

**Interactive mode** — no args, no flags. It walks you through filter choices (ownership, visibility, fork status), shows the matching repos, and asks for confirmation before making any changes:

```bash
./github/require-signed-commits.sh
```

### What it does

1. Fetches the repo list based on the filters
2. Checks each repo's current signed-commit status (what's already enabled, what needs changing, what's inaccessible or archived)
3. Shows you the breakdown before applying
4. Asks for confirmation
5. Creates a permissive branch protection rule if none exists, then enables signed commits

Archived repos and repos without admin access are skipped gracefully — counted in the summary, not a fatal error.

### See also

Safeguarding the merge gate is as important as the branch side. The [IDE Auto-Execution Guard](IDE-AUTO-EXEC-GUARD.md) is a GitHub Actions workflow that blocks malicious IDE and AI-agent config files from reaching your default branch through pull requests. Pair it with this script for defence in depth.

### Requirements

- `gh` (GitHub CLI, authenticated with `repo` and `admin:repo_hook` scopes)
