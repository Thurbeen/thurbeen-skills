---
name: orchestrate
description: Decompose a goal into subtasks, spawn thurbox worker sessions in parallel, poll their sentinel-terminated outputs, review PRs, and aggregate results. Supports bd-backed state tracking (default-on when .beads/ present) and a worker-review step before merge.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

## Orchestrate

Run a goal as a **supervisor / orchestrator-worker** workflow: this
session (the lead) decomposes the goal, spawns sibling thurbox sessions
as workers via MCP or CLI, polls their output for a result sentinel,
reviews PRs when present, and aggregates.

You (the lead) hold the plan in your own context window. Workers are
ephemeral and isolated — they receive one focused prompt, run to
completion, emit a sentinel with a JSON result, and idle. No shared
files, no shared git branches, no pub/sub bus.

**Input:** `$ARGUMENTS` is the high-level goal. Pre-existing bead IDs may
be included (e.g. `goal text [bd:admin-1a,admin-2b]`) — parse them out
and assign them to tasks during Phase 1.

### Required tools

**Thurbox MCP** (preferred):
`create_session`, `send_prompt`, `capture_session_output`, `get_session`,
`delete_session`.

**thurbox-cli** (graceful fallback — transparent to the user):
`thurbox-cli session list/get/create/send/capture/delete`.
Use the CLI when MCP is unavailable or when a tool call returns an error
mid-run (MCP can disconnect; the CLI is always present). See
[Known quirks](#known-thurbox-quirks) for the id-reconciliation step
required after every session creation.

**bd** (default-on):
```bash
BD_STATE=$(bash "$SKILL_DIR/scripts/bd-helpers.sh" detect)
# BD_STATE = "enabled" or "disabled"
```
Enabled when `.beads/` exists in cwd or any ancestor. When enabled, all
phase transitions, notes, and closures are recorded in bd. If `BD_MODE`
config is `off`, skip bd unconditionally.

If any **required** MCP tool and its CLI fallback are both missing, STOP
and tell the user.

### Setup

Resolve the skill directory:

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/orchestrate/SKILL.md)")" && pwd)"
```

Read config defaults (from the current working directory):

```bash
source "$SKILL_DIR/scripts/common.sh"
MAX_TASKS=$(config_get      "orchestrate.max_tasks"            "6")
MAX_PARALLEL=$(config_get   "orchestrate.max_parallel"         "3")
TIMEOUT_MIN=$(config_get    "orchestrate.task_timeout_minutes" "30")
WORKER_ROLE=$(config_get    "orchestrate.worker_role"          "developer")
WORKER_SKILLS=$(config_get  "orchestrate.worker_skills"        "publish,bump-pr-fixer,docs-update")
AUTO_CLEANUP=$(config_get   "orchestrate.auto_cleanup"         "true")
BASE_BRANCH=$(config_get    "orchestrate.base_branch"          "main")
BD_MODE=$(config_get        "orchestrate.bd"                   "auto")
REVIEW_MODE=$(config_get    "orchestrate.review"               "on")
BD_STATE="disabled"
if [[ "$BD_MODE" != "off" ]]; then
  BD_STATE=$(bash "$SKILL_DIR/scripts/bd-helpers.sh" detect)
