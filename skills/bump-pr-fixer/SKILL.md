---
name: bump-pr-fixer
description: Find Renovate dependency update PRs with failing CI and fix them using Claude Code.
user-invocable: false
allowed-tools: Bash, Read, Glob, Grep, Edit, Write, Agent, Skill
---

## Bump PR Fixer

Finds open Renovate PRs with failing CI checks across configured
repositories and uses Claude Code to diagnose and fix the failures.

**Required env vars:** `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `REPOS`
(newline-separated list of `owner/repo`).

---

### Step 1 — Setup

Verify required env vars and configure git for the CI runner:

```bash
[[ -n "$GH_TOKEN" && -n "$CLAUDE_CODE_OAUTH_TOKEN" && -n "$REPOS" ]] \
  || { echo "Missing required env vars"; exit 1; }

git config --global user.name  "claude-code-bot"
git config --global user.email "claude-code-bot@users.noreply.github.com"
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
```

---

### Step 2 — Process each repo

For each repo in `$REPOS` (skip empty lines and lines starting with `#`):

**Find failed Renovate PRs:**

```bash
gh pr list \
  --repo "$repo" \
  --author "app/renovate" \
  --state open \
  --json number,title,statusCheckRollup \
  --jq '
    [.[] | select(.statusCheckRollup[]? | .status == "COMPLETED" and .conclusion == "FAILURE")]
    | unique_by(.number)
    | [.[] | {number, title}]
  '
```

If the result is empty, log "no failed PRs in $repo" and continue to
the next repo.

Otherwise, clone the repo:

```bash
repo_dir="/workspace/$(echo "$repo" | tr '/' '-')"
rm -rf "$repo_dir"
git clone "https://github.com/${repo}.git" "$repo_dir"
```

For each failed PR number, run Step 3 below. Continue on failure —
one PR failing should not block the others.

After all PRs for that repo are processed, remove the clone:
`rm -rf "$repo_dir"`.

---

### Step 3 — Fix a single PR

Checkout the PR branch cleanly:

```bash
cd "$repo_dir"
git reset --hard
git clean -fd
DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
git checkout "$DEFAULT_BRANCH" && git pull --quiet
gh pr checkout "$pr_number"
```

**Delegate diagnosis and fix to a sub-agent** via the Agent tool.
Prompt:

> This is a Renovate dependency update PR (`<repo>`#`<pr_number>`) with
> failing CI checks. Working directory: `<repo_dir>`, already on the PR
> branch.
>
> Diagnose why CI is failing and fix the issue. The failure is likely
> caused by the dependency update requiring code changes. Pull the
> failing logs:
>
> ```bash
> gh pr checks --json name,conclusion,detailsUrl
> gh run view <run-id> --log-failed   # run-id is the trailing path segment of detailsUrl
> ```
>
> Make minimal targeted fixes — do not refactor unrelated code. After
> fixing, stage your changes with `git add`. Do not commit or push;
> the lead will handle that.

Allowed tools for the sub-agent: `Bash, Read, Edit, Write, Glob, Grep`.

After the sub-agent returns:

```bash
git diff --cached --quiet && echo "no changes" || echo "changes staged"
```

- **No changes** → record "no changes needed" for this PR, continue.
- **Changes staged** → invoke `/ship` via the Skill tool with the message
  `fix: resolve CI failures for dependency update`. `/ship` commits,
  rebases, pushes, and ensures the PR has auto-merge.

If the sub-agent errors (tool failure, timeout), record "claude_failed"
for this PR and continue.

---

### Output

Print a summary of processed repos and PRs:
- Repos scanned
- PRs found / fixed / failed / no changes needed
