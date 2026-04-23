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

Out of scope: stylistic rewrites, grammar polish, or adding docs for
code the diff did not touch. Do **not** invent documentation for
behavior that isn't actually implemented.

### Setup

Read optional overrides from `.claude/config.yaml` (defaults shown):

```bash
EXCLUDE_PATHS="$(yq   -r '.["docs-update"].exclude_paths    // [] | join(" ")' .claude/config.yaml 2>/dev/null)"
CHANGELOG_PATH="$(yq  -r '.["docs-update"].changelog_path   // "CHANGELOG.md"' .claude/config.yaml 2>/dev/null)"
SKIP_DOCSTRINGS="$(yq -r '.["docs-update"].skip_docstrings  // false'          .claude/config.yaml 2>/dev/null)"
```

If `$CHANGELOG_PATH` does not exist in the repo, skip changelog
entries silently.

---

### Phase -1 — Detect repos (multi-repo mode only)

Skip unless `$ARGUMENTS` contains `all`.

Use the Agent tool to discover every git repo with pending changes
across the directories this session is allowed to access.

> List the directories this Claude Code session is allowed to access.
> For each, check whether it is a git repo (has a `.git` directory) or
> contains git repos one level deep.
>
> A repo has pending changes if it is on a feature branch (not the
> default branch) AND has either uncommitted changes or commits ahead
> of the default branch.
>
> For each such repo, report: absolute path, basename, current branch,
> default branch. Skip repos on their default branch with no changes.

If no repos qualify → STOP: "No repos with pending changes found."

For each repo, `cd "<repo.path>"` and execute Phases 0–5 sequentially.
Collect per-repo results and emit a combined summary at the end.

---

### Phase 0 — Pre-flight

```bash
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }

DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]] && { echo "on default branch"; exit 1; }

COMMITS_AHEAD="$(git rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"
UNCOMMITTED="$(git status --porcelain | wc -l | tr -d ' ')"
[[ "$COMMITS_AHEAD" -eq 0 && "$UNCOMMITTED" -eq 0 ]] && { echo "no pending changes"; exit 1; }
```

Save `DEFAULT_BRANCH` and `CURRENT_BRANCH` for later phases.

---

### Phase 1 — Collect diff

```bash
BASE="origin/${DEFAULT_BRANCH}"
git rev-parse --verify "$BASE" >/dev/null 2>&1 || BASE="$DEFAULT_BRANCH"

DIFF_FILE="$(mktemp -t docs-update-diff.XXXXXX)"
git diff "$BASE" > "$DIFF_FILE"
CHANGED_FILES=( $(git diff --name-only "$BASE") )
LINE_COUNT="$(wc -l < "$DIFF_FILE" | tr -d ' ')"
```

Also collect candidate docs that already exist in the repo:

```bash
DOC_FILES=( $(git ls-files 'README*' 'docs/**' 'CHANGELOG*' '*.md' 2>/dev/null | sort -u) )
```

If `LINE_COUNT` is 0 → STOP: "No pending changes to review."

If every changed file is itself a doc (no code changes) → STOP:
"No code changes that could have caused doc drift."

---

### Phase 2 — Drift review

Spawn **one Agent** (`subagent_type: Explore`, thoroughness `medium`)
with a self-contained prompt. The agent has not seen this session.

Prompt it with:

- The absolute path to `DIFF_FILE`, the list of `CHANGED_FILES`, and
  the list of existing `DOC_FILES` in the repo.
- The in-scope categories listed above, verbatim.
- The explicit non-goals (no stylistic rewrites; do not document code
  the diff didn't touch; do not invent behavior).
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
    "drift": "<what the doc currently says vs. what the code now does, 1–3 sentences>",
    "fix": "<concrete suggested edit — quote the new text when short>",
    "confidence": "high|medium|low"
  }
  ```
- Severity guide: `high` = user-facing instructions now wrong
  (install/usage/flags); `medium` = API reference or docstring stale;
  `low` = cross-reference or example nit.
- Tell the agent to return `[]` if nothing is drifting and to keep its
  prose wrapper under 100 words — the JSON is what matters.

If `SKIP_DOCSTRINGS` is `true`, drop findings where `category ==
"docstring"`.

---

### Phase 3 — Triage

Group findings by severity (high → low). For each, decide:

- **fix** — doc clearly contradicts code; correct text is obvious.
- **skip (false positive)** — doc is still accurate; explain briefly.
- **defer (needs user)** — requires a product decision (what to name a
  feature, which flag to recommend, whether to announce).

Present the grouped findings to the user as a brief summary before
editing. If any finding would remove or substantially rewrite a
user-facing section, ask via AskUserQuestion first.

---

### Phase 4 — Fix

For each finding marked **fix**:

1. Read the target file.
2. Apply the minimum change that resolves the drift via the Edit tool.
   Preserve surrounding tone, heading levels, and formatting. Do not
   bundle unrelated edits.
3. For CHANGELOG entries, append under the Unreleased section using
   the repo's existing entry style; do not invent a new format.
4. If the correct wording depends on a product decision, mark it
   **defer** instead and surface it to the user.

After edits, re-diff just the touched files and re-run Phase 2 scoped
to the new diff:

```bash
DIFF_FILE="$(mktemp -t docs-update-diff.XXXXXX)"
git diff "$BASE" -- <file1> <file2> ... > "$DIFF_FILE"
```

Spawn a second Agent (same prompt shape) to confirm:
(a) the original drift items are resolved, and
(b) no new drift was introduced (e.g., an edited README now
    contradicts a sibling doc).

If new issues appear, loop once through Phase 3–4; beyond that, defer
to the user.

---

### Phase 5 — Report

Emit a concise summary:

- Findings by severity (count).
- Edits applied (file:line, title).
- Items deferred / skipped, with reason.
- Next step suggestion: run `/publish` to commit and ship.

Do **not** run `git commit` or `git push`. Leave the tree dirty for
the user or `/publish` to pick up.
