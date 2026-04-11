---
name: publish
description: Refactor and test recent changes, ship as a PR with auto-merge, then monitor CI and auto-fix failures until merged.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, WebFetch, Skill
---

## Publish

Refactor recent changes, then ship as PRs with auto-merge enabled.
Detects all repos with publishable changes within allowed
directories and runs the full publish flow for each.

**Input:** `$ARGUMENTS` optionally describes what was done
(used for the commit message and PR description).

---

### Phase 0 — Detect Repos

Use the Agent tool to discover all git repositories with
publishable changes across allowed directories.

Spawn an agent with the following task:

> Find all git repositories within my allowed directories that
> have publishable changes. A repo has publishable changes if it
> is on a feature branch (not the default branch) AND has either
> uncommitted changes or commits ahead of the default branch.
>
> For each repo found, report:
> - path (absolute)
> - name (directory basename)
> - current branch
> - default branch
> - number of commits ahead
> - whether it has uncommitted changes
>
> Use `git` commands to check each repo. Skip repos that are on
> their default branch with no changes.

Parse the agent's response into a list of repos to publish.

If no repos have publishable changes → STOP: "No repos with
publishable changes found."

Save the repos list. For each repo in the list, execute
Phases 1–4 below **sequentially** (cd into the repo's `path`
before running each phase's scripts).

---

### Phase 1 — Pre-flight (per repo)

Change into the repo directory, then run:

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/publish/SKILL.md)")" && pwd)"
cd "<repo.path>"
bash "$SKILL_DIR/scripts/preflight.sh"
```

Parse the JSON output:
- If `rebase` is `"conflict"` → STOP this repo: show
  `conflict_files` and ask user. Continue with next repo.
- If exit code is 2 → STOP this repo: show `error`.
  Continue with next repo.
- Save `default_branch` and `current_branch` for later phases

---

### Phase 2 — Refactor (per repo)

Check config first (from the repo's working directory):

```bash
cd "<repo.path>"
source "$SKILL_DIR/scripts/common.sh"
config_get "publish.skip_refactor" "false"
```

If `skip_refactor` is `"true"`, skip this phase.

Otherwise, run `/refactor` to perform the full 3-pass refactoring
cycle on recent changes (structure, coherence, tests).

---

### Phase 3 — Ship (per repo)

Run the ship script from the repo directory:

```bash
cd "<repo.path>"
bash "$SKILL_DIR/scripts/ship.sh" --message "<conventional commit message>"
```

If `$ARGUMENTS` was provided and there is only one repo,
use it to craft the commit message. For multiple repos,
infer type and scope from each repo's diff independently.
Always use conventional commit format.

Parse the JSON output:
- If `rebase` is `"conflict"` → STOP this repo
- Save `pr.url` for the final output

---

### Phase 4 — Monitor & Validate (per repo)

After shipping, monitor the PR until it merges or a hard-stop
condition is reached.

#### Step 0 — Detect capabilities

```bash
cd "<repo.path>"
gh pr checks --json name,state 2>/dev/null
gh pr view --json autoMergeRequest 2>/dev/null
```

- If no checks and no auto-merge → skip monitoring → record result
- If no checks but auto-merge → wait for merge only

#### Monitor loop

```text
fix_count = 0
wait = 30
max_rounds = config_get("publish.monitor_rounds", "10")
max_fixes = config_get("publish.max_fix_attempts", "3")

while round < max_rounds:
    round += 1
    sleep <wait> seconds
    wait = min(wait * 1.5, 120)

    Run monitor script:
    cd "<repo.path>"
    bash "$SKILL_DIR/scripts/monitor.sh"

    Parse JSON action field:

    "merged"  → run validate.sh, record result, move to next repo
    "wait"    → continue loop
    "stop"    → record stop_reason, move to next repo
    "fix"     → go to Fix step
```

#### Fix step

```text
if fix_count >= max_fixes:
    Record: "CI still failing after N attempts. Manual intervention required."
    Move to next repo.

fix_count += 1

1. Read failed_checks from monitor.sh JSON output
2. For each failed check:
   a. Extract run-id from detailsUrl
   b. Get log: gh run view <run-id> --log-failed
   c. Diagnose root cause
3. Apply fixes to the codebase (ensure you're in repo.path)
4. Run ship script again:
   cd "<repo.path>"
   bash "$SKILL_DIR/scripts/ship.sh" --message "fix: resolve CI failure"
5. Reset wait = 30
6. Continue monitor loop
```

#### Validate step

After PR merges, poll for deployment status (max 5 rounds, 30s apart):

```text
for round in 1..5:
    cd "<repo.path>"
    bash "$SKILL_DIR/scripts/validate.sh" --branch <default_branch>

    Parse JSON deployment field:
    found=false        → record, move on
    status="success"   → record, move on
    status="failure"   → record with deployment URL, move on
    status="in_progress" → sleep 30, continue polling
```

---

### Final Output

Print a summary table covering all repos (max 4 lines per repo):

```
## <repo.name> (<repo.branch>)
- PR: <url>
- CI: passed (or fixed N times) / no checks / failed
- Merge: confirmed / pending / conflict
```

If only one repo was published, use the single-repo format:

- Refactor: Pass 1 + Pass 2 + Pass 3 changes (counts), or skipped
- Commit: new or amended, with message
- PR: URL
- Auto-merge: enabled / not configured
- CI: passed (or fixed N times) / no checks
- Merge: confirmed / pending
- Deploy: succeeded / failed / no deployment detected
