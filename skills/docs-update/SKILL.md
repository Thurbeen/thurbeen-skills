---
name: docs-update
description: Review the pending diff on the current branch for documentation drift (README, docs/, CHANGELOG, docstrings, inline comments, config examples) and apply updates. Runs on the current repo by default; pass "all" to fan out across every accessible repo with pending changes. Stops before commit; pair with /publish to ship.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent
---

## Docs Update

Review the pending diff on the current branch for documentation that
no longer matches the code, and apply updates. Does **not** commit or
push — pair with `/publish` afterward to ship.

**Input:** `$ARGUMENTS` optionally narrows scope (e.g. a path or
target like "README only"). Default: review everything pending in
the current repo.

**Multi-repo mode:** if `$ARGUMENTS` contains the token `all` (e.g.
`all`, `all README only`), run across every accessible repo with
pending changes. See Phase -1 below. Any remaining tokens after
removing `all` become the per-repo scope hint.

### Scope

Focused on drift introduced by what's in the diff. In-scope:

- README and top-level guides: features, install/usage, CLI flags,
  env vars, required versions.
- `docs/` tree: API references, how-tos, tutorials, examples whose
  code snippets must still run.
- CHANGELOG / release notes: unreleased-section entries for user-
  visible changes.
- Docstrings and module headers on functions/classes/files touched
  by the diff — signatures, parameters, return types, raised errors.
- Inline comments that describe behavior the diff changed.
- Config examples: `.claude/config.yaml`, `.env.example`, sample
  JSON/YAML when schemas changed.
- Cross-references: links, anchors, and code-line citations that
  break when files move or symbols rename.

Out of scope: stylistic rewrites, grammar polish, or adding docs
for code the diff did not touch. Do **not** invent documentation
for behavior that isn't actually implemented.

### Setup

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/docs-update/SKILL.md)")" && pwd)"
```

Read optional overrides from `.claude/config.yaml`:

- `docs-update.exclude_paths` — glob list (vendored/generated docs).
- `docs-update.changelog_path` — path to CHANGELOG (default
  `CHANGELOG.md` if present; skip if absent).
- `docs-update.skip_docstrings` — `true` to leave in-code docstrings
  alone (default `false`).

---

### Phase -1 — Detect Repos (multi-repo mode only)

Skip this phase unless `$ARGUMENTS` contains `all`.

Use the Agent tool to discover all git repositories with pending
changes across directories this session is allowed to access.

Spawn an agent with the following task:

> List the directories this Claude Code session is allowed to
> access. For each allowed directory, check whether it is a git
> repository (has a `.git` directory) or contains git repos one
> level deep.
>
> A repo has pending changes if it is on a feature branch (not the
> default branch) AND has either uncommitted changes or commits
> ahead of the default branch.
>
> For each such repo, report: path (absolute), name, current
> branch, default branch.
>
> Skip repos on their default branch with no changes.

If no repos have pending changes → STOP: "No repos with pending
changes found."

For each detected repo, `cd "<repo.path>"` and execute Phases 0–5
sequentially. Collect per-repo results and emit a combined summary
at the end (one block per repo, same shape as Phase 5).

---

### Phase 0 — Pre-flight

```bash
bash "$SKILL_DIR/scripts/preflight.sh"
```

Parse JSON. If exit code 2 → STOP: report `error`. Save
`default_branch` and `current_branch`.

---

### Phase 1 — Collect Diff

```bash
bash "$SKILL_DIR/scripts/collect-diff.sh"
```

Parse JSON. Save `diff_file`, `changed_files`, `line_count`,
`doc_files`.

If `line_count` is 0 → STOP: "No pending changes to review."

If every changed file is itself a doc (no code changes) → STOP: "No
code changes that could have caused doc drift."

---

### Phase 2 — Drift Review

Spawn **one Agent** (subagent_type: `Explore`, thoroughness `medium`)
with a self-contained prompt. The agent has not seen this session.

Prompt it with:

- The absolute path to `diff_file`, the list of `changed_files`, and
  the list of existing `doc_files` in the repo.
- The in-scope categories listed above, verbatim.
- The explicit non-goals (no stylistic rewrites; do not document
  code the diff didn't touch; do not invent behavior).
- The request: read the diff, then read the candidate docs and any
  surrounding code needed to judge whether each doc still matches
  reality. Return findings as a single JSON array. Each finding:
  ```
  {
    "severity": "high|medium|low",
    "category": "readme|docs|changelog|docstring|comment|config|xref",
    "file": "<doc path to edit (or code path for docstrings/comments)>",
    "line": <int or null>,
    "title": "<short>",
    "drift": "<what the doc currently says vs. what the code now does, 1-3 sentences>",
    "fix": "<concrete suggested edit — quote the new text when short>",
    "confidence": "high|medium|low"
  }
  ```
- Severity guide: `high` = user-facing instructions now wrong
  (install/usage/flags); `medium` = API reference or docstring
  stale; `low` = cross-reference or example nit.
- Tell the agent to return `[]` if nothing is drifting and to keep
  its prose wrapper under 100 words — the JSON is what matters.

---

### Phase 3 — Triage

Group findings by severity (high → low). For each, decide:

- **fix** — doc clearly contradicts code; correct text is obvious.
- **skip (false positive)** — doc is actually still accurate;
  explain briefly.
- **defer (needs user)** — requires a product decision (what to
  name a feature, which flag to recommend, whether to announce).

Present the grouped findings to the user as a brief summary before
editing. If any finding would remove or substantially rewrite a
user-facing section, ask via AskUserQuestion first.

---

### Phase 4 — Fix

For each finding marked **fix**:

1. Read the target file.
2. Apply the minimum change that resolves the drift via the Edit
   tool. Preserve surrounding tone, heading levels, and formatting.
   Do not bundle unrelated edits.
3. For CHANGELOG entries, append under the Unreleased section using
   the repo's existing entry style; do not invent a new format.
4. If the correct wording depends on a product decision, mark it
   **defer** instead and surface it to the user.

After edits, re-run on just the touched files:

```bash
bash "$SKILL_DIR/scripts/collect-diff.sh" <file1> <file2> ...
```

Spawn a second Agent (same prompt shape) scoped to the new diff to
confirm (a) the original drift items are resolved and (b) no new
drift was introduced (e.g., an edited README now contradicts a
sibling doc). If new issues appear, loop once through Phase 3–4;
beyond that, defer to the user.

---

### Phase 5 — Report

Emit a concise summary:

- Findings by severity (count).
- Edits applied (file:line, title).
- Items deferred / skipped, with reason.
- Next step suggestion: run `/publish` to commit and ship.

Do **not** run `git commit` or `git push`. Leave the tree dirty for
the user or `/publish` to pick up.
