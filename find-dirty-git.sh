#!/usr/bin/env bash
# find-dirty-git.sh
# Recursively finds Git repositories with uncommitted changes under a given
# root directory.  Prints the path of each dirty repository to stdout (one
# per line) so the output can be piped into other tools.
#
# Usage:
#   ./find-dirty-git.sh                                 # scan pwd
#   ./find-dirty-git.sh /path/to/root                   # scan specific dir
#   ./find-dirty-git.sh --quiet ~/projects              # suppress progress
#
# Requirements: git

set -euo pipefail

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
Usage: $(basename "$0") [--help] [--quiet] [<root-dir>]

Recursively find Git repositories with uncommitted changes. Prints the
path of each dirty repository to stdout — one per line — so the output
can be piped into other tools.

Positional:
  <root-dir>    Directory to scan (default: current working directory)

Options:
  --quiet       Suppress progress output on stderr
  --help        Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") ~/projects
  $(basename "$0") --quiet | xargs -I{} sh -c 'cd "{}" && git diff'

Requires: git
EOF
  exit 0
}

# --help must work before any prerequisite checks
for arg do
  [ "$arg" = "--help" ] && show_usage
  break
done

# ── Prerequisites ───────────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
  echo -e "${RED}Error:${RESET} 'git' not found. Install from https://git-scm.com/" >&2
  exit 1
fi

# ── Parse arguments ─────────────────────────────────────────────────────────

QUIET=false
ROOT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help) show_usage ;;
    --quiet) QUIET=true; shift ;;
    --*)
      echo -e "${RED}Error:${RESET} Unknown option: $1" >&2
      show_usage
      ;;
    *)
      if [ -n "$ROOT_DIR" ]; then
        echo -e "${RED}Error:${RESET} Multiple root directories specified: $1" >&2
        exit 1
      fi
      ROOT_DIR="$1"
      shift
      ;;
  esac
done

# Default to current directory
ROOT_DIR="${ROOT_DIR:-$(pwd)}"

# Validate and resolve to absolute path
if [ ! -d "$ROOT_DIR" ]; then
  echo -e "${RED}Error:${RESET} Directory not found: $ROOT_DIR" >&2
  exit 1
fi
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

# ── Scan ────────────────────────────────────────────────────────────────────

[ "$QUIET" = false ] && echo -e "${CYAN}Scanning for dirty Git repos under:${RESET} ${BOLD}$ROOT_DIR${RESET}" >&2

TOTAL_REPOS=0
DIRTY_REPOS=()
CLEAN_REPOS=()
SKIPPED=0

# Process substitution avoids a subshell so arrays persist after the loop.
while IFS= read -r -d '' gitdir; do
  TOTAL_REPOS=$((TOTAL_REPOS + 1))
  repo="$(dirname "$gitdir")"

  # git -C avoids needing to cd into each repo
  output=$(git -C "$repo" status --porcelain 2>/dev/null)
  rc=$?

  if [ $rc -ne 0 ]; then
    # Repo inaccessible or broken
    SKIPPED=$((SKIPPED + 1))
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}⚠${RESET} Cannot read repo: $repo" >&2
  elif [ -n "$output" ]; then
    DIRTY_REPOS+=("$repo")
  else
    CLEAN_REPOS+=("$repo")
  fi

  # Progress line (overwritten each iteration with \r)
  if [ "$QUIET" = false ]; then
    printf "\r  ${CYAN}Scanned:${RESET} %d repos, ${YELLOW}%d dirty${RESET}, %d clean, %d skipped" \
      "$TOTAL_REPOS" "${#DIRTY_REPOS[@]}" "${#CLEAN_REPOS[@]}" "$SKIPPED" >&2
  fi
done < <(find "$ROOT_DIR" -type d -name ".git" -print0 2>/dev/null)

[ "$QUIET" = false ] && printf "\n\n" >&2

# ── Results ─────────────────────────────────────────────────────────────────

if [ "$TOTAL_REPOS" -eq 0 ]; then
  echo -e "${YELLOW}No Git repositories found under:${RESET} $ROOT_DIR" >&2
  exit 0
fi

# Print dirty repo paths to stdout (one per line — machine-parseable)
if [ "${#DIRTY_REPOS[@]}" -gt 0 ]; then
  printf '%s\n' "${DIRTY_REPOS[@]}"
fi

# Summary to stderr
echo -e "${BOLD}── Summary ──────────────────────────────────────────${RESET}" >&2
echo -e "  ${RED}Dirty:${RESET}  ${#DIRTY_REPOS[@]}" >&2
echo -e "  ${GREEN}Clean:${RESET}  ${#CLEAN_REPOS[@]}" >&2
[ "$SKIPPED" -gt 0 ] && echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED" >&2
echo -e "  Total:   $TOTAL_REPOS" >&2

# Exit 0 even when dirty repos exist — non-zero only on real errors
exit 0
