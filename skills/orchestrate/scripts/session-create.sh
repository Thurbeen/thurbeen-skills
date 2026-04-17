#!/usr/bin/env bash
# session-create.sh — spawn a thurbox worker session via MCP if possible,
# CLI as fallback, and always reconcile the authoritative UUID via
# `thurbox-cli session list`.
#
# Usage:
#   session-create.sh \
#     --name NAME \
#     --repo-path PATH \
#     --worktree-branch BRANCH \
#     --base-branch BRANCH \
#     [--role ROLE] \
#     [--skills "s1,s2,s3"]
#
# Prints the authoritative session UUID on stdout. Diagnostics go to stderr.
# Exit codes: 0 = success, 2 = fatal (no session created).
#
# Background:
#   - MCP `create_session` and `thurbox-cli session create` can return
#     different UUIDs for the same session (bug admin-7xp). The canonical
#     UUID is the one `thurbox-cli session list` reports, so we always
#     reconcile via list after spawning.
#   - Session names must be hyphenated with no whitespace (bug admin-jmb);
#     we hard-fail here rather than pass a bad name to the API.

set -euo pipefail
source "$(dirname "$0")/common.sh"

NAME=""
REPO_PATH=""
WORKTREE_BRANCH=""
BASE_BRANCH=""
ROLE=""
SKILLS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)             NAME="$2";            shift 2 ;;
    --repo-path)        REPO_PATH="$2";       shift 2 ;;
    --worktree-branch)  WORKTREE_BRANCH="$2"; shift 2 ;;
    --base-branch)      BASE_BRANCH="$2";     shift 2 ;;
    --role)             ROLE="$2";            shift 2 ;;
    --skills)           SKILLS="$2";          shift 2 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$NAME"            ]] || die "--name required"
[[ -n "$REPO_PATH"       ]] || die "--repo-path required"
[[ -n "$WORKTREE_BRANCH" ]] || die "--worktree-branch required"
[[ -n "$BASE_BRANCH"     ]] || die "--base-branch required"

if [[ "$NAME" =~ [[:space:]] ]]; then
  die "session name must not contain whitespace (admin-jmb): $NAME"
fi

# Build --skill flags from comma-separated list.
SKILL_FLAGS=()
if [[ -n "$SKILLS" ]]; then
  IFS=',' read -r -a _skills_arr <<< "$SKILLS"
  for s in "${_skills_arr[@]}"; do
    s="${s// /}"
    [[ -n "$s" ]] && SKILL_FLAGS+=(--skill "$s")
  done
fi

ROLE_FLAGS=()
[[ -n "$ROLE" ]] && ROLE_FLAGS+=(--role "$ROLE")

# --- Try CLI create (MCP-first logic lives in the lead; bash cannot
#     speak MCP directly). The lead should attempt MCP `create_session`
#     before invoking this script; if that fails or is unavailable, this
#     script takes over. The lead then reads the UUID this script prints.
log "spawning session via thurbox-cli: $NAME"
if ! thurbox-cli session create \
    --name "$NAME" \
    --repo-path "$REPO_PATH" \
    --worktree-branch "$WORKTREE_BRANCH" \
    --base-branch "$BASE_BRANCH" \
    "${ROLE_FLAGS[@]}" \
    "${SKILL_FLAGS[@]}" >&2; then
  die "thurbox-cli session create failed for $NAME"
fi

# --- Reconcile: always take the UUID from `session list`, picking the
#     most recent session matching the name.
log "reconciling UUID via thurbox-cli session list"
UUID="$(thurbox-cli session list --json 2>/dev/null \
  | jq -r --arg name "$NAME" '
      [.[] | select(.name == $name)]
      | sort_by(.created_at // .createdAt // "")
      | reverse
      | .[0].id // .[0].uuid // empty
    ' 2>/dev/null || true)"

if [[ -z "$UUID" ]]; then
  # Fallback: plain text session list, pick last line with name.
  UUID="$(thurbox-cli session list 2>/dev/null \
    | awk -v n="$NAME" '$0 ~ n { last=$1 } END { print last }')"
fi

[[ -n "$UUID" ]] || die "could not reconcile UUID for session $NAME"
printf '%s\n' "$UUID"
