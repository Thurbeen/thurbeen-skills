#!/usr/bin/env bash
# fix-pr.sh — Checkout a PR branch, run Claude to fix CI, ship via publish skill.
#
# Usage: fix-pr.sh --repo <owner/repo> --pr <number> --workdir <path>
#
# Required env vars:
#   GH_TOKEN                - GitHub PAT with repo scope
#   CLAUDE_CODE_OAUTH_TOKEN - Claude Max OAuth token
#
# Exit codes: 0=success (may have no changes), 1=Claude failed, 2=fatal
# Output: JSON to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO=""
PR_NUMBER=""
WORKDIR=""
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Glob,Grep,Edit,Write}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --pr)      PR_NUMBER="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    *)         shift ;;
  esac
done

[[ -n "$REPO" ]] || die "Missing --repo"
[[ -n "$PR_NUMBER" ]] || die "Missing --pr"
[[ -n "$WORKDIR" ]] || die "Missing --workdir"

require_env GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

log "Fixing PR #${PR_NUMBER} in ${REPO}"

cd "$WORKDIR" || die "Failed to cd into ${WORKDIR}"

# Clean state and checkout PR
git reset --hard 2>&1 >&2
git clean -fd 2>&1 >&2
git checkout main 2>&1 >&2 && git pull --quiet 2>&1 >&2
gh pr checkout "$PR_NUMBER" 2>&1 >&2 || die "Failed to checkout PR #${PR_NUMBER}"

PROMPT="This is a Renovate dependency update PR (${REPO}#${PR_NUMBER}) with failing CI checks. \
Diagnose why CI is failing and fix the issue. \
The failure is likely caused by the dependency update requiring code changes. \
Look at CI logs, test failures, and type errors. \
Make minimal targeted fixes - do not refactor unrelated code. \
After fixing, stage your changes with git add."

log "Running Claude"
CLAUDE_ARGS=(-p "$PROMPT" --allowedTools "$ALLOWED_TOOLS")
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
fi

if ! claude "${CLAUDE_ARGS[@]}" 2>&1 >&2; then
  warn "Claude failed on PR #${PR_NUMBER}"
  json_output "pr=${PR_NUMBER}" "repo=${REPO}" "status=claude_failed" "changes=@json:false"
  exit 1
fi

if git diff --cached --quiet 2>/dev/null; then
  log "No changes needed for PR #${PR_NUMBER}"
  json_output "pr=${PR_NUMBER}" "repo=${REPO}" "status=no_changes" "changes=@json:false"
  exit 0
fi

# Delegate commit and push to publish skill's ship.sh
PUBLISH_DIR="$(cd "$(dirname "$(readlink -f "$HOME/.claude/skills/publish/SKILL.md")")" && pwd)"
SHIP_OUTPUT="$(bash "$PUBLISH_DIR/ship.sh" --message "fix: resolve CI failures for dependency update")"
log "Ship output: ${SHIP_OUTPUT}"

log "Pushed fix for PR #${PR_NUMBER}"
json_output "pr=${PR_NUMBER}" "repo=${REPO}" "status=fixed" "changes=@json:true"
