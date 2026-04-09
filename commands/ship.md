---
model: sonnet
---

Ship the current branch: commit (or amend), sync with remote, push, and create/update a PR with auto-merge. Be efficient — no deliberation, just execute.

---

## Execute

Resolve the publish skill directory:

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/publish/SKILL.md)")" && pwd)"
```

Run the ship script. If `$ARGUMENTS` was provided, use it to craft a conventional commit message. Otherwise, first inspect the diff to infer type and scope — do not ask, just pick:

```bash
bash "$SKILL_DIR/ship.sh" --message "<conventional commit message>" --type "<type>"
```

If there are no uncommitted changes, omit `--message` and `--type` — the script will skip the commit step.

Parse the JSON output and handle:
- `rebase: "conflict"` → STOP: show conflict details
- `error` → STOP: show error

## Output

Print a short summary (no more than 5 lines) from the JSON:
- Commit: new or amended, with the message
- Rebase: clean or skipped
- Push: done
- PR: URL
- Auto-merge: enabled / not configured
