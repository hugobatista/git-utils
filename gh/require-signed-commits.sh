#!/usr/bin/env bash
# require-signed-commits.sh
# Applies "require signed commits" branch protection on the main branch
# across one or more GitHub repositories.
#
# Usage:
#   ./require-signed-commits.sh                            # interactive TUI
#   ./require-signed-commits.sh repo1 repo2                # specific repos
#   ./require-signed-commits.sh --mine --public --source    # all matching repos
#   ./require-signed-commits.sh --org my-org --private      # org's private repos
#
# Requirements: gh CLI (https://cli.github.com/) authenticated with a token
#               that has 'repo' + 'admin:repo_hook' scopes.

set -euo pipefail

# show_usage must be defined before the early --help check below
show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--help] [flags...] [repo...]

Apply "require signed commits" on the default branch across GitHub repos.

Modes:
  Interactive (no args)        Guided TUI to filter and select repos.
  Direct (repo names)          Apply to the listed repos (owner/name or bare name).
  Flag-based (flags, no name)  Apply to all repos matching the filter flags.

Flags:
  --mine          Only repos owned by the authenticated user.
  --org <name>    Only repos in the given organization.
  --public        Public repos only.
  --private       Private repos only.
  --source        Non-fork repos only (exclude forks).
  --forks         Fork repos only.

Examples:
  $(basename "$0")
  $(basename "$0") my/repo-1 owner/repo-2
  $(basename "$0") --mine --public --source
  $(basename "$0") --org my-org --private

Requires gh CLI authenticated with 'repo' and 'admin:repo_hook' scopes.
EOF
}

# --help must be handled before prerequisites so it works without a login
for arg do
  [ "$arg" = "--help" ] && { show_usage; exit 0; }
  break
done

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ── Prerequisites ────────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
  echo -e "${RED}Error:${RESET} 'gh' CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo -e "${RED}Error:${RESET} Not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

ACTOR=$(gh api /user --jq '.login' 2>/dev/null)
echo -e "${CYAN}Authenticated as:${RESET} ${BOLD}${ACTOR}${RESET}"
echo ""

# ── Parse arguments ──────────────────────────────────────────────────────────

declare -a REPO_ARGS=()
FLAG_MINE=false
FLAG_ORG=""
FLAG_PUBLIC=false
FLAG_PRIVATE=false
FLAG_SOURCE=false
FLAG_FORKS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --help) show_usage; exit 0 ;;
    --mine)   FLAG_MINE=true; shift ;;
    --org)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error:${RESET} --org requires an organization name." >&2
        exit 1
      fi
      FLAG_ORG="$2"; shift 2 ;;
    --public) FLAG_PUBLIC=true; shift ;;
    --private) FLAG_PRIVATE=true; shift ;;
    --source) FLAG_SOURCE=true; shift ;;
    --forks)  FLAG_FORKS=true; shift ;;
    -*)
      echo -e "${RED}Error:${RESET} Unknown flag: $1" >&2
      show_usage
      exit 1
      ;;
    *) REPO_ARGS+=("$1"); shift ;;
  esac
done

HAS_FLAGS=false
if [ "$FLAG_MINE" = true ] || [ -n "$FLAG_ORG" ] || [ "$FLAG_PUBLIC" = true ] || \
   [ "$FLAG_PRIVATE" = true ] || [ "$FLAG_SOURCE" = true ] || [ "$FLAG_FORKS" = true ]; then
  HAS_FLAGS=true
fi

# ── Resolve repo list ────────────────────────────────────────────────────────

declare -a REPOS=()

