#!/usr/bin/env bash
# pr-disable-maintainer-edit.sh
# Disables "Allow edits by maintainers" on pull requests authored by the
# authenticated user (or a specified user). This prevents maintainers of
# upstream/base repos from pushing changes to your PR branches.
#
# Usage:
#   ./pr-disable-maintainer-edit.sh                              # interactive TUI
#   ./pr-disable-maintainer-edit.sh owner/repo/#123              # specific PRs
#   ./pr-disable-maintainer-edit.sh --user octocat --dry-run     # preview only
#
# Requirements: gh CLI (https://cli.github.com/) authenticated, jq

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# ── Terminal styling ────────────────────────────────────────────────────────

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ── Usage ───────────────────────────────────────────────────────────────────

show_usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [--help] [flags...] [pr...]

Disable "Allow edits by maintainers" on pull requests. Scans PRs authored by
a user, checks the maintainer_can_modify setting, and disables it where it is
currently enabled.

Modes:
  Interactive (no args)        Guided TUI to choose author, repo, and PR state.
  Direct (PR identifiers)      Apply to one or more specific PRs.
  Flag-based (flags, no PRs)   Apply to PRs matching the given criteria.

PR identifier format:
  owner/repo/#123   or   owner/repo/123

Flags:
  --dry-run         Preview only — show what would change, make no changes.
  --user <login>    Target PRs authored by <login> (default: authenticated user).
  --repo <o/r>      Limit to a single repository (owner/repo).
  --state <s>       PR state filter: open, closed, all (default: open).

Examples:
  $SCRIPT_NAME                                           interactive mode
  $SCRIPT_NAME my-org/my-repo/#42                        disable on one PR
  $SCRIPT_NAME my-org/my-repo/#12 other-org/app/#7       disable on several
  $SCRIPT_NAME --dry-run                                 preview your PRs
  $SCRIPT_NAME --user octocat --state all                all of octocat's PRs
  $SCRIPT_NAME --repo my-org/my-repo                     PRs in one repo only

Requires: gh CLI authenticated, jq
EOF
  exit 0
}

# --help must be handled before prerequisites so it works without a login
for arg do
  [ "$arg" = "--help" ] && { show_usage; exit 0; }
  break
done

# ── Prerequisites ───────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
  echo -e "${RED}Error:${RESET} 'gh' CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error:${RESET} 'jq' not found. Install from https://jqlang.github.io/jq/" >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo -e "${RED}Error:${RESET} Not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

ACTOR=$(gh api /user --jq '.login' 2>/dev/null)
echo -e "${CYAN}Authenticated as:${RESET} ${BOLD}${ACTOR}${RESET}"
echo ""

# ── Parse arguments ─────────────────────────────────────────────────────────

declare -a PR_ARGS=()
FLAG_DRY_RUN=false
FLAG_USER=""
FLAG_REPO=""
FLAG_STATE="open"

while [ $# -gt 0 ]; do
  case "$1" in
    --help) show_usage; exit 0 ;;
    --dry-run) FLAG_DRY_RUN=true; shift ;;
    --user)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error:${RESET} --user requires a GitHub login." >&2
        exit 1
      fi
      FLAG_USER="$2"; shift 2 ;;
    --repo)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error:${RESET} --repo requires owner/repo." >&2
        exit 1
      fi
      FLAG_REPO="$2"; shift 2 ;;
    --state)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error:${RESET} --state requires a value (open, closed, all)." >&2
        exit 1
      fi
      case "$2" in
        open|closed|all) FLAG_STATE="$2"; shift 2 ;;
        *) echo -e "${RED}Error:${RESET} --state must be open, closed, or all (got: $2)." >&2; exit 1 ;;
      esac ;;
    -*)
      echo -e "${RED}Error:${RESET} Unknown flag: $1" >&2
      show_usage
      exit 1
      ;;
    *) PR_ARGS+=("$1"); shift ;;
  esac
done

HAS_FLAGS=false
[ "$FLAG_DRY_RUN" = true ] || [ -n "$FLAG_USER" ] || [ -n "$FLAG_REPO" ] || [ "$FLAG_STATE" != "open" ] && HAS_FLAGS=true

# ── Helpers ─────────────────────────────────────────────────────────────────

