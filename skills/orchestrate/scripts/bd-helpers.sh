#!/usr/bin/env bash
# bd-helpers.sh — thin wrappers around the `bd` CLI for the orchestrate skill.
#
# Subcommands:
#   detect                                         — prints "enabled" or "disabled"
#   create  --title T --priority P --type T --description D  — prints new bd id
#   start   --issue ID                             — bd set-state in-progress
#   note    --issue ID --message M                 — bd note
#   close   --issue ID --message M                 — bd close
#   dep     --issue A --blocks B                   — bd dep add (A blocks B)
#
# All subcommands emit human-readable logs on stderr and the authoritative
# value (bead id or nothing) on stdout.

set -euo pipefail
source "$(dirname "$0")/common.sh"

SUBCMD="${1:-}"
shift || true

case "$SUBCMD" in
  detect)
    dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
      if [[ -d "$dir/.beads" ]]; then
        printf 'enabled\n'
        exit 0
      fi
      dir="$(dirname "$dir")"
    done
    printf 'disabled\n'
    ;;

  create)
    TITLE=""
    PRIORITY="medium"
    TYPE="task"
    DESC=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title)       TITLE="$2";    shift 2 ;;
        --priority)    PRIORITY="$2"; shift 2 ;;
        --type)        TYPE="$2";     shift 2 ;;
        --description) DESC="$2";     shift 2 ;;
        *) die "create: unknown arg: $1" ;;
      esac
    done
    [[ -n "$TITLE" ]] || die "create: --title required"
    # `bd create` prints a line like "Created admin-22t: <title>".
    # Parse the first token that matches <prefix>-<slug>.
    local_out="$(bd create "$TITLE" \
      --priority "$PRIORITY" \
      --issue-type "$TYPE" \
      ${DESC:+--description "$DESC"} 2>&1)" \
      || die "create: bd create failed: $local_out"
    log "bd create output: $local_out"
    # Extract first <word>-<alnum> that looks like an id.
    id="$(printf '%s\n' "$local_out" | grep -oE '[a-z]+-[a-z0-9]+' | head -1 || true)"
    [[ -n "$id" ]] || die "create: could not parse bd id from: $local_out"
    printf '%s\n' "$id"
    ;;

  start)
    ISSUE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --issue) ISSUE="$2"; shift 2 ;;
        *) die "start: unknown arg: $1" ;;
      esac
    done
    [[ -n "$ISSUE" ]] || die "start: --issue required"
    bd set-state "$ISSUE" in-progress >&2
    ;;

  note)
    ISSUE=""
    MSG=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --issue)   ISSUE="$2"; shift 2 ;;
        --message) MSG="$2";   shift 2 ;;
        *) die "note: unknown arg: $1" ;;
      esac
    done
    [[ -n "$ISSUE" ]] || die "note: --issue required"
    [[ -n "$MSG"   ]] || die "note: --message required"
    bd note "$ISSUE" "$MSG" >&2
    ;;

  close)
    ISSUE=""
    MSG=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --issue)   ISSUE="$2"; shift 2 ;;
        --message) MSG="$2";   shift 2 ;;
        *) die "close: unknown arg: $1" ;;
      esac
    done
    [[ -n "$ISSUE" ]] || die "close: --issue required"
    if [[ -n "$MSG" ]]; then
      bd close "$ISSUE" -m "$MSG" >&2
    else
      bd close "$ISSUE" >&2
    fi
    ;;

  dep)
    ISSUE=""
    BLOCKS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --issue)  ISSUE="$2";  shift 2 ;;
        --blocks) BLOCKS="$2"; shift 2 ;;
        *) die "dep: unknown arg: $1" ;;
      esac
    done
    [[ -n "$ISSUE"  ]] || die "dep: --issue required"
    [[ -n "$BLOCKS" ]] || die "dep: --blocks required"
    bd dep add "$ISSUE" "$BLOCKS" >&2
    ;;

  ""|-h|--help|help)
    cat <<'EOF' >&2
bd-helpers.sh subcommands:
  detect
  create  --title T [--priority P] [--type T] [--description D]
  start   --issue ID
  note    --issue ID --message M
  close   --issue ID --message M
  dep     --issue A --blocks B
EOF
    [[ -z "$SUBCMD" ]] && exit 2 || exit 0
    ;;

  *)
    die "Unknown subcommand: $SUBCMD"
    ;;
esac
