---
name: code-security
description: Review the pending diff on the current branch for security issues (injection, authz, secrets, crypto misuse, SSRF, XSS, etc.) and apply fixes. Stops before commit; pair with /publish to ship.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent
---

## Code Security

Review the pending diff on the current branch for security
vulnerabilities and apply fixes. Does **not** commit or push — pair
with `/publish` afterward to ship.

**Input:** `$ARGUMENTS` optionally narrows scope (e.g. a path or
category like "authz only"). Default: review everything pending.

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

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/code-security/SKILL.md)")" && pwd)"
```

Read optional overrides from `.claude/config.yaml`:

- `code-security.exclude_paths` — glob list (vendored/generated code).
- `code-security.severity_floor` — min severity to surface (default
  `low`). One of: `info|low|medium|high|critical`.
- `code-security.auto_fix_max_severity` — severities fixed without
  asking (default `medium`; `high`/`critical` always prompt).

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

Parse JSON. Save `diff_file`, `changed_files`, `line_count`.

If `line_count` is 0 → STOP: "No pending changes to review."

If `changed_files` is entirely under `exclude_paths` → STOP.

---

### Phase 2 — Security Review

Spawn **one Agent** (subagent_type: `Explore`, thoroughness `medium`)
with a self-contained prompt. The agent has not seen this session.

Prompt it with:

- The absolute path to `diff_file` and the list of `changed_files`.
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
    "explanation": "<why this is exploitable, 1-3 sentences>",
    "fix": "<concrete suggested change>",
    "confidence": "high|medium|low"
  }
  ```
- Tell the agent to return `[]` if nothing is found and to keep its
  prose wrapper under 100 words — the JSON is what matters.

Parse the findings array. Drop findings whose severity is below
`severity_floor`.

---

### Phase 3 — Triage

Group findings by severity (critical → info). For each, decide:

- **fix** — clear, local, exploit path obvious.
- **skip (false positive)** — explain to the user why.
- **defer (needs user)** — ambiguous, architectural, or requires
  domain knowledge.

For severities above `auto_fix_max_severity`, ask the user before
applying the fix (use AskUserQuestion with the finding's
title + explanation + proposed fix).

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

After edits, re-run on just the touched files:

```bash
bash "$SKILL_DIR/scripts/collect-diff.sh" <file1> <file2> ...
```

Spawn a second Agent (same prompt shape) scoped to the new diff to
confirm (a) the original issues are resolved and (b) no new findings
were introduced. If new issues appear, loop once through Phase 3–4;
beyond that, defer to the user.

---

### Phase 5 — Report

Emit a concise summary:

- Findings by severity (count).
- Fixes applied (file:line, title).
- Items deferred / skipped, with reason.
- Next step suggestion: run `/publish` to commit and ship.

Do **not** run `git commit` or `git push`. Leave the tree dirty for
the user or `/publish` to pick up.
