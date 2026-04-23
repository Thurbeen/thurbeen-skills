---
name: create-repo
description: Create a GitHub repository from template with full configuration (merge settings, branch protection, profile READMEs).
user-invocable: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

## Create Repo

Create a new GitHub repository from a template, configure it with
standardized settings (rebase-only merges, branch protection ruleset),
and update GitHub profile READMEs with the new project.

**Input:** `$ARGUMENTS` — repo name (required), plus optional
`--visibility`, `--description`, `--org`, `--emoji` flags.

---

### Phase 0 — Resolve defaults

Read `.claude/config.yaml` if present (defaults shown):

```bash
ORG="$(yq        -r '.["create-repo"].default_org   // ""'                 .claude/config.yaml 2>/dev/null)"
VISIBILITY="$(yq -r '.["create-repo"].visibility    // "private"'          .claude/config.yaml 2>/dev/null)"
TEMPLATE="$(yq   -r '.["create-repo"].template      // "Thurbeen/template"' .claude/config.yaml 2>/dev/null)"
SKIP_PROFILES="$(yq -r '.["create-repo"].skip_profiles // false'           .claude/config.yaml 2>/dev/null)"
```

Overlay explicit flags from `$ARGUMENTS`:
- First positional word → `NAME` (required). If missing, STOP.
- `--visibility <public|private>` overrides config.
- `--description "<text>"` optional.
- `--org <org>` overrides config.
- `--emoji <emoji>` optional (profile entries).

---

### Phase 1 — Create from template

Build the full name (`$ORG/$NAME` if `ORG` set, else `$NAME`):

```bash
gh repo create "<FULL_NAME>" \
  --template "$TEMPLATE" \
  --"$VISIBILITY" \
  --clone \
  [--description "<DESCRIPTION>"]
```

On failure, STOP and report the `gh` error.

Resolve paths and metadata:

```bash
CLONE_PATH="$(cd "$NAME" && pwd)"
REPO_INFO="$(cd "$NAME" && gh repo view --json nameWithOwner,url)"
REPO="$(echo "$REPO_INFO" | jq -r '.nameWithOwner')"
URL="$(echo "$REPO_INFO"  | jq -r '.url')"
```

Save `REPO`, `CLONE_PATH`, `URL`, `VISIBILITY` for later phases.

---

### Phase 2 — Configure merge settings and ruleset

Detect default branch:

```bash
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name')"
```

**Merge settings** — rebase-only, auto-merge, delete branch on merge:

```bash
gh api -X PATCH "repos/${REPO}" \
  -F allow_merge_commit=false \
  -F allow_squash_merge=false \
  -F allow_rebase_merge=true \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true
```

**Branch ruleset** (`protect-default-branch`) — idempotent: POST if
absent, PUT if already present.

```bash
EXISTING_RULESET_ID="$(gh api "repos/${REPO}/rulesets" \
  -q '.[] | select(.name == "protect-default-branch") | .id' 2>/dev/null || true)"

if [[ -n "$EXISTING_RULESET_ID" ]]; then
  METHOD="PUT"
  ENDPOINT="repos/${REPO}/rulesets/${EXISTING_RULESET_ID}"
  RULESET_ACTION="updated"
else
  METHOD="POST"
  ENDPOINT="repos/${REPO}/rulesets"
  RULESET_ACTION="created"
fi

gh api -X "$METHOD" "$ENDPOINT" --input - <<'RULESET_EOF'
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
    {"type": "deletion"},
    {"type": "non_fast_forward"},
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
          {"context": "All Checks", "integration_id": 15368}
        ]
      }
    }
  ]
}
RULESET_EOF
```

Save `RULESET_ACTION` for the summary.

---

### Phase 3 — Update profile READMEs

If `SKIP_PROFILES` is `true`, skip this phase.

Extract `owner` from `REPO` (`owner/name` → `owner`). Determine target
profile repos based on owner and visibility:

**If owner is `Thurbeen`:**

| Profile repo | File | Section match | Condition |
|---|---|---|---|
| `Thurbeen/.github-private` | `profile/README.md` | `## Projects` | always |
| `Thurbeen/.github`         | `profile/README.md` | `## Projects` | `VISIBILITY == public` |
| `LeTuR/LeTuR`              | `README.md`         | `Projects — [Thurbeen]` | always |

**If owner is `LeTuR`:**

| Profile repo | File | Section match |
|---|---|---|
| `LeTuR/LeTuR` | `README.md` | `Projects — Personal` |

Pick an emoji that fits the description (or use `--emoji` from
`$ARGUMENTS` if given). If no `--description` was provided, use the
repo name as description.

Build the entry line:

```
- <emoji> [<name>](https://github.com/<repo>) — <description>
```

For each qualifying profile repo, run **Step 3a** below.

#### Step 3a — Add entry to one profile

Work in a tempdir:

```bash
WORK_DIR="$(mktemp -d)"
gh repo clone "<profile_repo>" "$WORK_DIR/repo" -- --depth 1
cd "$WORK_DIR/repo"
```

**Idempotency check.** Use Grep on `<file>` for `https://github.com/${REPO}`.
If found, record "skipped — entry already exists" for this profile,
clean up (`rm -rf "$WORK_DIR"`), skip the rest of Step 3a.

**Insert the entry.** Use Read on `<file>` to find:
1. The heading line starting with `#` that contains `<section match>`.
2. The last line matching `^- ` between that heading and the next
   heading (or EOF) — that's the insertion point.

Use Edit to replace that last bullet with itself plus the new entry on
the next line. To keep the Edit `old_string` unique, include the
preceding heading line or enough surrounding context.

If the section has no bullet yet, record a warning for this profile
and skip (do not abort the whole phase).

**Commit, push, create PR:**

```bash
git config user.name  "claude-code-bot"
git config user.email "claude-code-bot@users.noreply.github.com"

BRANCH="profile/add-<source_name>"   # source_name = basename of REPO
git checkout -b "$BRANCH"
git add "<file>"
git commit -m "docs: add ${REPO} to profile"
git push -u origin "$BRANCH"

PR_URL="$(gh pr create \
  --repo "<profile_repo>" \
  --title "Add ${REPO} to profile" \
  --body  "Add **${REPO}** to the project list." \
  --head  "$BRANCH")"

gh pr merge "$PR_URL" --auto --rebase 2>/dev/null || echo "Auto-merge not available"
```

Clean up: `rm -rf "$WORK_DIR"`. Save `PR_URL`.

If any step fails, warn but do not abort the whole skill — the profile
update is non-fatal.

---

### Final Output

- Repository: `owner/repo` (visibility)
- Template: template used
- Clone path: where the repo was cloned
- Merge: rebase only, auto-merge enabled, delete branch on merge
- Ruleset: protect-default-branch (created/updated)
- Profiles: each profile repo updated (PR link) or skipped
- URL: link to the repository
