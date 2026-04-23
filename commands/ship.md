---
model: sonnet
---

Ship the current branch: commit (or amend), sync with remote, push, and create/update a PR with auto-merge. Be efficient — no deliberation, just execute.

## Execute

Read config (defaults shown):

```bash
AUTO_MERGE="$(yq -r   '.ship.auto_merge // true'          .claude/config.yaml 2>/dev/null)"
MERGE_METHOD="$(yq -r '.publish.merge_method // "rebase"' .claude/config.yaml 2>/dev/null)"
```

Abort on default branch:

```bash
DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]] && { echo "on default branch — refuse to ship"; exit 1; }
```

**1. Stage & commit.** If the tree is dirty, stage everything and unstage common secret paths. If `$ARGUMENTS` was provided, use it as the commit message (must be conventional commit format). Otherwise inspect the diff and infer type/scope — do not ask.

```bash
git add -A
git reset HEAD -- '*.env' '*credentials*' '*.key' '*.pem' 2>/dev/null || true
git diff --cached --quiet || git commit -m "<conventional message>"
```

Or, if amending a previous commit:

```bash
git commit --amend --no-edit
```

**2. Rebase.**

```bash
git fetch origin
git rebase "origin/${DEFAULT_BRANCH}"
```

On conflict: `git rebase --abort`, list files from `git diff --name-only --diff-filter=U`, STOP.

**3. Push.**

```bash
git push --force-with-lease origin HEAD
```

**4. Ensure PR exists.** If `gh pr view` returns nothing, create one (truncate title to 70 chars):

```bash
gh pr view --json url,title,state 2>/dev/null \
  || gh pr create --title "<title:0..70>" --body "$(cat <<'EOF'
## Summary

<1–3 bullets describing the change>

## Test plan

- CI checks pass
EOF
)"
```

**5. Auto-merge.** Only if `AUTO_MERGE == "true"`:

```bash
gh pr merge --auto --"${MERGE_METHOD}" 2>/dev/null \
  && echo "auto-merge enabled" \
  || echo "auto-merge not configured"
```

## Output

Print a short summary (no more than 5 lines):
- Commit: new or amended, with the message
- Rebase: clean or skipped
- Push: done
- PR: URL
- Auto-merge: enabled / not configured
