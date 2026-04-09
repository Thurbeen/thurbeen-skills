---
name: publish
description: Refactor and test recent changes, ship as a PR with auto-merge, then monitor CI and auto-fix failures until merged.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, WebFetch, Skill
---

## Publish

Refactor recent changes, then ship the current branch as a PR
with auto-merge enabled. After shipping, monitor CI checks and
proactively fix any failures until the PR merges.

**Input:** `$ARGUMENTS` optionally describes what was done
(used for the commit message and PR description).

---

### Phase 0 — Pre-flight

Run the preflight script to sync with the remote default branch:

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/publish/SKILL.md)")" && pwd)"
bash "$SKILL_DIR/scripts/preflight.sh"
```

Parse the JSON output:
- If `rebase` is `"conflict"` → STOP: show `conflict_files` and ask user
- If exit code is 2 → STOP: show `error` from JSON
- Save `default_branch` and `current_branch` for later phases

---

### Phase 1 — Refactor

Check config first:

```bash
source "$SKILL_DIR/scripts/common.sh"
config_get "publish.skip_refactor" "false"
```

If `skip_refactor` is `"true"`, skip this phase.

Otherwise, run `/refactor` to perform the full 3-pass refactoring
cycle on recent changes (structure, coherence, tests).

---

### Phase 2 — Ship

Run the ship script:

```bash
bash "$SKILL_DIR/scripts/ship.sh" --message "<conventional commit message>"
```

If `$ARGUMENTS` was provided, use it to craft the commit message.
Otherwise, infer type and scope from the diff. Always use
conventional commit format.

Parse the JSON output:
- If `rebase` is `"conflict"` → STOP
- Save `pr.url` for the final output

---

### Phase 3 — Monitor & Validate

After shipping, monitor the PR until it merges or a hard-stop
condition is reached.

#### Step 0 — Detect capabilities

```bash
gh pr checks --json name,state 2>/dev/null
gh pr view --json autoMergeRequest 2>/dev/null
```

- If no checks and no auto-merge → skip monitoring → Final Output
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
    bash "$SKILL_DIR/scripts/monitor.sh"

    Parse JSON action field:

    "merged"  → run validate.sh, go to Final Output
    "wait"    → continue loop
    "stop"    → STOP: show stop_reason
    "fix"     → go to Fix step
```

#### Fix step

```text
if fix_count >= max_fixes:
    STOP: "CI still failing after N attempts. Manual intervention required."

fix_count += 1

1. Read failed_checks from monitor.sh JSON output
2. For each failed check:
   a. Extract run-id from detailsUrl
   b. Get log: gh run view <run-id> --log-failed
   c. Diagnose root cause
3. Apply fixes to the codebase
4. Run ship script again:
   bash "$SKILL_DIR/scripts/ship.sh" --message "fix: resolve CI failure"
5. Reset wait = 30
6. Continue monitor loop
```

#### Validate step

After PR merges, poll for deployment status (max 5 rounds, 30s apart):

```text
for round in 1..5:
    bash "$SKILL_DIR/scripts/validate.sh" --branch <default_branch>

    Parse JSON deployment field:
    found=false        → no deployments, go to Final Output
    status="success"   → go to Final Output
    status="failure"   → STOP with deployment URL
    status="in_progress" → sleep 30, continue polling
```

---

### Final Output

Print a summary (max 8 lines):

- Refactor: Pass 1 + Pass 2 + Pass 3 changes (counts), or skipped
- Commit: new or amended, with message
- PR: URL
- Auto-merge: enabled / not configured
- CI: passed (or fixed N times) / no checks
- Merge: confirmed / pending
- Deploy: succeeded / failed / no deployment detected
