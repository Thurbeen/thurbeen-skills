#!/usr/bin/env bash
# create-fix-pr.sh — Clone GitOps repo, run Claude to fix issues, ship via publish skill.
#
# Usage: create-fix-pr.sh --repo <owner/repo> --state-file <path>
#
# Required env vars:
#   GH_TOKEN                - GitHub PAT with repo scope
#   CLAUDE_CODE_OAUTH_TOKEN - Claude Max OAuth token
#
# Exit codes: 0=success, 1=no fixable issues, 2=fatal
# Output: JSON to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO=""
STATE_FILE=""
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Glob,Grep,Edit,Write}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    *)            shift ;;
  esac
done

[[ -n "$REPO" ]] || die "Missing --repo"
[[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || die "Missing or invalid --state-file"

require_env GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

STATE="$(cat "$STATE_FILE")"

WORKDIR="/workspace/$(echo "$REPO" | tr '/' '-')"
rm -rf "$WORKDIR"
git clone --depth=1 "https://github.com/${REPO}.git" "$WORKDIR" 2>&1 >&2
cd "$WORKDIR" || die "Failed to cd into ${WORKDIR}"

BRANCH="fix/infra-monitor-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH" 2>&1 >&2

PROMPT="You are a Kubernetes cluster monitor for a bare-metal Talos Linux cluster managed by ArgoCD GitOps.

Here is the current cluster state:

${STATE}

Analyze the cluster state above and identify any issues that can be fixed via GitOps changes in this repo.
Focus on:
- Pods in CrashLoopBackOff, Error, or Pending state
- Firing Prometheus alerts that indicate misconfigurations
- Resource limit/request mismatches causing OOMKills
- Any configuration issues visible in events

For each fixable issue, make the minimal targeted change in the appropriate Kubernetes manifest.
Do not refactor unrelated code. Do not fix issues that require manual intervention outside GitOps.
If there are no GitOps-fixable issues, do nothing.

After making changes, stage them with git add."

log "Running Claude"
CLAUDE_ARGS=(-p "$PROMPT" --allowedTools "$ALLOWED_TOOLS")
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
fi

claude "${CLAUDE_ARGS[@]}" 2>&1 >&2 || die "Claude failed"

if git diff --cached --quiet 2>/dev/null; then
  log "No GitOps-fixable issues found"
  json_output "repo=${REPO}" "status=no_issues" "pr=@json:null"
  rm -rf "$WORKDIR"
  exit 1
fi

# Delegate commit, push, and PR creation to publish skill's ship.sh
PUBLISH_DIR="$(cd "$(dirname "$(readlink -f "$HOME/.claude/skills/publish/SKILL.md")")" && pwd)"
SHIP_OUTPUT="$(bash "$PUBLISH_DIR/ship.sh" --message "fix: infra-monitor auto-remediation $(date +%Y-%m-%d)")"
log "Ship output: ${SHIP_OUTPUT}"

PR_URL="$(echo "$SHIP_OUTPUT" | jq -r '.pr.url // empty')"
json_output "repo=${REPO}" "status=pr_created" "pr=${PR_URL}"

rm -rf "$WORKDIR"
