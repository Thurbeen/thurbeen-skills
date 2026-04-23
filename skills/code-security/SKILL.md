---
name: code-security
description: Review the pending diff on the current branch for security issues (injection, authz, secrets, crypto misuse, SSRF, XSS, etc.) and apply fixes. Runs on the current repo by default; pass "all" to fan out across every accessible repo with pending changes. Stops before commit; pair with /publish to ship.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent
---

## Code Security

Review the pending diff on the current branch for security
vulnerabilities and apply fixes. Does **not** commit or push — pair
with `/publish` afterward to ship.

**Input:** `$ARGUMENTS` optionally narrows scope (e.g. a path or
category like "authz only"). Default: review everything pending in
the current repo.

**Multi-repo mode:** if `$ARGUMENTS` contains the token `all` (e.g.
`all`, `all authz only`), run across every accessible repo with
pending changes. See Phase -1 below. Any remaining tokens after
removing `all` become the per-repo scope hint.

### Scope

Focused on what's in the diff. In-scope categories:

- Injection: SQL, command/shell, template, LDAP, XPath, NoSQL
- AuthN/AuthZ: missing checks, IDOR, role downgrade, session mistakes
- Secrets: API keys, tokens, passwords committed or logged
- Unsafe deserialization (pickle, `yaml.load`, Java readObject, etc.)
- SSRF, path traversal, open redirect, ZIP-slip
- XSS: reflected/stored/DOM, template auto-escape bypass
- Crypto: weak algos, static IV/nonce, `==` on secrets (non-constant-time)
- TOCTOU / race conditions in security-relevant flows
- Insecure defaults: permissive CORS, `verify=False`, `eval`, shell=True
- Dependency changes: new packages with known-bad reputation

Out of scope: performance, style, refactors unrelated to security.
Do **not** rewrite code unrelated to a finding.

### Setup

Read optional overrides from `.claude/config.yaml` (defaults shown):

```bash
EXCLUDE_PATHS="$(yq    -r '.["code-security"].exclude_paths          // [] | join(" ")' .claude/config.yaml 2>/dev/null)"
SEVERITY_FLOOR="$(yq   -r '.["code-security"].severity_floor         // "low"'           .claude/config.yaml 2>/dev/null)"
AUTO_FIX_MAX="$(yq     -r '.["code-security"].auto_fix_max_severity  // "medium"'        .claude/config.yaml 2>/dev/null)"
```

Severities: `info` < `low` < `medium` < `high` < `critical`.
`high`/`critical` always prompt before fixing.

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
Collect per-repo results and emit a combined summary at the end (one
block per repo, same shape as Phase 5).

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

Diff the working tree (including uncommitted changes) against the
default branch. Write the full diff to a temp file and list the
changed paths.

```bash
BASE="origin/${DEFAULT_BRANCH}"
git rev-parse --verify "$BASE" >/dev/null 2>&1 || BASE="$DEFAULT_BRANCH"

DIFF_FILE="$(mktemp -t code-security-diff.XXXXXX)"
git diff "$BASE" > "$DIFF_FILE"
CHANGED_FILES=( $(git diff --name-only "$BASE") )
LINE_COUNT="$(wc -l < "$DIFF_FILE" | tr -d ' ')"
```

If `LINE_COUNT` is 0 → STOP: "No pending changes to review."

If every changed file matches an entry in `EXCLUDE_PATHS` → STOP.

---

### Phase 2 — Security review

Spawn **one Agent** (`subagent_type: Explore`, thoroughness `medium`)
with a self-contained prompt. The agent has not seen this session.

Prompt it with:

- The absolute path to `DIFF_FILE` and the list of `CHANGED_FILES`.
- The in-scope categories listed above, verbatim.
- The explicit non-goals (no perf/style/refactor findings).
- The request: read the diff, then read surrounding context from the
  files as needed to judge exploitability, and return findings as a
  single JSON array. Each finding:
  ```
  {
    "severity": "critical|high|medium|low|info",
    "category": "<one of the in-scope categories>",
    "file": "<path>",
    "line": <int or null>,
    "title": "<short>",
    "explanation": "<why this is exploitable, 1–3 sentences>",
    "fix": "<concrete suggested change>",
    "confidence": "high|medium|low"
  }
  ```
- Tell the agent to return `[]` if nothing is found and to keep its
  prose wrapper under 100 words — the JSON is what matters.

Parse the findings array. Drop findings whose severity is below
`SEVERITY_FLOOR`.

---

### Phase 3 — Triage

Group findings by severity (critical → info). For each, decide:

- **fix** — clear, local, exploit path obvious.
- **skip (false positive)** — explain why.
- **defer (needs user)** — ambiguous, architectural, or requires
  domain knowledge.

For severities above `AUTO_FIX_MAX`, ask the user before applying the
fix (AskUserQuestion with the finding's title + explanation + proposed
fix).

Present the grouped findings to the user as a brief summary before
editing.

---

### Phase 4 — Fix

For each finding marked **fix**:

1. Read the target file.
2. Apply the minimum change that closes the vulnerability via the
   Edit tool. Do not bundle unrelated cleanups.
3. If the fix requires a new dependency or config change, mark it
   **defer** instead and surface it to the user.

After edits, re-diff just the touched files and re-run Phase 2 scoped
to the new diff:

```bash
DIFF_FILE="$(mktemp -t code-security-diff.XXXXXX)"
git diff "$BASE" -- <file1> <file2> ... > "$DIFF_FILE"
```

Spawn a second Agent (same prompt shape) to confirm:
(a) the original issues are resolved, and
(b) no new findings were introduced.

If new issues appear, loop once through Phase 3–4; beyond that, defer
to the user.

---

### Phase 5 — Report

Emit a concise summary:

- Findings by severity (count).
- Fixes applied (file:line, title).
- Items deferred / skipped, with reason.
- Next step suggestion: run `/publish` to commit and ship.

Do **not** run `git commit` or `git push`. Leave the tree dirty for
the user or `/publish` to pick up.
