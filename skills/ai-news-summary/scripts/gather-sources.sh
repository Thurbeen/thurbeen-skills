#!/usr/bin/env bash
# gather-sources.sh — Fetch candidate AI-news items from curated sources.
#
# Reads source config from .claude/config.yaml in the CURRENT directory
# (run this from the cloned ai-news repo root) and delegates fetching/parsing
# to fetch_sources.py. Emits the JSON object produced by that script.
#
# Usage: gather-sources.sh
# Env: EDITION, NEWS_DATE (passed through to the output object).
# Exit codes: 0=success, 2=fatal
# Output: JSON {edition, date, count, items:[...]}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

command -v python3 >/dev/null || die "python3 is required"

# Strip a single layer of surrounding quotes — config_get's no-yq awk fallback
# returns YAML values with their quotes intact, unlike the jq-yq path.
unquote() {
  local v="$1"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

HN_MIN_POINTS="$(unquote "$(config_get sources.hn_min_points 100)")"
ARXIV_CATEGORIES="$(unquote "$(config_get sources.arxiv_categories 'cs.AI cs.LG cs.CL')")"
ARXIV_MAX="$(unquote "$(config_get sources.arxiv_max 15)")"
RSS_FEEDS="$(unquote "$(config_get sources.rss_feeds '')")"
RSS_MAX_PER_FEED="$(unquote "$(config_get sources.rss_max_per_feed 20)")"

log "Gathering sources (HN>=${HN_MIN_POINTS}, arxiv='${ARXIV_CATEGORIES}', feeds present: $([[ -n "$RSS_FEEDS" ]] && echo yes || echo no))"

HN_MIN_POINTS="$HN_MIN_POINTS" \
ARXIV_CATEGORIES="$ARXIV_CATEGORIES" \
ARXIV_MAX="$ARXIV_MAX" \
RSS_FEEDS="$RSS_FEEDS" \
RSS_MAX_PER_FEED="$RSS_MAX_PER_FEED" \
EDITION="${EDITION:-}" \
NEWS_DATE="${NEWS_DATE:-}" \
  python3 "${SCRIPT_DIR}/fetch_sources.py"