if [ "${#REPO_ARGS[@]}" -gt 0 ]; then
  # ── Repo names on command line ──────────────────────────────────
  OWNER_PREFIX="$ACTOR"
  [ -n "$FLAG_ORG" ] && OWNER_PREFIX="$FLAG_ORG"
  for arg in "${REPO_ARGS[@]}"; do
    if [[ "$arg" != */* ]]; then
      REPOS+=("${OWNER_PREFIX}/${arg}")
    else
      REPOS+=("$arg")
    fi
  done

elif [ "$HAS_FLAGS" = true ]; then
  # ── Flags without repo names → non-interactive API fetch ────────
  # Visibility
  case "${FLAG_PRIVATE}:${FLAG_PUBLIC}" in
    true:*)  api_type="private" ;;
    *:true)  api_type="public"  ;;
    *)       api_type="all"     ;;
  esac

  # jq filters
  jq_parts=()

  # Ownership
  if [ "$FLAG_MINE" = true ]; then
    jq_parts+=('select(.owner.login == "'"$ACTOR"'")')
  elif [ -n "$FLAG_ORG" ]; then
    jq_parts+=('select(.owner.login == "'"$FLAG_ORG"'")')
  fi

  # Fork
  if [ "$FLAG_SOURCE" = true ]; then
    jq_parts+=('select(.fork == false)')
  elif [ "$FLAG_FORKS" = true ]; then
    jq_parts+=('select(.fork == true)')
  fi

  if [ "${#jq_parts[@]}" -gt 0 ]; then
    jq_pipe=$(IFS='|'; echo "${jq_parts[*]}")
    jq_expr=".[] | ${jq_pipe} | .full_name"
  else
    jq_expr='.[] | .full_name'
  fi

  api_params="type=${api_type}&per_page=100"

  echo -e "${YELLOW}Fetching repos matching flags...${RESET}"
  mapfile -t REPOS < <(
    gh api --paginate "/user/repos?${api_params}" \
      --jq "$jq_expr" 2>/dev/null
  )

  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo -e "${RED}No repos found matching filters.${RESET}"
    exit 0
  fi
  echo -e "  ${BOLD}${#REPOS[@]}${RESET} repos matched."
  echo ""

else
  # ── Interactive TUI ────────────────────────────────────────────
  echo -e "${YELLOW}No repos specified — choose filters interactively.${RESET}"
  echo ""

  # 1. Ownership
  echo -e "1) Repository ownership:"
  echo -e "   ${BOLD}m${RESET}) My own repos"
  echo -e "   ${BOLD}o${RESET}) Organization repos"
  echo -e "   ${BOLD}b${RESET}) Both"
  read -rp "   Choice [b]: " own_choice

  ORG_NAME=""
  if [[ "${own_choice:-b}" =~ ^[oO]$ ]]; then
    orgs=()
    while IFS= read -r org; do
      orgs+=("$org")
    done < <(gh api /user/orgs --jq '.[].login' 2>/dev/null)

    echo ""
    if [ "${#orgs[@]}" -gt 0 ]; then
      echo -e "   Select an organization (or type a name):"
      for i in "${!orgs[@]}"; do
        printf "   %2d) %s\n" "$((i+1))" "${orgs[$i]}"
      done
    else
      echo -e "   No organizations found via API."
    fi
    read -rp "   Organization name or #: " org_input
    if [[ "$org_input" =~ ^[0-9]+$ ]] && [ "$org_input" -ge 1 ] && [ "$org_input" -le "${#orgs[@]}" ]; then
      ORG_NAME="${orgs[$((org_input-1))]}"
    else
      ORG_NAME="$org_input"
    fi
  fi
  echo ""

  # 2. Visibility
  echo -e "2) Repository visibility:"
  echo -e "   ${BOLD}a${RESET}) All"
  echo -e "   ${BOLD}p${RESET}) Public only"
  echo -e "   ${BOLD}r${RESET}) Private only"
  read -rp "   Choice [a]: " vis_choice
  echo ""

  # 3. Fork / source
  echo -e "3) Repository type:"
  echo -e "   ${BOLD}a${RESET}) All"
  echo -e "   ${BOLD}s${RESET}) Source (non-forks) only"
  echo -e "   ${BOLD}f${RESET}) Forks only"
  read -rp "   Choice [a]: " fork_choice
  echo ""

  # ── Build API query ────────────────────────────────────────────
  case "${vis_choice:-a}" in  p|P) api_type="public" ;;  r|R) api_type="private" ;;  *) api_type="all" ;; esac

  jq_parts=()

  # Ownership filter
  case "${own_choice:-b}" in
    m|M) jq_parts+=('select(.owner.login == "'"$ACTOR"'")') ;;
    o|O)
      if [ -n "$ORG_NAME" ]; then
        jq_parts+=('select(.owner.login == "'"$ORG_NAME"'")')
      else
        jq_parts+=('select(.owner.type == "Organization")')
      fi
      ;;
    *) ;;
  esac

  # Fork filter
  case "${fork_choice:-a}" in
    s|S) jq_parts+=('select(.fork == false)') ;;
    f|F) jq_parts+=('select(.fork == true)')  ;;
  esac

  if [ "${#jq_parts[@]}" -gt 0 ]; then
    jq_pipe=$(IFS='|'; echo "${jq_parts[*]}")
    jq_expr=".[] | ${jq_pipe} | .full_name"
  else
    jq_expr='.[] | .full_name'
  fi

  api_params="type=${api_type}&per_page=100"

  echo -e "${YELLOW}Fetching repos...${RESET}"
  mapfile -t REPOS < <(
    gh api --paginate "/user/repos?${api_params}" \
      --jq "$jq_expr" 2>/dev/null
  )

  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo -e "${RED}No repos found matching filters.${RESET}"
    exit 0
  fi

  echo ""
  echo -e "${BOLD}Found ${#REPOS[@]} repos matching filters:${RESET}"
  for repo in "${REPOS[@]}"; do
    echo "  - $repo"
  done
  echo ""
  read -rp "$(echo -e "${BOLD}Proceed to evaluate these repos? [y/N]:${RESET} ")" tui_confirm
  if [[ ! "$tui_confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# ── Check current state and prepare target list ──────────────────────────────

echo -e "${BOLD}Repos to be evaluated:${RESET}"
echo ""

declare -a TARGETS=()      # repos that will be changed
declare -a ALREADY=()      # repos already compliant
declare -a SKIPPED=()      # repos where branch doesn't exist / no admin

printf "  %-55s %s\n" "REPOSITORY" "STATUS"
printf "  %-55s %s\n" "$(printf '%.0s─' {1..55})" "$(printf '%.0s─' {1..20})"

for repo in "${REPOS[@]}"; do
  # Get the repository's default branch (main, master, etc.)
  default_branch=$(gh api "/repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "")

  if [ -z "$default_branch" ]; then
    printf "  %-55s %s\n" "$repo" "⚠️  not accessible — skipping"
    SKIPPED+=("$repo")
    continue
  fi

  # Check existing signed commit requirement on the default branch
  current=$(gh api "/repos/${repo}/branches/${default_branch}/protection/required_signatures" \
    --jq '.enabled' 2>/dev/null || echo "false")

  if [ "$current" = "true" ]; then
    printf "  %-55s %s\n" "$repo" "✅ already required"
    ALREADY+=("$repo")
  else
    printf "  %-55s %s\n" "$repo" "🔓 will be enforced"
    TARGETS+=("$repo")
  fi
done

echo ""
echo -e "  ${GREEN}${#ALREADY[@]} already compliant${RESET}  |  ${YELLOW}${#TARGETS[@]} will be updated${RESET}  |  ${RED}${#SKIPPED[@]} skipped${RESET}"
echo ""

# ── Nothing to do ────────────────────────────────────────────────────────────

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo -e "${GREEN}All repos are already compliant. Nothing to do.${RESET}"
  exit 0
fi

# ── Confirmation ─────────────────────────────────────────────────────────────

echo -e "${BOLD}The following repos will have 'require signed commits' enabled on their default branch:${RESET}"
for repo in "${TARGETS[@]}"; do
  echo "  - $repo"
done
echo ""
echo -e "${YELLOW}Note:${RESET} If a repo has no branch protection rule yet, one will be created (permissive, only signed commits enforced)."
echo ""
read -rp "$(echo -e "${BOLD}Proceed? [y/N]:${RESET} ")" confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ── Apply ─────────────────────────────────────────────────────────────────────

declare -a FAILED=()
declare -a DONE=()

for repo in "${TARGETS[@]}"; do
  printf "  %-55s " "$repo"

  default_branch=$(gh api "/repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "")
  if [ -z "$default_branch" ]; then
    echo -e "${RED}✗${RESET}"
    FAILED+=("$repo   repo not accessible")
    continue
  fi

  API_HDR=("--header" "Accept: application/vnd.github+json")

  # Retry loop: try POST first; if 404, create protection and retry
  for attempt in 1 2; do
    error_out=$(mktemp)
    result=$(gh api -X POST \
      "/repos/${repo}/branches/${default_branch}/protection/required_signatures" \
      "${API_HDR[@]}" --jq '.enabled' 2>"$error_out" || echo "error")
    error_text=$(<"$error_out")
    rm -f "$error_out"

    if [ "$result" = "true" ]; then
      echo -e "${GREEN}✓${RESET}"
      DONE+=("$repo")
      break
    fi

    # If this is the first attempt and error is 404 (no protection), create it
    if [ "$attempt" -eq 1 ]; then
      case "$error_text" in
        *"404"*|*"Branch not protected"*)
          echo -n "creating protection... "
          error_out=$(mktemp)
          if gh api -X PUT "/repos/${repo}/branches/${default_branch}/protection" \
            "${API_HDR[@]}" --input - 2>"$error_out" <<'JSON' >/dev/null; then
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
            rm -f "$error_out"
          else
            err=$(<"$error_out"); rm -f "$error_out"
            echo -e "${RED}✗${RESET}"
            FAILED+=("$repo   ${err}")
            break
          fi
          sleep 1
          echo -n "enabling signed commits... "
          continue
          ;;
      esac
    fi

    # Non-retryable error or second attempt also failed
    echo -e "${RED}✗${RESET}"
    FAILED+=("$repo   ${error_text}")
    break
  done
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}── Summary ──────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}✓ Applied:${RESET}  ${#DONE[@]} repos"
echo -e "  ${RED}✗ Failed:${RESET}   ${#FAILED[@]} repos"
echo -e "  ⏭  Skipped:  ${#SKIPPED[@]} repos (not accessible)"
echo -e "  ✅ Already:  ${#ALREADY[@]} repos (already compliant)"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo ""
  echo -e "${RED}Failed repos:${RESET}"
  for r in "${FAILED[@]}"; do
    echo "  - $r"
  done
  exit 1
fi

echo ""
echo -e "${GREEN}Done.${RESET} Verify at: https://github.com/<owner>/<repo>/settings/branches"