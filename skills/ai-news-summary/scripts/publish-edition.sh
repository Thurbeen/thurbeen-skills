#!/usr/bin/env bash
# publish-edition.sh — Commit and push a written edition file to the ai-news repo.
#
# Run from the cloned ai-news repo root. The edition markdown file must already
# be written by the agent. Pushing to the default branch triggers the CI image
# build, whose 7-char SHA becomes the deployed image tag.
#
# Usage: publish-edition.sh <path-to-edition.md>
# Env: GH_TOKEN (required, for push).
# Exit codes: 0=published, 1=no changes, 2=fatal
# Output: JSON {status, file, sha}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_env GH_TOKEN
setup_git

FILE="${1:-}"
[[ -n "$FILE" ]] || die "Usage: publish-edition.sh <path-to-edition.md>"
[[ -f "$FILE" ]] || die "Edition file not found: ${FILE}"

BRANCH="$(detect_default_branch)"
BRANCH="${BRANCH:-main}"

git add "$FILE"
if git diff --cached --quiet; then
  log "No changes to publish for ${FILE}"
  json_output "status=no_changes" "file=${FILE}"
  exit 1
fi

# -c commit.gpgsign=false: never depend on a signing key being present in the
# agent container (and ignore any inherited signing config).
git -c commit.gpgsign=false commit -m "feat(content): $(basename "$FILE" .md) edition" >&2 \
  || die "git commit failed"
git push origin "HEAD:${BRANCH}" >&2 || die "git push failed"

SHA="$(git rev-parse --short=7 HEAD)"
log "Published ${FILE} as ${SHA}"
json_output "status=published" "file=${FILE}" "sha=${SHA}"
