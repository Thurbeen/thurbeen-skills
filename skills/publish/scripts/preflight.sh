#!/usr/bin/env bash
# preflight.sh — Fetch, detect branches, rebase on default branch.
#
# Usage: preflight.sh
#
# Exit codes: 0=success, 1=rebase conflict, 2=fatal error
# Output: JSON to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Fetch
log "Fetching origin"
git fetch origin 2>&1 >&2 || die "git fetch failed"

# Detect branches
DEFAULT_BRANCH="$(detect_default_branch)"
CURRENT_BRANCH="$(git branch --show-current)"

if [[ -z "$DEFAULT_BRANCH" ]]; then
  die "Could not detect default branch"
fi

if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  json_output \
    "default_branch=${DEFAULT_BRANCH}" \
    "current_branch=${CURRENT_BRANCH}" \
    "rebase=skipped" \
    "error=on default branch"
  exit 2
fi

# Rebase
log "Rebasing on origin/${DEFAULT_BRANCH}"
if git rebase "origin/${DEFAULT_BRANCH}" 2>&1 >&2; then
  REBASE_STATUS="clean"
  CONFLICT_FILES="@json:[]"
else
  REBASE_STATUS="conflict"
  CONFLICT_FILES="@json:$(git diff --name-only --diff-filter=U 2>/dev/null | jq -R -s 'split("\n") | map(select(. != ""))')"
  git rebase --abort 2>/dev/null || true
fi

json_output \
  "default_branch=${DEFAULT_BRANCH}" \
  "current_branch=${CURRENT_BRANCH}" \
  "rebase=${REBASE_STATUS}" \
  "conflict_files=${CONFLICT_FILES}"

if [[ "$REBASE_STATUS" == "conflict" ]]; then
  exit 1
fi
