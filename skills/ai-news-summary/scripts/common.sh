#!/usr/bin/env bash
# common.sh — Shared utilities for thurbeen-skills scripts.
# Source this file: source "$(dirname "$0")/common.sh"

set -euo pipefail

# --- Logging (stderr) ---

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "FATAL: $*"; exit 2; }

# --- Environment ---

require_env() {
  local var
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "Missing required env var: ${var}"
  done
}

# --- Git ---

setup_git() {
  git config --global user.name "claude-code-bot"
  git config --global user.email "claude-code-bot@users.noreply.github.com"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
  fi
}

# Detect default branch from origin
detect_default_branch() {
  git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'
}

# --- JSON output (stdout) ---

# Emit a JSON object from key=value pairs.
# Usage: json_output key1=val1 key2=val2
# Values are strings unless prefixed with @json: for raw JSON.
# Example: json_output status=ok "checks=@json:[1,2,3]"
json_output() {
  local first=true
  printf '{'
  for pair in "$@"; do
    local key="${pair%%=*}"
    local val="${pair#*=}"
    $first || printf ','
    first=false
    if [[ "$val" == @json:* ]]; then
      printf '"%s":%s' "$key" "${val#@json:}"
    else
      # Escape backslashes, double quotes, and newlines for JSON string
      val="${val//\\/\\\\}"
      val="${val//\"/\\\"}"
      val="$(printf '%s' "$val" | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')"
      printf '"%s":"%s"' "$key" "$val"
    fi
  done
  printf '}\n'
}

# --- Config ---

# Config file path (project-local)
_CONFIG_FILE=".claude/config.yaml"

# Read a dotted config key from .claude/config.yaml.
# Returns empty string if key not found or file missing.
# Usage: config_get "publish.skip_refactor" "false"
#   $1 = dotted key path (e.g., "publish.skip_refactor")
#   $2 = default value (optional)
config_get() {
  local key="$1"
  local default="${2:-}"

  if [[ ! -f "$_CONFIG_FILE" ]]; then
    printf '%s' "$default"
    return
  fi

  local val=""
  if command -v yq &>/dev/null; then
    val="$(yq -r ".${key} // empty" "$_CONFIG_FILE" 2>/dev/null)" || val=""
  else
    # Fallback: simple 2-level key parser (handles "section.key: value")
    local section="${key%%.*}"
    local subkey="${key#*.}"
    if [[ "$section" == "$subkey" ]]; then
      # Top-level key
      val="$(grep -E "^${key}:" "$_CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//')" || val=""
    else
      # Two-level key: find section, then find key within it
      val="$(awk -v sect="$section" -v k="$subkey" '
        /^[^ #]/ { in_sect = ($0 ~ "^"sect":") }
        in_sect && $0 ~ "^[[:space:]]+"k":" {
          sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
          sub(/[[:space:]]*$/, "")
          print
          exit
        }
      ' "$_CONFIG_FILE" 2>/dev/null)" || val=""
    fi
  fi

  if [[ -z "$val" || "$val" == "null" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}
