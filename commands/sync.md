---
model: haiku
---

Sync the current branch with the remote default branch. Be efficient — do not deliberate, just execute.

## Execute

```bash
DEFAULT="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
CURRENT="$(git branch --show-current)"
[[ "$CURRENT" == "$DEFAULT" ]] && { echo "On default branch ($DEFAULT) — nothing to sync."; exit 0; }
git fetch origin
git rebase "origin/$DEFAULT"
```

If the rebase fails:
- `git diff --name-only --diff-filter=U` to list conflicting files
- `git rebase --abort`
- STOP and ask the user how to proceed

## Output

One line: `Rebased <CURRENT> on origin/<DEFAULT> — up to date.` or the conflict details.
