---
name: orchestrate
description: Decompose a goal into subtasks, spawn thurbox worker sessions in parallel, poll their sentinel-terminated outputs, and aggregate results. Pure supervisor pattern — no shared store, no git coordination.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

## Orchestrate

Run a goal as a **supervisor / orchestrator-worker** workflow: this
session (the lead) decomposes the goal, spawns sibling thurbox
sessions as workers via MCP, polls their output for a result
sentinel, and aggregates.

You (the lead) hold the plan in your own context window. Workers
are ephemeral and isolated — they receive one focused prompt,
run to completion, emit a sentinel with a JSON result, and idle.
No shared files, no git branches, no pub/sub bus.

**Input:** `$ARGUMENTS` is the high-level goal.

**Required MCP:** the active thurbox MCP server must expose
`create_session`, `send_prompt`, `capture_session_output`, and
`delete_session`. `schedule_command` is used for paced polling
when available but optional. If any required tool is missing,
STOP and tell the user.

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
WORKER_ROLE=$(config_get    "orchestrate.worker_role"          "worker")
AUTO_CLEANUP=$(config_get   "orchestrate.auto_cleanup"         "false")
```

---

### Phase 1 — Decompose

From `$ARGUMENTS`, produce an internal plan: an ordered list of
subtasks, each with:

- `id` — short slug, unique within the run
- `title` — one line
- `prompt` — self-contained instructions for a worker that will
  not see this conversation
- `acceptance` — how the worker knows it's done
- `depends_on` — list of task ids that must complete first
- `expected_artifact` — what "done" produces (a commit, a file,
  a URL, a test result)

Hard limits:

- Total tasks must be ≤ `MAX_TASKS`. If the goal naturally
  decomposes into more, group related steps into a single task
  rather than exceeding the limit.
- Avoid cyclic dependencies.
- Each task's `prompt` must stand alone — assume the worker has
  no memory of this conversation.

---

### Phase 2 — Confirm

Present the plan to the user with `AskUserQuestion`, offering:
`approve`, `edit` (user revises the decomposition), `cancel`.

If `cancel` → STOP.
If `edit` → revise and re-present until approved.

---

### Phase 3 — Dispatch wave

Repeat until every task has terminal state (`done` or `failed`):

1. Compute the **ready set**: tasks whose status is `pending` and
   whose `depends_on` are all `done`.
2. From the ready set, dispatch up to `MAX_PARALLEL − in_flight`
   tasks. For each:
   - Render the worker prompt:

     ```bash
     bash "$SKILL_DIR/scripts/render-worker-prompt.sh" \
       --title "<task.title>" \
       --prompt "<task.prompt>" \
       --acceptance "<task.acceptance>"
     ```

   - Call thurbox MCP `create_session` with:
     - worktree isolation (so workers don't step on each other)
     - `role` = `WORKER_ROLE`
     - a descriptive name like `orchestrate/<task.id>`
   - Call `send_prompt` with the rendered prompt on the returned
     session UUID. If it fails, retry up to 3× with 2s backoff;
     if still failing, mark the task `failed` and continue.
   - Record: `session_uuid`, `started_at`, `status = running`.
3. Proceed to **Phase 4 — Poll** for the in-flight workers.

---

### Phase 4 — Poll

Use `schedule_command` to wake yourself roughly every 30s, or
loop with small sleeps if `schedule_command` is unavailable. In
each tick, for every `running` task:

1. Call `capture_session_output` on its `session_uuid`.
2. Pipe to parser:

   ```bash
   printf '%s' "<captured-output>" \
     | bash "$SKILL_DIR/scripts/parse-result.sh"
   ```

   Exit codes:
   - `0` → JSON on stdout. Parse `status` ∈ {`ok`, `error`} and
     `artifact`, `notes`. Mark the task `done` (if ok) or
     `failed` (if error). Record the result.
   - `1` → no sentinel yet; leave `running`.
   - `2` → sentinel present but malformed. Mark `failed` with
     `notes = "malformed result JSON"`.
3. If a task has been `running` longer than `TIMEOUT_MIN` minutes,
   mark it `failed` with `notes = "timeout"` and capture the last
   output for diagnostics.

Exit this phase when all in-flight tasks have settled, then loop
back to **Phase 3** to dispatch the next wave.

---

### Phase 5 — Handle failures

Any time a task enters `failed`, pause before dispatching
dependents-of-others and prompt the user via `AskUserQuestion`:

- `retry` — reset the task to `pending` and dispatch again.
- `skip` — leave it `failed`; any tasks that depended on it
  cascade to `failed` with `notes = "dependency <id> failed"`.
- `abort` — stop the run; keep any completed artifacts.

Do not cascade failures silently.

---

### Phase 6 — Aggregate

When every task is terminal:

1. If `AUTO_CLEANUP = "true"`, call `delete_session` on every
   worker whose task ended `done`. Leave `failed` workers alive
   so the user can inspect their state.
2. Print a summary table:

   ```
   ## Orchestration summary

   Goal: <goal>
   Tasks: N done, M failed, K skipped

   - <id> — <title>
     status: done | failed | skipped
     session: <uuid>  (cleaned up | alive)
     artifact: <value>
     notes: <one line>
   ```

3. If any task failed, list remediation options the user could
   take (inspect a worker, rerun the skill with a narrower goal,
   fix manually).

---

### Worker contract (reference)

Every worker is sent this contract verbatim via the template at
`templates/worker-init.md`. The sentinel format is:

```
===RESULT===
{"status":"ok","artifact":"<value>","notes":"<short summary>"}
```

Workers are told not to spawn sub-workers and not to wait for
follow-ups. The sentinel is the entire coordination protocol.

---

### Config keys (`.claude/config.yaml`)

```yaml
orchestrate:
  max_tasks: 6              # hard cap on decomposition
  max_parallel: 3           # max concurrent workers
  task_timeout_minutes: 30  # per-task wall clock
  worker_role: worker       # thurbox role applied to workers
  auto_cleanup: false       # delete_session on done workers
```

---

### Limitations (v1)

- No sub-worker spawning (flat hierarchy only).
- Plan state lives in the lead's context. If the lead session
  dies, workers keep running but the plan is lost — resume
  requires re-invoking with a narrower goal. If this bites,
  graduate to a JSON blackboard.
- Single-repo per run; for multi-repo fan-out, use `publish`.
