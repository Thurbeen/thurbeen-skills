#!/usr/bin/env bash
# ship.sh — Commit, rebase, push, create/update PR with auto-merge.
#
# Usage: ship.sh [--message "commit msg"] [--type feat|fix|...] [--amend]
#
# Reads config: ship.auto_merge, publish.merge_method
# Exit codes: 0=success, 1=recoverable, 2=fatal
# Output: JSON to stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# --- Parse args ---
COMMIT_MESSAGE=""
COMMIT_TYPE=""
AMEND=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) COMMIT_MESSAGE="$2"; shift 2 ;;
    --type)    COMMIT_TYPE="$2"; shift 2 ;;
    --amend)   AMEND=true; shift ;;
    *)         shift ;;
  esac
done

# --- Config ---
AUTO_MERGE="$(config_get "ship.auto_merge" "true")"
MERGE_METHOD="$(config_get "publish.merge_method" "rebase")"

# --- Gather state ---
log "Gathering state"
DEFAULT_BRANCH="$(detect_default_branch)"
CURRENT_BRANCH="$(git branch --show-current)"
HAS_CHANGES=false

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  HAS_CHANGES=true
fi

if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  json_output "error=on default branch"
  exit 2
fi

# --- Stage & commit ---
COMMIT_ACTION="none"
if [[ "$HAS_CHANGES" == "true" ]]; then
  # Stage all tracked changes + new files (excluding sensitive files)
  git add -A 2>&1 >&2
  git reset HEAD -- '*.env' '*credentials*' '*.key' '*.pem' 2>/dev/null || true

  if git diff --cached --quiet 2>/dev/null; then
    log "Nothing to commit after staging"
  else
    if [[ "$AMEND" == "true" ]]; then
      git commit --amend --no-edit 2>&1 >&2
      COMMIT_ACTION="amend"
      COMMIT_MESSAGE="$(git log -1 --format=%s)"
    else
      if [[ -z "$COMMIT_MESSAGE" ]]; then
        # Auto-generate conventional commit message from diff
        COMMIT_MESSAGE="${COMMIT_TYPE:-feat}: update"
      fi
      git commit -m "$COMMIT_MESSAGE" 2>&1 >&2
      COMMIT_ACTION="new"
    fi
    log "Committed: ${COMMIT_ACTION} — ${COMMIT_MESSAGE}"
  fi
fi

# --- Rebase ---
log "Rebasing on origin/${DEFAULT_BRANCH}"
git fetch origin 2>&1 >&2
REBASE_STATUS="clean"
if ! git rebase "origin/${DEFAULT_BRANCH}" 2>&1 >&2; then
  REBASE_STATUS="conflict"
  git rebase --abort 2>/dev/null || true
  COMMIT_JSON="$(jq -n --arg action "$COMMIT_ACTION" --arg message "$COMMIT_MESSAGE" \
    '{action: $action, message: $message}')"
  json_output \
    "commit=@json:${COMMIT_JSON}" \
    "rebase=${REBASE_STATUS}" \
    "push=skipped" \
    "pr=@json:{}" \
    "auto_merge=skipped"
  exit 1
fi

# --- Push ---
log "Pushing"
git push --force-with-lease origin HEAD 2>&1 >&2 || die "Push failed"

# --- PR ---
PR_JSON="$(gh pr view --json url,title,state 2>/dev/null)" || PR_JSON=""
PR_CREATED=false

if [[ -z "$PR_JSON" || "$PR_JSON" == "null" ]]; then
  log "Creating PR"
  PR_TITLE="${COMMIT_MESSAGE:-${CURRENT_BRANCH}}"
  # Truncate to 70 chars
  PR_TITLE="${PR_TITLE:0:70}"

  PR_URL="$(gh pr create \
    --title "$PR_TITLE" \
    --body "## Summary

Automated PR from publish skill.

## Test plan

- CI checks pass" 2>&1)" || die "PR creation failed: ${PR_URL}"

  PR_JSON="$(gh pr view --json url,title,state 2>/dev/null)" || PR_JSON="{}"
  PR_CREATED=true
  log "PR created: ${PR_URL}"
else
  log "PR exists: $(echo "$PR_JSON" | jq -r '.url')"
fi

# --- Auto-merge ---
AUTO_MERGE_STATUS="skipped"
if [[ "$AUTO_MERGE" == "true" ]]; then
  if gh pr merge --auto --"${MERGE_METHOD}" 2>&1 >&2; then
    AUTO_MERGE_STATUS="enabled"
    log "Auto-merge enabled (${MERGE_METHOD})"
  else
    AUTO_MERGE_STATUS="not_configured"
    warn "Auto-merge could not be enabled"
  fi
fi

# --- Output ---
PR_URL="$(echo "$PR_JSON" | jq -r '.url // empty')"
PR_STATE="$(echo "$PR_JSON" | jq -r '.state // empty')"

COMMIT_JSON="$(jq -n --arg action "$COMMIT_ACTION" --arg message "$COMMIT_MESSAGE" \
  '{action: $action, message: $message}')"
PR_OBJ="$(jq -n --arg url "$PR_URL" --arg state "$PR_STATE" --argjson created "$PR_CREATED" \
  '{url: $url, state: $state, created: $created}')"

json_output \
  "commit=@json:${COMMIT_JSON}" \
  "rebase=${REBASE_STATUS}" \
  "push=ok" \
  "pr=@json:${PR_OBJ}" \
  "auto_merge=${AUTO_MERGE_STATUS}"
