#!/usr/bin/env bash
# configure-repo.sh — Apply merge settings and branch ruleset to a GitHub repo.
#
# Usage: configure-repo.sh --repo <owner/repo>
#
# Configures:
# - Rebase-only merges (disable merge commit and squash)
# - Auto-merge enabled
# - Delete branch on merge
# - Branch ruleset protecting the default branch
#
# Exit codes: 0=success, 2=fatal
# Output: JSON on stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *)      die "Unknown argument: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "Missing --repo argument"

log "Configuring repository: ${REPO}"

# ── Default branch ──────────────────────────────────────
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name')
log "Default branch: ${DEFAULT_BRANCH}"

# ── Merge settings ──────────────────────────────────────
log "Setting merge strategy to rebase-only..."

if ! MERGE_OUTPUT=$(gh api -X PATCH "repos/${REPO}" \
  -F allow_merge_commit=false \
  -F allow_squash_merge=false \
  -F allow_rebase_merge=true \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true 2>&1); then
  json_output "error=Failed to set merge settings: ${MERGE_OUTPUT}"
  exit 2
fi

log "Merge settings applied"

# ── Branch ruleset ──────────────────────────────────────
log "Creating branch ruleset: protect-default-branch..."

# Check if ruleset already exists (idempotent)
EXISTING_RULESET_ID=$(gh api "repos/${REPO}/rulesets" \
  -q '.[] | select(.name == "protect-default-branch") | .id' 2>/dev/null || true)

METHOD="POST"
ENDPOINT="repos/${REPO}/rulesets"
RULESET_ACTION="created"
if [[ -n "${EXISTING_RULESET_ID}" ]]; then
  METHOD="PUT"
  ENDPOINT="repos/${REPO}/rulesets/${EXISTING_RULESET_ID}"
  RULESET_ACTION="updated"
  log "Ruleset already exists (ID: ${EXISTING_RULESET_ID}), updating..."
fi

# integration_id 15368 = GitHub Actions
# actor_id 2 = Repository Admin role (RepositoryRole)
if ! RULESET_RESPONSE=$(gh api -X "${METHOD}" "${ENDPOINT}" \
  --input - <<'RULESET_EOF'
{
  "name": "protect-default-branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 2,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          {
            "context": "All Checks",
            "integration_id": 15368
          }
        ]
      }
    }
  ]
}
RULESET_EOF
); then
  json_output "error=Failed to create/update branch ruleset"
  exit 2
fi

RULESET_ID=$(echo "$RULESET_RESPONSE" | jq -r '.id')
log "Ruleset ${RULESET_ACTION} (ID: ${RULESET_ID})"

json_output \
  "repo=${REPO}" \
  "default_branch=${DEFAULT_BRANCH}" \
  "merge_settings=applied" \
  "ruleset_action=${RULESET_ACTION}" \
  "ruleset_id=${RULESET_ID}"
