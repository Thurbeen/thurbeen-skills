#!/usr/bin/env bash
# find-failed-prs.sh — Find Renovate PRs with failing CI.
#
# Usage: find-failed-prs.sh --repo <owner/repo>
#
# Exit codes: 0=success, 2=fatal
# Output: JSON array of PR numbers to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *)      shift ;;
  esac
done

[[ -n "$REPO" ]] || die "Missing --repo argument"

log "Finding failed Renovate PRs in ${REPO}"

FAILED_PRS="$(gh pr list \
  --repo "$REPO" \
  --author "app/renovate" \
  --state open \
  --json number,title,statusCheckRollup \
  --jq '
    [.[] | select(.statusCheckRollup[]? | .status == "COMPLETED" and .conclusion == "FAILURE")]
    | unique_by(.number)
    | [.[] | {number, title}]
  ' 2>/dev/null)" || FAILED_PRS="[]"

COUNT="$(echo "$FAILED_PRS" | jq 'length')"
log "Found ${COUNT} failed Renovate PR(s)"

echo "$FAILED_PRS"
