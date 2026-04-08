---
name: publish
description: Refactor and test recent changes, ship as a PR with auto-merge, then monitor CI and auto-fix failures until merged.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, WebFetch, Skill
---

## Publish

Refactor recent changes, then ship the current branch as a PR
with auto-merge enabled. After shipping, monitor CI checks and
proactively fix any failures until the PR merges. Be thorough
on refactoring but efficient on shipping.

**Input:** `$ARGUMENTS` optionally describes what was done
(used for the commit message and PR description).

---

### Phase 0 — Pre-flight

Run `/sync` to sync the branch with the remote default branch
before refactoring.

Then determine DEFAULT_BRANCH and CURRENT_BRANCH:

```bash
git remote show origin | grep 'HEAD branch' | awk '{print $NF}'
git branch --show-current
```

If on the default branch, STOP: "Create a feature branch
first."

---

### Phase 1 — Refactor

Run `/refactor` to perform the full 3-pass refactoring cycle
on recent changes (structure, coherence, tests).

---

### Phase 2 — Ship

Run `/ship` to commit, sync, push, and create/update a PR
with auto-merge. If `$ARGUMENTS` was provided, pass it along
so the commit message and PR description reflect it.

---

### Phase 3 — Monitor & Validate

After shipping, monitor the PR until it merges or a hard-stop
condition is reached. Be proactive: if CI fails, diagnose and
fix the issue, then push again.

This phase adapts to the project: not all repos have CI
checks, deployments, or auto-merge. Detect what applies and
skip what doesn't.

#### Step 0 — Detect project capabilities

```text
Run in parallel:
- gh pr checks --json name,state  → HAS_CHECKS (non-empty list)
- gh pr view --json autoMergeRequest → HAS_AUTO_MERGE (non-null)

If no checks and no auto-merge:
    Skip monitoring entirely → go to Final Output
If no checks but auto-merge is set:
    Wait for merge only (skip Fix step entirely)
```

#### Monitor loop

```text
fix_count = 0
wait = 30  # seconds
round = 0

while round < 10:
    round += 1
    sleep <wait> seconds
    wait = min(wait * 1.5, 120)

    Run in parallel:
    - gh pr view --json state,mergeStateStatus,mergeable
    - gh pr checks --json name,state,conclusion,detailsUrl

    Evaluate:

    A) PR state == MERGED → go to Validate step
    B) All checks passing, merge pending → continue loop
    C) One or more checks failed → go to Fix step
    D) PR closed (not merged) → STOP: "PR was closed"
    E) Merge conflicts → STOP: "Merge conflicts — rebase manually"
```

#### Fix step

```text
if fix_count >= 3:
    STOP: "CI still failing after 3 fix attempts.
    Failing checks: <list>. Manual intervention required."

fix_count += 1

1. Identify failed check(s) from gh pr checks output
2. For each failed check:
   a. Extract run-id from the details URL
   b. Get log: gh run view <run-id> --log-failed
   c. Read error output and diagnose root cause
3. Apply fixes to the codebase
4. Run /ship to commit and push the fix
5. Reset wait = 30
6. Continue monitor loop
```

#### Validate step

After the PR merges:

1. Confirm merge: `gh pr view --json state` → assert MERGED
2. Check for deployment workflows:
   `gh run list --branch <DEFAULT_BRANCH> --limit 5 --json name,status,conclusion`
3. If a deployment run is in progress, poll every 30s (max 5
   times) until it completes or fails
4. If deployment fails, STOP and show the failed run URL
5. If no deployment runs exist, skip — not all projects deploy

---

### Final Output

Print a summary (max 8 lines):

- Refactor: Pass 1 + Pass 2 + Pass 3 changes (counts)
- Commit: new or amended, with message
- PR: URL
- Auto-merge: enabled / not configured
- CI: passed (or fixed N times) / no checks
- Merge: confirmed / pending
- Deploy: succeeded / failed / no deployment detected
