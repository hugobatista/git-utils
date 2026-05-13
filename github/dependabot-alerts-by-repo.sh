#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [owner] [options]

Scan repositories and generate a Dependabot alert report for a user or
organization.  During the scan, a running count is shown on stderr; when
the scan finishes, a full report with alert links is written to stdout.

POSITIONAL:
  owner         GitHub owner (user or org). Defaults to authenticated user.

OPTIONS:
  --state S       Alert state filter: open|fixed|dismissed|auto_dismissed
                  (default: open, env: STATE)
  --visibility V  Repo visibility filter: all|public|private
                  (default: all, env: VISIBILITY)
  --limit N       Max repos to inspect (default: 1000, env: LIMIT)
  --help, -h      Show this help message

ENVIRONMENT:
  STATE, VISIBILITY, LIMIT  Set defaults that flags override.

EXAMPLES:
  $SCRIPT_NAME                                            your repos
  $SCRIPT_NAME my-org                                     org's repos
  $SCRIPT_NAME --state all --visibility public            all alert states, public repos

REQUIRES: gh (GitHub CLI, authenticated), jq
EOF
  exit 1
}

# ── Defaults ────────────────────────────────────────────────────────
STATE="${STATE:-open}"
VISIBILITY="${VISIBILITY:-all}"
LIMIT="${LIMIT:-1000}"

# ── Parse flags ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --state) STATE="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --) shift; break ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      usage
      ;;
    *) break ;;
  esac
done

OWNER="${1:-$(gh api user --jq .login)}"

# ── Validate inputs ─────────────────────────────────────────────────
case "$STATE" in
  open|fixed|dismissed|auto_dismissed) ;;
  *)
    echo "Error: --state must be one of: open, fixed, dismissed, auto_dismissed (got: $STATE)" >&2
    exit 1
    ;;
esac

case "$VISIBILITY" in
  all|public|private) ;;
  *)
    echo "Error: --visibility must be one of: all, public, private (got: $VISIBILITY)" >&2
    exit 1
    ;;
esac

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
  echo "Error: --limit must be a positive integer (got: $LIMIT)" >&2
  exit 1
fi

if [ -z "$OWNER" ]; then
  echo "Error: Could not determine owner. Provide it as an argument or authenticate with 'gh auth login'." >&2
  exit 1
fi

# ── Prerequisites ───────────────────────────────────────────────────
for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required but not installed." >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: Not authenticated with GitHub CLI. Run: gh auth login" >&2
  exit 1
fi

# ── Setup temp directory ────────────────────────────────────────────
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

report_file="$tmpdir/report.tmp"

echo "Checking Dependabot alerts for: $OWNER" >&2
echo "  State: $STATE | Visibility: $VISIBILITY | Limit: $LIMIT" >&2
echo >&2

# ── Initialize report ───────────────────────────────────────────────
{
  echo "# Dependabot Alert Report"
  echo "# Owner: $OWNER"
  echo "# Filters: state=$STATE, visibility=$VISIBILITY"
  echo "# Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo
} > "$report_file"

# ── Build jq filter for repo list ───────────────────────────────────
repo_jq='.[] | select(.isFork == false and .owner.login == "'"$OWNER"'") | .nameWithOwner'

case "$VISIBILITY" in
  public)
    repo_jq='.[] | select(.isFork == false and .owner.login == "'"$OWNER"'" and .visibility == "PUBLIC") | .nameWithOwner'
    ;;
  private)
    repo_jq='.[] | select(.isFork == false and .owner.login == "'"$OWNER"'" and .visibility == "PRIVATE") | .nameWithOwner'
    ;;
esac

# ── Fetch repository list ───────────────────────────────────────────
repo_list="$(
  gh repo list "$OWNER" \
    --limit "$LIMIT" \
    --json nameWithOwner,isFork,visibility,owner \
    --jq "$repo_jq"
)" || {
  echo "Error: Failed to list repositories for $OWNER. Check your network connection and permissions." >&2
  exit 1
}

mapfile -t repos <<< "$repo_list"

repo_count="${#repos[@]}"

if [ "$repo_count" -eq 0 ]; then
  echo "No matching repositories found." >> "$report_file"
  cat "$report_file"
  exit 0
fi

# ── Scan each repo for Dependabot alerts ────────────────────────────
# Progress (counts) goes to stderr; alert details are accumulated in the
# report file and printed to stdout at the end.
total_alerts=0
repos_with_alerts=0

i=0
for repo in "${repos[@]}"; do
  i=$((i + 1))

  out="$tmpdir/$(echo "$repo" | tr '/' '_').json"

  if gh api \
      --paginate \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/$repo/dependabot/alerts?state=$STATE&per_page=100" \
      > "$out" 2>/dev/null; then

    count="$(jq 'length' "$out" 2>/dev/null || echo 0)"
    count="${count:-0}"

    if [ "$count" -gt 0 ]; then
      repos_with_alerts=$((repos_with_alerts + 1))
      total_alerts=$((total_alerts + count))

      # Progress on stderr — just the count
      alert_label="alert"; [ "$count" -ne 1 ] && alert_label="${alert_label}s"
      echo "  [$i/$repo_count] $repo ($count $alert_label)" >&2

      # Append this repo's alerts to the report
      {
        echo "## $repo ($count $alert_label)"
        jq -r '
          sort_by(.security_vulnerability.severity, .dependency.package.name)[] |
          "  - \(.dependency.package.name // "unknown") (\(.dependency.package.ecosystem // "unknown")) — \(.security_vulnerability.severity // "unknown") severity",
          "    URL: \(.html_url)",
          "    Summary: \((.security_advisory.summary // "no summary") | gsub("[\r\n]"; " "))",
          "    Manifest: \(.dependency.manifest_path // "n/a") (\(.dependency.scope // "n/a"))",
          ""
        ' "$out"
      } >> "$report_file"
    else
      echo "  [$i/$repo_count] $repo (0 alerts)" >&2
    fi
  else
    echo "  [$i/$repo_count] $repo - Unable to read alerts (missing access, alerts disabled, or unsupported)" >&2
  fi
done

# ── Finalize report ─────────────────────────────────────────────────
if [ "$total_alerts" -eq 0 ]; then
  echo "No alerts found across $repo_count repositories." >> "$report_file"
else
  {
    echo
    echo "---"
    echo "Scanned $repo_count repos | $total_alerts alerts across $repos_with_alerts repos"
  } >> "$report_file"
fi

# ── Output report to stdout ─────────────────────────────────────────
cat "$report_file"

# ── Summary to stderr ───────────────────────────────────────────────
echo >&2
echo "Scanned $repo_count repos; found $total_alerts alerts across $repos_with_alerts repos." >&2
