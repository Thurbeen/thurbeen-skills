#!/usr/bin/env bash
# render-worker-prompt.sh — substitute task fields into worker-init template.
#
# Usage:
#   render-worker-prompt.sh --title <t> --prompt <p> --acceptance <a>
#
# Emits the rendered prompt on stdout. Pure text helper, no state.

set -euo pipefail
source "$(dirname "$0")/common.sh"

TITLE=""
PROMPT=""
ACCEPTANCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)      TITLE="$2";      shift 2 ;;
    --prompt)     PROMPT="$2";     shift 2 ;;
    --acceptance) ACCEPTANCE="$2"; shift 2 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$TITLE"  ]] || die "--title required"
[[ -n "$PROMPT" ]] || die "--prompt required"
[[ -n "$ACCEPTANCE" ]] || ACCEPTANCE="(none specified)"

TEMPLATE="$(dirname "$0")/../templates/worker-init.md"
[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"

# Substitute placeholders without invoking a shell on the values.
awk -v title="$TITLE" -v prompt="$PROMPT" -v accept="$ACCEPTANCE" '
  { gsub(/\{\{TITLE\}\}/,      title);
    gsub(/\{\{PROMPT\}\}/,     prompt);
    gsub(/\{\{ACCEPTANCE\}\}/, accept);
    print }
' "$TEMPLATE"