# Validate and normalize a PR identifier "owner/repo/123" or "owner/repo/#123"
# Returns "owner/repo num" on stdout, or empty string on invalid input.
normalize_pr() {
  local input="$1"
  if [[ "$input" =~ ^([^/]+/[^/]+)/#?([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  fi
}

# Fetch maintainer_can_modify status for one PR.
# Returns TSV: maintainer_can_modify<TAB>state<TAB>title
# Or "error" on failure.
fetch_pr_status() {
  local repo="$1" num="$2"
  gh api "/repos/${repo}/pulls/${num}" \
    --jq '[.maintainer_can_modify, .state, .title] | @tsv' \
    2>/dev/null || echo "error"
}

# Disable maintainer edits on one PR. Returns true on success.
disable_maintainer_edit() {
  local repo="$1" num="$2"
  local result
  result=$(echo '{"maintainer_can_modify": false}' | \
  gh api -X PATCH "/repos/${repo}/pulls/${num}" \
    --input - --jq '.maintainer_can_modify' 2>&1)
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  ${RED}${result}${RESET}" >&2
    return 1
  fi
  [ "$result" = "false" ]
}

# ── PR discovery ────────────────────────────────────────────────────────────

# Resolve target user
TARGET_USER="${FLAG_USER:-$ACTOR}"

# Map internal state to gh search prs --state flag.
# "all" → no flag (search returns everything).
search_state_flag=()
if [ "$FLAG_STATE" != "all" ]; then
  search_state_flag=("--state" "$FLAG_STATE")
fi

declare -a ALL_PRS=()          # "owner/repo #num" format
declare -a PR_DISPLAY=()       # parallel array: "title" for display

resolve_prs() {
  local mode="$1"  # "direct", "flags", or "interactive"
  ALL_PRS=()
  PR_DISPLAY=()

  if [ "$mode" = "direct" ]; then
    # ── Direct PR ids from positional args ─────────────────
    for arg in "${PR_ARGS[@]}"; do
      local normalized
      normalized=$(normalize_pr "$arg")
      if [ -z "$normalized" ]; then
        echo -e "  ${YELLOW}⚠${RESET} Invalid PR format, skipping: $arg" >&2
        continue
      fi
      ALL_PRS+=("$normalized")
      PR_DISPLAY+=("")
    done

  else
    # ── Search-based discovery (flag or interactive mode) ──
    local search_args=("--author" "$TARGET_USER" "--limit" "1000")
    [ "${#search_state_flag[@]}" -gt 0 ] && search_args+=("${search_state_flag[@]}")
    [ -n "$FLAG_REPO" ] && search_args+=("--repo" "$FLAG_REPO")

    echo -e "${CYAN}Searching for PRs authored by ${BOLD}${TARGET_USER}${RESET}${CYAN}...${RESET}" >&2

    local prs_json
    prs_json=$(gh search prs "${search_args[@]}" \
      --json number,repository,title,url 2>/dev/null) || {
      echo -e "  ${YELLOW}No PRs found or search failed.${RESET}" >&2
      return
    }

    # Parse search results
    while IFS=$'\t' read -r repo num title; do
      ALL_PRS+=("${repo} ${num}")
      PR_DISPLAY+=("$title")
    done < <(
      echo "$prs_json" | jq -r '.[] | [.repository.nameWithOwner, (.number | tostring), .title] | @tsv' 2>/dev/null
    )

    if [ "${#ALL_PRS[@]}" -eq 0 ]; then
      echo -e "  ${YELLOW}No PRs found matching criteria.${RESET}" >&2
    fi
  fi
}

# ── Status checking ─────────────────────────────────────────────────────────

declare -a PR_COMPLIANT=()     # PRs where it's already false
declare -a PR_TARGETS=()       # PRs where it's true and will be disabled
declare -a PR_SKIPPED=()       # PRs that couldn't be checked

check_prs() {
  PR_COMPLIANT=()
  PR_TARGETS=()
  PR_SKIPPED=()
  local i=0 total="${#ALL_PRS[@]}"

  if [ "$total" -eq 0 ]; then
    return
  fi

  echo ""
  echo -e "${BOLD}Checking PRs...${RESET}"
  echo ""

  for pr in "${ALL_PRS[@]}"; do
    i=$((i + 1))
    read -r repo num <<< "$pr"
    local display_title="${PR_DISPLAY[$((i-1))]}"

    local status
    status=$(fetch_pr_status "$repo" "$num")

    if [ "$status" = "error" ]; then
      printf "  ${CYAN}[%d/%d]${RESET} %s #%-5s  %-55s  ${RED}skipped${RESET}\n" \
        "$i" "$total" "$repo" "$num" "(not accessible)"
      PR_SKIPPED+=("${repo} ${num}")
      continue
    fi

    read -r can_modify pr_state pr_title <<< "$status"

    # Use fetched title if search didn't provide one
    [ -z "$display_title" ] && display_title="$pr_title"

    # Build the base display line with aligned columns, then append colored label
    local display_line
    printf -v display_line "  ${CYAN}[%d/%d]${RESET} %s #%-5s  %-55s  %-7s" \
      "$i" "$total" "$repo" "$num" "${display_title:0:54}" "${pr_state^^}"

    if [ "$can_modify" = "false" ]; then
      echo -e "${display_line}  ${GREEN}already disabled${RESET}"
      PR_COMPLIANT+=("${repo} ${num}")
    else
      echo -e "${display_line}  ${YELLOW}will be disabled${RESET}"
      PR_TARGETS+=("${repo} ${num}")
    fi
  done

  echo ""
  echo -e "  ${GREEN}${#PR_COMPLIANT[@]} already disabled${RESET}  |  ${YELLOW}${#PR_TARGETS[@]} will be disabled${RESET}  |  ${RED}${#PR_SKIPPED[@]} skipped${RESET}"
  echo ""
}

# ── Confirm and apply ───────────────────────────────────────────────────────

apply_changes() {
  if [ "${#PR_TARGETS[@]}" -eq 0 ]; then
    echo -e "${GREEN}Nothing to do.${RESET}"
    return
  fi

  if [ "$FLAG_DRY_RUN" = true ]; then
    echo -e "${YELLOW}--dry-run set. No changes applied.${RESET}"
    return
  fi

  echo -e "${BOLD}Disabling maintainer edits on ${#PR_TARGETS[@]} PR(s):${RESET}"
  for pr in "${PR_TARGETS[@]}"; do
    echo "  - ${pr/ / #}"
  done
  echo ""

  local j=0 total="${#PR_TARGETS[@]}"
  declare -a FAILED=()
  declare -a DONE=()

  for pr in "${PR_TARGETS[@]}"; do
    j=$((j + 1))
    read -r repo num <<< "$pr"

    printf "  [%d/%d] %s #%s ... " "$j" "$total" "$repo" "$num" >&2

    if disable_maintainer_edit "$repo" "$num"; then
      echo -e "${GREEN}✓${RESET}"
      DONE+=("${repo} ${num}")
    else
      echo -e "${RED}✗${RESET}"
      FAILED+=("${repo} ${num}")
    fi
  done

  echo ""
  echo -e "${BOLD}── Summary ──────────────────────────────────────────${RESET}"
  echo -e "  ${GREEN}✓ Disabled:${RESET}  ${#DONE[@]} PRs"
  echo -e "  ${RED}✗ Failed:${RESET}   ${#FAILED[@]} PRs"
  echo -e "  ⏭  Skipped:  ${#PR_SKIPPED[@]} PRs (not accessible)"
  echo -e "  ✅ Already:  ${#PR_COMPLIANT[@]} PRs (already disabled)"

  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed PRs:${RESET}"
    for r in "${FAILED[@]}"; do
      echo "  - ${r/ / #}"
    done
    exit 1
  fi

  echo ""
  echo -e "${GREEN}Done.${RESET}"
}

# ── Interactive mode ────────────────────────────────────────────────────────

run_interactive() {
  echo -e "${YELLOW}No PRs specified — choose filters interactively.${RESET}"
  echo ""

  # 1. Author
  echo -e "1) PR author:"
  echo -e "   ${BOLD}m${RESET}) My PRs (${ACTOR})"
  echo -e "   ${BOLD}u${RESET}) A specific user"
  read -rp "   Choice [m]: " author_choice

  if [[ "${author_choice:-m}" =~ ^[uU]$ ]]; then
    read -rp "   GitHub login: " TARGET_USER
    [ -z "$TARGET_USER" ] && TARGET_USER="$ACTOR"
  else
    TARGET_USER="$ACTOR"
  fi
  echo ""

  # 2. Repo scope
  echo -e "2) Repository scope:"
  echo -e "   ${BOLD}a${RESET}) All repos"
  echo -e "   ${BOLD}r${RESET}) A specific repo (owner/repo)"
  read -rp "   Choice [a]: " repo_choice

  if [[ "${repo_choice:-a}" =~ ^[rR]$ ]]; then
    read -rp "   Repository (owner/repo): " FLAG_REPO
  fi
  echo ""

  # 3. PR state
  echo -e "3) PR state:"
  echo -e "   ${BOLD}o${RESET}) Open only"
  echo -e "   ${BOLD}c${RESET}) Closed only"
  echo -e "   ${BOLD}a${RESET}) All states"
  read -rp "   Choice [o]: " state_choice

  case "${state_choice:-o}" in
    c|C) FLAG_STATE="closed" ;;
    a|A) FLAG_STATE="all" ;;
    *)   FLAG_STATE="open" ;;
  esac

  # Reset search_state_flag for the new choices
  search_state_flag=()
  if [ "$FLAG_STATE" != "all" ]; then
    search_state_flag=("--state" "$FLAG_STATE")
  fi

  echo ""

  # 4. Discover and check
  resolve_prs "interactive"

  if [ "${#ALL_PRS[@]}" -eq 0 ]; then
    exit 0
  fi

  check_prs

  # 5. Confirm
  if [ "${#PR_TARGETS[@]}" -eq 0 ]; then
    exit 0
  fi

  if [ "$FLAG_DRY_RUN" = true ]; then
    echo -e "${YELLOW}--dry-run set. No changes applied.${RESET}"
    exit 0
  fi

  read -rp "$(echo -e "${BOLD}Proceed to disable maintainer edits on these PRs? [y/N]:${RESET} ")" confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""

  apply_changes
}

# ── Mode resolution ─────────────────────────────────────────────────────────

if [ "${#PR_ARGS[@]}" -gt 0 ]; then
  # ── Direct mode: specific PRs provided ─────────────────────
  resolve_prs "direct"
  check_prs
  apply_changes

elif [ "$HAS_FLAGS" = true ]; then
  # ── Flag mode: non-interactive API-based selection ──────────
  resolve_prs "flags"
  check_prs
  apply_changes

else
  # ── Interactive mode: no args, no flags ─────────────────────
  run_interactive
fi
