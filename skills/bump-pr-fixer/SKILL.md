---
name: bump-pr-fixer
description: Find Renovate dependency update PRs with failing CI and fix them using Claude Code.
user-invocable: false
allowed-tools: Bash, Read, Glob, Grep, Edit, Write
---

## Bump PR Fixer

Finds open Renovate PRs with failing CI checks across configured
repositories and uses Claude Code to diagnose and fix the failures.

**Required env vars:** `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `REPOS`
(newline-separated list of `owner/repo`).

---

### Step 1 — Setup

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/bump-pr-fixer/SKILL.md)")" && pwd)"
source "$SKILL_DIR/scripts/common.sh"
setup_git
require_env GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN REPOS
```

---

### Step 2 — Process each repo

For each repo in `$REPOS` (skip empty lines and `#` comments):

```bash
# Find failed Renovate PRs
FAILED_PRS="$(bash "$SKILL_DIR/scripts/find-failed-prs.sh" --repo "$repo")"
```

If no failed PRs, log and continue to next repo.

Otherwise, clone the repo:

```bash
repo_dir="/workspace/$(echo "$repo" | tr '/' '-')"
git clone "https://github.com/${repo}.git" "$repo_dir"
```

For each failed PR number:

```bash
bash "$SKILL_DIR/scripts/fix-pr.sh" \
  --repo "$repo" \
  --pr "$pr_number" \
  --workdir "$repo_dir"
```

Parse JSON output. Continue on failure (one PR failing should not
block the others).

Clean up the cloned repo after processing all PRs for that repo.

---

### Output

Print a summary of processed repos and PRs:
- Repos scanned
- PRs found / fixed / failed / no changes needed
