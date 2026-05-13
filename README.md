# git-utils

Standalone scripts and GitHub Actions for Git and GitHub chores I got tired of doing by hand.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## IDE and AI-agent config attacks are on the rise

The Mini Shai-Hulud worm spreads through malicious IDE config files hidden in pull requests. When a developer opens the repo, VS Code runs the attacker's code — no clicking, no warning.

**[ide-auto-exec-guard](docs/IDE-AUTO-EXEC-GUARD.md)** is a GitHub Actions workflow that checks pull requests for the known attack patterns and flags them before they merge. It won't catch everything — no single check can — but it raises the bar and makes these attacks harder to slip through.

---

## Scripts

A few bash utilities for repo maintenance. Plain shell, no build step, no dependencies beyond what's in the table below.

| Script | What it does |
|--------|-------------|
| `find-dirty-git.sh` | Find repos with uncommitted changes, recursively |
| `github/dependabot-alerts-by-repo.sh` | Generate a Dependabot alert report across repos |
| `github/require-signed-commits.sh` | Enable required signed commits on many repos at once |

→ [Usage and examples](docs/SCRIPTS.md)

## GitHub Actions

Drop-in workflow files for your own repositories. Copy the YAML, commit, done.

| Workflow | What it protects |
|----------|-----------------|
| `github/ide-auto-exec-guard.yml` | Malicious IDE / AI-agent config files in pull requests |

→ [Setup guide and what it checks](docs/IDE-AUTO-EXEC-GUARD.md)

---

## Requirements

| Tool | Needed for |
|------|-----------|
| `git` | `find-dirty-git.sh` |
| `gh` (logged in) + `jq` | Dependabot and signed-commits scripts |
| `GITHUB_TOKEN` (built in) | `ide-auto-exec-guard` workflow |

Script conventions and how to add new ones live in [docs/AGENTS.md](docs/AGENTS.md).

## License

MIT
