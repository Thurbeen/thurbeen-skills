#!/usr/bin/env bash
# collect-diff.sh — Collect the pending diff (commits ahead + uncommitted)
# against the default branch and emit its metadata as JSON. Also lists
# candidate documentation files present in the repo so the reviewer
# agent knows where docs may need updating.
#
# The full diff is written to a temp file (paths can be long); callers
# read it from `diff_file`.
#
# Usage: collect-diff.sh [file1 file2 ...]
#   With no args: diff all pending changes.
#   With args: restrict the diff to the given paths (used for re-review
#   after applying fixes).
#
# Exit codes: 0=success, 2=fatal
# Output: JSON to stdout with:
#   default_branch, current_branch, changed_files (array),
#   diff_file (path), line_count, doc_files (array)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

git rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository"

DEFAULT_BRANCH="$(detect_default_branch)"
[[ -n "$DEFAULT_BRANCH" ]] || die "Could not detect default branch"

CURRENT_BRANCH="$(git branch --show-current)"
BASE="origin/${DEFAULT_BRANCH}"
git rev-parse --verify "$BASE" >/dev/null 2>&1 || BASE="$DEFAULT_BRANCH"

DIFF_FILE="$(mktemp -t docs-update-diff.XXXXXX)"

if [[ $# -gt 0 ]]; then
  git diff "$BASE" -- "$@" > "$DIFF_FILE"
  CHANGED="$(git diff --name-only "$BASE" -- "$@")"
else
  git diff "$BASE" > "$DIFF_FILE"
  CHANGED="$(git diff --name-only "$BASE")"
fi

LINE_COUNT="$(wc -l < "$DIFF_FILE" | tr -d ' ')"

CHANGED_JSON="$(printf '%s\n' "$CHANGED" | jq -R -s 'split("\n") | map(select(. != ""))')"

# Enumerate candidate documentation files (tracked in git, typical doc paths).
DOC_FILES="$(git ls-files \
  '*.md' '*.mdx' '*.rst' '*.txt' \
  'docs/**' 'doc/**' \
  2>/dev/null | sort -u)"
DOC_FILES_JSON="$(printf '%s\n' "$DOC_FILES" | jq -R -s 'split("\n") | map(select(. != ""))')"

json_output \
  "default_branch=${DEFAULT_BRANCH}" \
  "current_branch=${CURRENT_BRANCH}" \
  "base=${BASE}" \
  "diff_file=${DIFF_FILE}" \
  "line_count=@json:${LINE_COUNT}" \
  "changed_files=@json:${CHANGED_JSON}" \
  "doc_files=@json:${DOC_FILES_JSON}"
