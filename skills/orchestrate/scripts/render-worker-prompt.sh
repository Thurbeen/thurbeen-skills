#!/usr/bin/env bash
# render-worker-prompt.sh — substitute task fields into worker-init template.
#
# Usage:
#   render-worker-prompt.sh \
#     --title <t> --prompt <p> --acceptance <a> \
#     [--bead <bead_id>] [--branch <worktree_branch>]
#
# Emits the rendered prompt on stdout. Pure text helper, no state.
# --bead and --branch are optional for backward compatibility; when omitted
# they render as "(none)" so the template remains well-formed.

set -euo pipefail
source "$(dirname "$0")/common.sh"

TITLE=""
PROMPT=""
ACCEPTANCE=""
BEAD=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)      TITLE="$2";      shift 2 ;;
    --prompt)     PROMPT="$2";     shift 2 ;;
    --acceptance) ACCEPTANCE="$2"; shift 2 ;;
    --bead)       BEAD="$2";       shift 2 ;;
    --branch)     BRANCH="$2";     shift 2 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$TITLE"  ]] || die "--title required"
[[ -n "$PROMPT" ]] || die "--prompt required"
[[ -n "$ACCEPTANCE" ]] || ACCEPTANCE="(none specified)"
[[ -n "$BEAD"   ]] || BEAD="(none)"
[[ -n "$BRANCH" ]] || BRANCH="(none)"

TEMPLATE="$(dirname "$0")/../templates/worker-init.md"
[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"

# Substitute placeholders without invoking a shell on the values.
awk -v title="$TITLE" -v prompt="$PROMPT" -v accept="$ACCEPTANCE" \
    -v bead="$BEAD" -v branch="$BRANCH" '
  { gsub(/\{\{TITLE\}\}/,      title);
    gsub(/\{\{PROMPT\}\}/,     prompt);
    gsub(/\{\{ACCEPTANCE\}\}/, accept);
    gsub(/\{\{BEAD_ID\}\}/,    bead);
    gsub(/\{\{BRANCH\}\}/,     branch);
    print }
' "$TEMPLATE"
