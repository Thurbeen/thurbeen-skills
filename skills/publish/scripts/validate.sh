#!/usr/bin/env bash
# validate.sh — Post-merge deployment validation (single poll).
#
# Usage: validate.sh --branch <default_branch>
#
# Does NOT loop internally — Claude controls polling so it can
# decide when to stop.
#
# Exit codes: 0=success, 1=deployment failed or not merged, 2=fatal
# Output: JSON to stdout with deployment status:
#   found=false        — no deployment runs detected
#   status=success     — deployment completed successfully
#   status=failure     — deployment failed (url included)
#   status=in_progress — deployment still running, poll again

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DEFAULT_BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

[[ -n "$DEFAULT_BRANCH" ]] || die "Missing --branch argument"

# Confirm merge
log "Confirming PR merge"
PR_STATE="$(gh pr view --json state -q '.state' 2>/dev/null)" || PR_STATE=""
if [[ "$PR_STATE" != "MERGED" ]]; then
  json_output "merged=@json:false" "deployment=@json:{\"found\":false}"
  exit 1
fi

# Check for deployment workflows
log "Checking deployment workflows on ${DEFAULT_BRANCH}"
RUNS_JSON="$(gh run list --branch "$DEFAULT_BRANCH" --limit 5 --json name,status,conclusion,url 2>/dev/null)" || RUNS_JSON="[]"
RUN_COUNT="$(echo "$RUNS_JSON" | jq 'length')"

if [[ "$RUN_COUNT" -eq 0 ]]; then
  log "No deployment runs found"
  json_output "merged=@json:true" "deployment=@json:{\"found\":false}"
  exit 0
fi

# Check for failures
FAILED_RUNS="$(echo "$RUNS_JSON" | jq '[.[] | select(.conclusion == "failure")]')"
FAILED_COUNT="$(echo "$FAILED_RUNS" | jq 'length')"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  FAILED_URL="$(echo "$FAILED_RUNS" | jq -r '.[0].url')"
  log "Deployment failed: ${FAILED_URL}"
  json_output \
    "merged=@json:true" \
    "deployment=@json:{\"found\":true,\"status\":\"failure\",\"url\":\"${FAILED_URL}\"}"
  exit 1
fi

# Report current state
LATEST_STATUS="$(echo "$RUNS_JSON" | jq -r '.[0].status // "unknown"')"
LATEST_CONCLUSION="$(echo "$RUNS_JSON" | jq -r '.[0].conclusion // "unknown"')"
LATEST_URL="$(echo "$RUNS_JSON" | jq -r '.[0].url // ""')"

DEPLOY_STATUS="$LATEST_CONCLUSION"
[[ "$LATEST_STATUS" == "in_progress" || "$LATEST_STATUS" == "queued" ]] && DEPLOY_STATUS="in_progress"

json_output \
  "merged=@json:true" \
  "deployment=@json:{\"found\":true,\"status\":\"${DEPLOY_STATUS}\",\"url\":\"${LATEST_URL}\"}"