fi
```

---

### Phase 1 — Decompose

From `$ARGUMENTS`, produce an internal plan: an ordered list of subtasks,
each with:

- `id` — short slug, unique within the run (e.g. `setup-db`)
- `bead_id` — pre-assigned if the user passed it in `$ARGUMENTS`; otherwise
  left blank and filled in during Phase 2.
- `title` — one line
- `repo_path` — absolute path; defaults to cwd
- `worktree_branch` — `tb/<bead_id>-<slug>` (finalized in Phase 2 once
  bead_id is known; use a placeholder like `tb/pending-<slug>` until then)
- `prompt` — self-contained instructions for a worker that will not see
  this conversation
- `acceptance` — how the worker knows it's done
- `depends_on` — list of task ids that must complete first
- `expected_artifact` — what "done" produces (a commit, a file, a URL, a
  test result)
- `skills` — comma-separated skill names to pass as `--skill` flags;
  defaults to `WORKER_SKILLS`

**Session name rules** (hard constraint — see quirk `admin-jmb`):
Use hyphenated title-case with no spaces, ≤ 64 chars.
`orchestrate-<slug>` is a safe pattern. **Hard-fail** if any computed name
contains whitespace.

Hard limits:
- Total tasks ≤ `MAX_TASKS`. Group related steps rather than exceed the
  limit.
- No cyclic dependencies.
- Each task's `prompt` must stand alone.

---

### Phase 2 — Confirm & materialize bd issues

Present the plan to the user with `AskUserQuestion`, offering: `approve`,
`edit`, `cancel`.

- `cancel` → STOP.
- `edit` → revise and re-present until approved.

After approval, if `BD_STATE = "enabled"`:

1. For each task with no `bead_id`, create a bead:
   ```bash
   BEAD_ID=$(bash "$SKILL_DIR/scripts/bd-helpers.sh" create \
     --title "<task.title>" \
     --priority "medium" \
     --type "task" \
     --description "<task.prompt first 120 chars>")
   ```
   Store `bead_id` on the task.

2. Finalize `worktree_branch` → `tb/<bead_id>-<slug>`.

3. Wire dependencies:
   ```bash
   bash "$SKILL_DIR/scripts/bd-helpers.sh" dep \
     --issue "<dependency_bead_id>" --blocks "<task_bead_id>"
   ```

---

### Phase 3 — Dispatch wave

Repeat until every task has terminal state (`done` or `failed`):

1. Compute the **ready set**: tasks whose status is `pending` and whose
   `depends_on` are all `done`.
2. From the ready set, dispatch up to `MAX_PARALLEL − in_flight` tasks.
   For each task:

   a. If `BD_STATE = "enabled"`:
      ```bash
      bash "$SKILL_DIR/scripts/bd-helpers.sh" start --issue "<task.bead_id>"
      ```

   b. Render the worker prompt:
      ```bash
      bash "$SKILL_DIR/scripts/render-worker-prompt.sh" \
        --title "<task.title>" \
        --prompt "<task.prompt>" \
        --acceptance "<task.acceptance>" \
        --bead "<task.bead_id>" \
        --branch "<task.worktree_branch>"
      ```

   c. Compute the session name (no spaces, ≤ 64 chars). Example:
      `orchestrate-<task.id>`.
      ```bash
      [[ "$SESSION_NAME" =~ [[:space:]] ]] && { log "FATAL: session name contains whitespace"; exit 2; }
      ```

   d. Spawn the session via `scripts/session-create.sh`:
      ```bash
      SESSION_UUID=$(bash "$SKILL_DIR/scripts/session-create.sh" \
        --name "$SESSION_NAME" \
        --repo-path "<task.repo_path>" \
        --worktree-branch "<task.worktree_branch>" \
        --base-branch "$BASE_BRANCH" \
        --role "$WORKER_ROLE" \
        --skills "<task.skills>")
      ```
      `session-create.sh` prefers MCP `create_session` and falls back to
      the CLI automatically (see script). It always prints the authoritative
      UUID on stdout after reconciliation.

   e. Send the rendered prompt via MCP `send_prompt`; on failure retry up
      to 3× with 2 s backoff. If still failing, mark task `failed`.

   f. Record: `session_uuid`, `started_at`, `status = running`.

3. Proceed to **Phase 4** for in-flight workers.

---

### Phase 4 — Poll

Use `schedule_command` to wake roughly every 30 s, or loop with small
sleeps. In each tick, for every `running` task:

1. Call `get_session` on the `session_uuid`. If status is `Busy`, skip
   this tick — do **not** call `capture_session_output` on a Busy session.
2. When status is `Idle` or `Waiting`, call `capture_session_output`.
3. Pipe to parser:
   ```bash
   printf '%s' "<captured-output>" \
     | bash "$SKILL_DIR/scripts/parse-result.sh"
   ```
   Exit codes:
   - `0` → JSON on stdout. Parse `status` ∈ {`ok`, `error`},
     `artifact`, `notes`, and optional `pr_url`, `bd_id`. Mark task
     `done` (ok) or `failed` (error). Record result.
   - `1` → no sentinel yet; leave `running`.
   - `2` → sentinel present but malformed. Mark `failed` with
     `notes = "malformed result JSON"`.
4. If a task has been `running` longer than `TIMEOUT_MIN` minutes, mark
   `failed` with `notes = "timeout"` and capture last output.

Exit phase when all in-flight tasks have settled, then loop back to
**Phase 3** to dispatch the next wave.

---

### Phase 5 — Review & notify

When a task enters `done` and has a `pr_url` and `REVIEW_MODE = "on"`:

1. Fetch the diff:
   ```bash
   gh pr diff "<pr_url>"
   ```
2. Compare the diff against the task's `prompt` and `acceptance`.
   Flag any of: scope creep, unrelated files changed, missing tests,
   acceptance criteria not met.
3. Present findings to the user via `AskUserQuestion`:
   - `merge` — looks good, proceed.
   - `request-changes` — leave PR open; note issues; do not auto-close bd.
   - `skip-review` — skip this PR's review.
   - `abort` — stop the run; keep completed artifacts.
4. If `BD_STATE = "enabled"`, record the decision:
   ```bash
   bash "$SKILL_DIR/scripts/bd-helpers.sh" note \
     --issue "<task.bead_id>" \
     --message "review: <merge|request-changes|skip-review|abort>"
   ```

---

### Phase 6 — Handle failures

Any time a task enters `failed`, pause before dispatching dependents and
prompt the user via `AskUserQuestion`:

- `retry` — reset to `pending` and dispatch again.
- `skip` — leave `failed`; cascade `failed` with
  `notes = "dependency <id> failed"` to downstream tasks.
- `abort` — stop the run; keep completed artifacts.

If `BD_STATE = "enabled"`, note the failure:
```bash
bash "$SKILL_DIR/scripts/bd-helpers.sh" note \
  --issue "<task.bead_id>" \
  --message "failed: <diagnosis>"
