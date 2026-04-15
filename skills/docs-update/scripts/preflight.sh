#!/usr/bin/env bash
# preflight.sh — Verify we're on a feature branch with pending changes.
#
# Usage: preflight.sh
#
# Exit codes: 0=success, 2=fatal error (no pending changes / on default branch)
# Output: JSON to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

git rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository"

DEFAULT_BRANCH="$(detect_default_branch)"
[[ -n "$DEFAULT_BRANCH" ]] || die "Could not detect default branch"

CURRENT_BRANCH="$(git branch --show-current)"

if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  json_output \
    "default_branch=${DEFAULT_BRANCH}" \
    "current_branch=${CURRENT_BRANCH}" \
    "error=on default branch"
  exit 2
fi

COMMITS_AHEAD="$(git rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"
UNCOMMITTED="$(git status --porcelain | wc -l | tr -d ' ')"

if [[ "$COMMITS_AHEAD" -eq 0 && "$UNCOMMITTED" -eq 0 ]]; then
  json_output \
    "default_branch=${DEFAULT_BRANCH}" \
    "current_branch=${CURRENT_BRANCH}" \
    "commits_ahead=0" \
    "uncommitted=0" \
    "error=no pending changes"
  exit 2
fi

json_output \
  "default_branch=${DEFAULT_BRANCH}" \
  "current_branch=${CURRENT_BRANCH}" \
  "commits_ahead=@json:${COMMITS_AHEAD}" \
  "uncommitted=@json:${UNCOMMITTED}"
