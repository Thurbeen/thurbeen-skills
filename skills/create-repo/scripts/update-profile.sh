#!/usr/bin/env bash
# update-profile.sh — Add a project entry to a GitHub profile README.
#
# Clones the profile repo, inserts the entry after the last bullet
# in the matching section, commits, pushes, and creates a PR.
#
# Usage: update-profile.sh --profile-repo <owner/repo> --file <path>
#          --section "<heading text>" --entry "<markdown line>"
#          --source-repo <owner/repo>
#
# Exit codes: 0=success, 1=skipped (entry already exists), 2=fatal
# Output: JSON on stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE_REPO=""
FILE=""
SECTION=""
ENTRY=""
SOURCE_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-repo) PROFILE_REPO="$2"; shift 2 ;;
    --file)         FILE="$2"; shift 2 ;;
    --section)      SECTION="$2"; shift 2 ;;
    --entry)        ENTRY="$2"; shift 2 ;;
    --source-repo)  SOURCE_REPO="$2"; shift 2 ;;
    *)              die "Unknown argument: $1" ;;
  esac
done

[[ -n "$PROFILE_REPO" ]] || die "Missing --profile-repo"
[[ -n "$FILE" ]]         || die "Missing --file"
[[ -n "$SECTION" ]]      || die "Missing --section"
[[ -n "$ENTRY" ]]        || die "Missing --entry"
[[ -n "$SOURCE_REPO" ]]  || die "Missing --source-repo"

SOURCE_NAME="${SOURCE_REPO#*/}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Cloning ${PROFILE_REPO}..."
if ! gh repo clone "$PROFILE_REPO" "$WORK_DIR/repo" -- --depth 1 >/dev/null 2>&1; then
  die "Failed to clone ${PROFILE_REPO}"
fi

cd "$WORK_DIR/repo" || die "Failed to enter clone directory"

[[ -f "$FILE" ]] || die "File not found in repo: ${FILE}"

# Check if entry already exists (by source repo URL)
REPO_URL="https://github.com/${SOURCE_REPO}"
if grep -qF "$REPO_URL" "$FILE"; then
  log "Entry for ${SOURCE_REPO} already exists in ${PROFILE_REPO}/${FILE}"
  json_output \
    "profile_repo=${PROFILE_REPO}" \
    "action=skipped" \
    "reason=already exists"
  exit 1
fi

log "Inserting entry into section: ${SECTION}"

# Insert entry after the last bullet line (^- ) in the matching section.
# A section starts at a heading line containing $SECTION and ends at
# the next heading line (^#) or EOF.
if ! awk -v section="$SECTION" -v entry="$ENTRY" '
BEGIN { in_section = 0; last_bullet = 0 }
{
  lines[NR] = $0
  if (index($0, section) > 0 && $0 ~ /^#/) {
    in_section = 1
  } else if (in_section && $0 ~ /^#/) {
    in_section = 0
  }
  if (in_section && $0 ~ /^- /) {
    last_bullet = NR
  }
}
END {
  if (last_bullet == 0) {
    print "ERROR: no bullet found in section" > "/dev/stderr"
    exit 1
  }
  for (i = 1; i <= NR; i++) {
    print lines[i]
    if (i == last_bullet) {
      print entry
    }
  }
}
' "$FILE" > "${FILE}.tmp"; then
  rm -f "${FILE}.tmp"
  die "Failed to insert entry — section '${SECTION}' not found or has no bullets"
fi

mv "${FILE}.tmp" "$FILE"

# Configure git identity for the commit
git config user.name "claude-code-bot"
git config user.email "claude-code-bot@users.noreply.github.com"

BRANCH="profile/add-${SOURCE_NAME}"
git checkout -b "$BRANCH" >/dev/null 2>&1
git add "$FILE"
git commit -m "docs: add ${SOURCE_REPO} to profile" >/dev/null 2>&1

log "Pushing branch ${BRANCH}..."
if ! git push -u origin "$BRANCH" >/dev/null 2>&1; then
  die "Failed to push branch to ${PROFILE_REPO}"
fi

log "Creating pull request..."
if ! PR_URL=$(gh pr create \
  --repo "$PROFILE_REPO" \
  --title "Add ${SOURCE_REPO} to profile" \
  --body "Add **${SOURCE_REPO}** to the project list." \
  --head "$BRANCH" 2>&1); then
  die "Failed to create PR: ${PR_URL}"
fi

# Enable auto-merge so it lands without manual intervention
gh pr merge "$PR_URL" --auto --rebase >/dev/null 2>&1 || warn "Auto-merge not available for ${PROFILE_REPO}"

log "PR created: ${PR_URL}"

json_output \
  "profile_repo=${PROFILE_REPO}" \
  "action=pr_created" \
  "pr_url=${PR_URL}" \
  "branch=${BRANCH}"