```

Do not cascade failures silently.

---

### Phase 7 — Aggregate & cleanup

When every task is terminal:

1. If `AUTO_CLEANUP = "true"`, call `delete_session` on every worker whose
   task ended `done`. Leave `failed` workers alive for inspection.
2. If `BD_STATE = "enabled"`, close done beads that have a `pr_url`:
   ```bash
   bash "$SKILL_DIR/scripts/bd-helpers.sh" close \
     --issue "<task.bead_id>" \
     --message "PR <pr_url> merged"
   ```
   Leave `failed` beads open.
3. Print a summary table:

   ```
   ## Orchestration summary

   Goal: <goal>
   Tasks: N done, M failed, K skipped

   - <id> — <title>
     status: done | failed | skipped
     bd: <bead_id>          (if bd enabled)
     session: <uuid>  (cleaned up | alive)
     artifact: <value>
     PR: <pr_url>           (if present)
     notes: <one line>
   ```

4. If any task failed, list remediation options (inspect worker, rerun with
   narrower goal, fix manually).

---

### Worker contract (reference)

Every worker receives the template at `templates/worker-init.md`. The
sentinel format is:

```
===RESULT===
{"status":"ok","artifact":"<value>","notes":"<short summary>","pr_url":"<optional>","bd_id":"<optional>"}
```

Workers are told not to spawn sub-workers and not to wait for follow-ups.
The sentinel is the entire coordination protocol.

---

### Config keys (`.claude/config.yaml`)

```yaml
orchestrate:
  max_tasks: 6                                      # hard cap on decomposition
  max_parallel: 3                                   # max concurrent workers
  task_timeout_minutes: 30                          # per-task wall clock
  worker_role: developer                            # thurbox role for workers (developer = auto-permission mode)
  worker_skills: "publish,bump-pr-fixer,docs-update"
  auto_cleanup: true                                # delete_session on done workers
  base_branch: main                                 # base branch for worktrees
  bd: auto                                          # auto|on|off — auto detects .beads/
  review: on                                        # on|off — PR review step
```

---

### Known thurbox quirks

**`admin-7xp` — CLI↔MCP session id mismatch**

`thurbox-cli session create` and MCP `create_session` may return
different UUIDs for the same session. Always reconcile: after creating a
session by any means, call `thurbox-cli session list`, find the latest
entry matching the session name, and use that UUID as the authoritative id.
`scripts/session-create.sh` handles this transparently.

**`admin-jmb` — session names must be hyphenated, no spaces**

Thurbox rejects session names containing whitespace. The skill
hard-fails before calling any API if the computed name contains a space.
Use the pattern `orchestrate-<slug>` and ensure slugs contain only
`[a-z0-9-]`.

**MCP instability → CLI fallback**

MCP can disconnect mid-run. `session-create.sh` falls back to the CLI
silently; the UUID reconciliation step ensures the id is correct
regardless of which path was taken. Callers see one UUID and need not
know which path succeeded.

**Pre-PR-269 `-vN` name suffix workaround — no longer required**

Earlier versions of this skill appended `-v1`, `-v2` suffixes to session
names to work around a duplicate-name rejection bug. That bug was fixed in
PR-269. Do **not** add version suffixes.

---

### Limitations

- No sub-worker spawning (flat hierarchy only).
- Plan state lives in the lead's context. If the lead session dies,
  workers keep running but the plan is lost — resume requires re-invoking
  with a narrower goal. When bd is enabled, bead state survives and can
  be used to reconstruct progress.
- Single-repo per run; for multi-repo fan-out, use `publish`.
