#!/usr/bin/env bash
# setup-repo.sh — Clone the ai-news content repo and resolve the current edition.
#
# Usage: setup-repo.sh
# Env: GH_TOKEN (required), AI_NEWS_REPO (default Thurbeen/ai-news),
#      AI_NEWS_WORKDIR (default $HOME/ai-news), EDITION (morning|evening, optional),
#      TZ (default Europe/Paris for edition/date resolution).
# Exit codes: 0=success, 2=fatal
# Output: JSON {workdir, repo, date, edition}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_env GH_TOKEN
setup_git

REPO="${AI_NEWS_REPO:-Thurbeen/ai-news}"
WORKDIR="${AI_NEWS_WORKDIR:-$HOME/ai-news}"
TZ_NAME="${TZ:-Europe/Paris}"

# Resolve date and edition (Europe/Paris). Edition is explicit via $EDITION,
# otherwise inferred from the local hour (before noon = morning).
NEWS_DATE="$(TZ="$TZ_NAME" date +%F)"
if [[ -n "${EDITION:-}" ]]; then
  ED="$EDITION"
else
  HOUR="$(TZ="$TZ_NAME" date +%H)"
  if [[ "$HOUR" -lt 12 ]]; then ED="morning"; else ED="evening"; fi
fi

log "Cloning ${REPO} into ${WORKDIR} (edition=${ED}, date=${NEWS_DATE})"
rm -rf "$WORKDIR"
git clone --depth=1 "https://github.com/${REPO}.git" "$WORKDIR" >&2 \
  || die "Failed to clone ${REPO}"

json_output "workdir=${WORKDIR}" "repo=${REPO}" "date=${NEWS_DATE}" "edition=${ED}"
