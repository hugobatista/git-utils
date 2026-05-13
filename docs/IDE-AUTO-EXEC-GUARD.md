# IDE Auto-Execution Guard

A GitHub Actions workflow that detects malicious IDE and AI-agent configuration files in pull requests. Think of it as a vaccine for the Mini Shai-Hulud class of supply chain attacks.

---

## Background

In April 2026, a self-replicating npm worm named **Mini Shai-Hulud** started compromising developer machines by committing malicious IDE config files into legitimate repos under spoofed identities. When a developer opened the repo, VS Code would silently execute the payload via a `runOn: "folderOpen"` task — no clicking, no warning. AI coding agents (Claude Code, Cursor, etc.) could be weaponized the same way through `SessionStart` hooks.

Beyond infection, the malware:

- Exfiltrated GitHub PATs, npm tokens, and cloud credentials
- Re-published trojanised packages under victim maintainers' identities
- Modified CI/CD pipelines to persist access
- Spread to every teammate who cloned the infected repo

This guard blocks these attacks at the PR level — before the config files ever reach your default branch.

---

## What it checks

The workflow triggers only on PRs that touch IDE or AI-agent config directories. For normal code changes, it stays completely silent.

| Check | What it detects | Severity |
|-------|----------------|----------|
| **Config directory changed** | `.vscode/`, `.claude/`, `.idea/`, `.cursor/`, `.codeium/`, `.continue/`, `.windsurf/`, `.github/`, `.devcontainer/` | Advisory |
| **`runOn: "folderOpen"`** | VS Code auto-task execution — the primary Mini Shai-Hulud vector | Critical |
| **AI agent hooks** | `SessionStart`, `PreToolUse`, `PostToolUse`, `SessionBreak`, or any `"hooks"` block in agent configs | Critical |
| **Exec / download patterns** | `curl`, `wget`, `eval`, `exec`, base64 decode, hex obfuscation inside config files | Critical |
| **External URLs in configs** | `https://` or `http://` URLs (separate from exec patterns — avoids false positives from legitimate schema/marketplace URLs) | Advisory |
| **Suspicious commit author** | Spoofed, empty, or unrecognised author email on config commits | Advisory |
| **PR comment** | Consolidated report with remediation guidance | — |
| **Check failure** | Blocks merge via branch protection when critical findings are present | — |

**Critical findings fail the check** (exit 1). Advisory findings post a comment but don't block.

---

## Installation

### 1. Copy the workflow file

```bash
mkdir -p .github/workflows
curl -o .github/workflows/ide-auto-exec-guard.yml \
  https://raw.githubusercontent.com/hugobatista/git-utils/main/github/ide-auto-exec-guard.yml
```

Or copy the file from this repo's [`github/ide-auto-exec-guard.yml`](../github/ide-auto-exec-guard.yml) into `.github/workflows/` in your own repo.

### 2. Commit and push

```bash
git add .github/workflows/ide-auto-exec-guard.yml
git commit -m "ci: add IDE auto-exec security check"
git push
```

The workflow activates on the next pull request that touches a watched config directory.

### 3. Enforce as a required check (strongly recommended)

1. Go to your repo → **Settings → Branches → Branch protection rules**
2. Edit (or create) the rule for your default branch
3. Enable **Require status checks to pass before merging**
4. Search for and add: `IDE auto-exec security Check`
5. Save

---

## Required permissions

The workflow uses the built-in `GITHUB_TOKEN` with these permissions (already set in the workflow file):

```yaml
permissions:
  pull-requests: write   # to post and update PR comments
  contents: read         # to read changed files
```

No external tokens or secrets needed.

---

## What happens on a finding

When the workflow detects a critical issue:

1. **Posts a detailed PR comment** explaining what was found, why it's dangerous, and what action is required before merge.
2. **Fails the status check**, blocking merge if branch protection is enabled.
3. **Updates the same comment** on subsequent pushes — no spam.

Example comment for a `runOn: "folderOpen"` finding:

> ### runOn: "folderOpen" detected
> A `.vscode/tasks.json` in this PR contains `runOn: "folderOpen"`, which causes VS Code to **automatically execute code** when any developer opens this workspace. This is the primary persistence mechanism used by the Mini Shai-Hulud supply chain worm.
>
> **Required action:** Remove or justify the `runOn: "folderOpen"` entry before merge.

---

## Covered config directories

| Directory / File | Tool |
|-----------------|------|
| `.vscode/` | VS Code (tasks, launch, extensions, settings) |
| `.claude/` | Claude Code (Anthropic) |
| `.idea/` | JetBrains IDEs |
| `.cursor/` | Cursor |
| `.codeium/` | Codeium / Windsurf |
| `.continue/` | Continue.dev |
| `.windsurf/` | Windsurf IDE |
| `.github/` | Workflows, issue templates, Copilot instructions, agent configs |
| `.devcontainer/` | VS Code Dev Containers |

---

## False positives

Some legitimate use cases may trigger advisory (non-blocking) warnings:

- **Internal monorepos** where `runOn: "folderOpen"` is intentionally used for dev server startup — add a PR comment explaining the intent and have a maintainer approve.
- **Trusted automation bots** (Dependabot, Renovate, pre-commit-ci) — explicitly allowed by the author check.
- **AI agent hook files created intentionally** — if your team uses `SessionStart` hooks on purpose, document it in a `SECURITY.md` note and approve with a maintainer review.
- **Dev container configs** with legitimate `postCreateCommand` — normal for dev environments. Use an inline comment and have a maintainer approve.
- **GitHub noreply email addresses** (`@users.noreply.github.com`) — legitimate privacy addresses, explicitly whitelisted.

---

## Testing

A full testing guide is available in [IDE-AUTO-EXEC-GUARD-TESTING.md](IDE-AUTO-EXEC-GUARD-TESTING.md) (same directory) covering:

- Quick smoke tests via `workflow_dispatch`
- Local validation (no GitHub needed)
- End-to-end tests: malicious VS Code tasks, `.claude/` hooks, `.github/` workflow injections
- Benign change tests to verify no false positives
- Fork PR behavior
- Edge cases: symlink attacks, subdirectory paths, bot authors, dangling symlinks

---

## Further reading

- [Mini Shai-Hulud is Back: npm Worm Hits over 160 Packages — Aikido Security](https://www.aikido.dev/blog/mini-shai-hulud-is-back-tanstack-compromised)
- [Mini Shai-Hulud: npm Worm Hits SAP Developer Packages — Endor Labs](https://www.endorlabs.com/learn/mini-shai-hulud-npm-worm-hits-sap-developer-packages)
- [VS Code tasks config file abused to run malicious code — DevClass](https://www.devclass.com/development/2026/01/22/vs-code-tasks-config-file-abused-to-run-malicious-code/4079547)
- [Shai-Hulud: The novel self-replicating worm — Sysdig](https://www.sysdig.com/blog/shai-hulud-the-novel-self-replicating-worm-infecting-hundreds-of-npm-packages)
- [CSA Research Note: Mini Shai-Hulud Multi-Ecosystem Supply Chain Attack](https://labs.cloudsecurityalliance.org/research/csa-research-note-mini-shai-hulud-multi-ecosystem-supply-cha/)
