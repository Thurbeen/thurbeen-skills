#!/usr/bin/env bash
# monitor.sh — Single CI poll round for a PR.
#
# Usage: monitor.sh
#
# Does NOT loop internally — Claude controls the loop so it can
# intervene on failures and make decisions.
#
# Exit codes: 0=success (parse JSON for action), 2=fatal
# Output: JSON to stdout with action field:
#   wait    — checks still running, poll again
#   fix     — one or more checks failed, Claude should diagnose
#   merged  — PR has been merged
#   stop    — hard stop condition (closed, conflicts, etc.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# --- Gather PR state ---
log "Polling PR status"

PR_JSON="$(gh pr view --json state,mergeStateStatus,mergeable 2>/dev/null)" \
  || die "Could not read PR state"
CHECKS_JSON="$(gh pr checks --json name,state,conclusion,detailsUrl 2>/dev/null)" \
  || CHECKS_JSON="[]"

PR_STATE="$(echo "$PR_JSON" | jq -r '.state')"
MERGE_STATUS="$(echo "$PR_JSON" | jq -r '.mergeStateStatus')"
MERGEABLE="$(echo "$PR_JSON" | jq -r '.mergeable')"

# --- Evaluate ---

# A) PR merged
if [[ "$PR_STATE" == "MERGED" ]]; then
  log "PR merged"
  json_output \
    "pr_state=MERGED" \
    "merge_status=${MERGE_STATUS}" \
    "checks=@json:${CHECKS_JSON}" \
    "action=merged"
  exit 0
fi

# B) PR closed (not merged)
if [[ "$PR_STATE" == "CLOSED" ]]; then
  log "PR closed without merge"
  json_output \
    "pr_state=CLOSED" \
    "merge_status=${MERGE_STATUS}" \
    "checks=@json:${CHECKS_JSON}" \
    "action=stop" \
    "stop_reason=PR was closed"
  exit 0
fi

# C) Merge conflicts
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  log "Merge conflicts detected"
  json_output \
    "pr_state=${PR_STATE}" \
    "merge_status=${MERGE_STATUS}" \
    "checks=@json:${CHECKS_JSON}" \
    "action=stop" \
    "stop_reason=Merge conflicts — rebase manually"
  exit 0
fi

# D) Check for failures
FAILED_CHECKS="$(echo "$CHECKS_JSON" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "failure")]')"
FAILED_COUNT="$(echo "$FAILED_CHECKS" | jq 'length')"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  log "${FAILED_COUNT} check(s) failed"
  json_output \
    "pr_state=${PR_STATE}" \
    "merge_status=${MERGE_STATUS}" \
    "checks=@json:${CHECKS_JSON}" \
    "failed_checks=@json:${FAILED_CHECKS}" \
    "action=fix"
  exit 0
fi

# E) All passing or still running
PENDING_CHECKS="$(echo "$CHECKS_JSON" | jq '[.[] | select(.state != "COMPLETED" and .state != "completed")]')"
PENDING_COUNT="$(echo "$PENDING_CHECKS" | jq 'length')"

if [[ "$PENDING_COUNT" -gt 0 ]]; then
  log "${PENDING_COUNT} check(s) still running"
  json_output \
    "pr_state=${PR_STATE}" \
    "merge_status=${MERGE_STATUS}" \
    "checks=@json:${CHECKS_JSON}" \
    "action=wait"
  exit 0
fi

# F) All checks passed, merge pending
log "All checks passed, merge pending"
json_output \
  "pr_state=${PR_STATE}" \
  "merge_status=${MERGE_STATUS}" \
  "checks=@json:${CHECKS_JSON}" \
  "action=wait"
