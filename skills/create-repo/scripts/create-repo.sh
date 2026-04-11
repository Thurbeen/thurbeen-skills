#!/usr/bin/env bash
# create-repo.sh — Create a GitHub repo from a template and clone it.
#
# Usage: create-repo.sh --name <name> --template <owner/repo>
#          [--org <org>] [--visibility <private|public>]
#          [--description "<text>"]
#
# Exit codes: 0=success, 2=fatal
# Output: JSON on stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NAME=""
TEMPLATE=""
ORG=""
VISIBILITY="private"
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --template)    TEMPLATE="$2"; shift 2 ;;
    --org)         ORG="$2"; shift 2 ;;
    --visibility)  VISIBILITY="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    *)             die "Unknown argument: $1" ;;
  esac
done

[[ -n "$NAME" ]]     || die "Missing --name argument"
[[ -n "$TEMPLATE" ]] || die "Missing --template argument"

# Build the full repo name
if [[ -n "$ORG" ]]; then
  FULL_NAME="${ORG}/${NAME}"
else
  FULL_NAME="${NAME}"
fi

log "Creating repo ${FULL_NAME} from template ${TEMPLATE}"

# Build gh repo create command
CREATE_ARGS=(
  "$FULL_NAME"
  --template "$TEMPLATE"
  --"${VISIBILITY}"
  --clone
)

if [[ -n "$DESCRIPTION" ]]; then
  CREATE_ARGS+=(--description "$DESCRIPTION")
fi

if ! CREATE_OUTPUT=$(gh repo create "${CREATE_ARGS[@]}" 2>&1); then
  json_output "error=${CREATE_OUTPUT}"
  exit 2
fi

log "Repository created"

[[ -d "$NAME" ]] || die "Clone directory not found: $NAME"

CLONE_PATH="$(cd "$NAME" && pwd)"
REPO_INFO=$(cd "$NAME" && gh repo view --json nameWithOwner,url)
REPO=$(echo "$REPO_INFO" | jq -r '.nameWithOwner')
URL=$(echo "$REPO_INFO" | jq -r '.url')

log "Cloned to ${CLONE_PATH}"

json_output \
  "repo=${REPO}" \
  "name=${NAME}" \
  "visibility=${VISIBILITY}" \
  "url=${URL}" \
  "clone_path=${CLONE_PATH}" \
  "template=${TEMPLATE}"
