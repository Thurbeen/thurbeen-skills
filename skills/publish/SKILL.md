---
name: publish
description: Refactor and test recent changes across all repos with publishable changes, ship PRs with auto-merge, then monitor CI and auto-fix failures until merged.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, WebFetch, Skill
---

## Publish

Refactor recent changes, ship them as PRs with auto-merge, then watch CI
until each PR merges (or hard-stops). Operates on every git repo with
publishable changes that this session can reach.

**Do not stop mid-flow.** Phases 1–4 run to completion for every repo
detected in Phase 0. Sub-commands like `/refactor` produce their own
summaries — those are intermediate, never terminal. The only terminal
output is the Final Output section at the end.

**Input:** `$ARGUMENTS` optionally describes what was done (used for the
commit message and PR description).

The only shell helper this skill calls is `ship.sh`, which performs the
atomic commit → rebase → push → PR → auto-merge sequence (also reused by
the `bump-pr-fixer` and `infra-monitor` skills). Resolve it once:

```bash
SHIP="$(cd "$(dirname "$(readlink -f ~/.claude/skills/publish/SKILL.md)")" && pwd)/scripts/ship.sh"
```

Everything else is plain `git` / `gh` / `yq` invocations Claude runs
directly through Bash.

---

### Phase 0 — Detect repos

Use the Agent tool to discover every git repo with publishable changes
across the directories this session is allowed to access.

> List the directories this Claude Code session is allowed to access. For
> each one, check whether it is a git repo (has a `.git` directory) or
> contains git repos one level deep.
>
> A repo has publishable changes if it is on a feature branch (not the
> default branch) AND has either uncommitted changes or commits ahead of
> the default branch.
>
> For each publishable repo, report: absolute path, directory basename,
> current branch, default branch, commits ahead, uncommitted-changes flag.
> Skip repos on their default branch with no changes.

If no repos qualify → STOP: "No repos with publishable changes found."

For each repo in the list, `cd` into its path and run Phases 1–4
**sequentially**.

---

### Phase 1 — Refactor (per repo)

Skip if the repo's `.claude/config.yaml` sets `publish.skip_refactor: true`:

```bash
[[ "$(yq -r '.publish.skip_refactor // false' .claude/config.yaml 2>/dev/null)" == "true" ]] \
  && echo "skip refactor" || echo "run refactor"
```

Otherwise run `/refactor` to perform the full 3-pass cycle (structure,
coherence, tests).

**`/refactor` ends with its own "Final Summary".** That summary is NOT
the end of publish. Do not stop, do not ask the user to confirm, do not
wait. As soon as `/refactor` returns, immediately proceed to Phase 2.

---

### Phase 2 — Ship (per repo)

**Entry reminder:** if you just finished Phase 1, continue here without
pausing. The publish flow is not done until Phase 3 records a result for
every repo from Phase 0.

Craft a conventional-commit message. If `$ARGUMENTS` was provided and
there is only one repo, use it. For multi-repo runs, infer type and
scope from each repo's diff independently.

```bash
"$SHIP" --message "<conventional commit message>"
```

Parse the JSON output:
- `rebase: "conflict"` → record the conflict, skip remaining phases for
  this repo, continue with next repo.
- `error` → record, skip, continue.
- Otherwise save `pr.url` and `default_branch` for Phase 3.

---

### Phase 3 — Monitor & validate (per repo)

After shipping, watch the PR until it merges or hits a hard stop.

Detect capabilities once:

```bash
gh pr checks --json name,state 2>/dev/null
gh pr view --json autoMergeRequest 2>/dev/null
```

- No checks **and** no auto-merge → record "no monitoring", move on.
- No checks **but** auto-merge enabled → wait for merge only.

Read limits from per-repo config (defaults shown):

```bash
MAX_ROUNDS="$(yq -r '.publish.monitor_rounds // 10' .claude/config.yaml 2>/dev/null)"
MAX_FIXES="$(yq -r  '.publish.max_fix_attempts // 3' .claude/config.yaml 2>/dev/null)"
```

#### Monitor loop

```text
fix_count = 0
wait_s = 30
for round in 1..MAX_ROUNDS:
    sleep wait_s
    wait_s = min(wait_s * 1.5, 120)

    pr      = gh pr view   --json state,mergeStateStatus,mergeable
    checks  = gh pr checks --json name,state,conclusion,detailsUrl

    if pr.state == "MERGED":  → validate (below), then next repo
    if pr.state == "CLOSED":  → record "PR closed", next repo
    if pr.mergeable == "CONFLICTING":
                              → record "merge conflicts — rebase manually", next repo

    failed = [c for c in checks if c.conclusion in {"FAILURE","failure"}]
    if failed: → fix step
    else:      → continue loop  (some still running, or all green awaiting merge)
```

#### Fix step

```text
if fix_count >= MAX_FIXES:
    record "CI still failing after N attempts; manual intervention required"
    next repo

fix_count += 1
for c in failed:
    run_id = trailing path segment of c.detailsUrl
    gh run view <run_id> --log-failed
    diagnose root cause and apply fixes (Edit/Write)

"$SHIP" --message "fix: resolve CI failure"
wait_s = 30
continue monitor loop
```

#### Validate step (after merge)

Poll deployment workflows on the default branch (max 5 rounds, 30s
apart). Default branch came from Phase 2's ship JSON — fall back to
`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.

```bash
gh run list --branch "<default_branch>" --limit 5 \
  --json name,status,conclusion,url
```

Decide per round:
- empty list                       → record "no deployment detected", done
- any `conclusion == "failure"`    → record failure + URL, done
- top run `status == "in_progress"` or `"queued"` → sleep 30, poll again
- top run `conclusion == "success"` → record success, done

---

### Final Output

One block per repo (≤4 lines):

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
