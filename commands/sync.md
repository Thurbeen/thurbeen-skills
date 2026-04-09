---
model: haiku
---

Sync the current branch with the remote default branch. Be efficient — do not deliberate, just execute.

## Execute

Resolve the publish skill directory:

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/publish/SKILL.md)")" && pwd)"
```

Run the preflight script:

```bash
bash "$SKILL_DIR/preflight.sh"
```

Parse the JSON output:
- `rebase: "clean"` → success
- `rebase: "conflict"` → STOP: show `conflict_files`, ask user how to proceed

## Output

Print one line: `Rebased on origin/<default_branch> — up to date.` or the conflict details.
