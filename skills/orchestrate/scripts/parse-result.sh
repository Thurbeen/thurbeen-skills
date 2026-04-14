#!/usr/bin/env bash
# parse-result.sh — extract the last ===RESULT=== JSON block from a
# worker's captured terminal output.
#
# Reads captured output from stdin (or --file <path>).
# Exit codes:
#   0 = found, JSON printed on stdout
#   1 = no sentinel yet (worker still running)
#   2 = sentinel present but JSON malformed

set -euo pipefail
source "$(dirname "$0")/common.sh"

INPUT=""
if [[ "${1:-}" == "--file" ]]; then
  [[ -f "$2" ]] || die "File not found: $2"
  INPUT="$(cat "$2")"
else
  INPUT="$(cat)"
fi

# Find the line number of the LAST "===RESULT===" marker.
LAST_MARKER=$(printf '%s\n' "$INPUT" | grep -n '^===RESULT===$' | tail -1 | cut -d: -f1 || true)

if [[ -z "$LAST_MARKER" ]]; then
  exit 1
fi

# The JSON should be on the line immediately after the marker.
JSON_LINE=$((LAST_MARKER + 1))
JSON="$(printf '%s\n' "$INPUT" | sed -n "${JSON_LINE}p" | sed 's/[[:space:]]*$//')"

if [[ -z "$JSON" ]]; then
  exit 2
fi

# Validate it parses as JSON if a parser is available.
if command -v jq &>/dev/null; then
  if ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    exit 2
  fi
fi

printf '%s\n' "$JSON"
