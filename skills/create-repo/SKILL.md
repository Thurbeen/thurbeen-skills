---
name: create-repo
description: Create a GitHub repository from template with full configuration (merge settings + branch protection).
user-invocable: true
allowed-tools: Bash
---

## Create Repo

Create a new GitHub repository from a template and configure it
with standardized settings (rebase-only merges, branch protection
ruleset).

**Input:** `$ARGUMENTS` — repo name (required), plus optional
`--visibility`, `--description`, `--org` flags.

---

### Phase 0 — Resolve Defaults

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/create-repo/SKILL.md)")" && pwd)"
source "$SKILL_DIR/scripts/common.sh"
echo "org=$(config_get 'create-repo.default_org' '')"
echo "visibility=$(config_get 'create-repo.visibility' 'private')"
echo "template=$(config_get 'create-repo.template' 'Thurbeen/template')"
```

Parse config defaults. Overlay any explicit arguments from `$ARGUMENTS`:

- Extract repo name (first positional word)
- Extract `--visibility <public|private>` if present
- Extract `--description "<text>"` if present
- Extract `--org <org>` if present

If name is missing, STOP and ask the user.

---

### Phase 1 — Create

```bash
bash "$SKILL_DIR/scripts/create-repo.sh" \
  --name "<name>" \
  --template "<template>" \
  [--org "<org>"] \
  [--visibility "<visibility>"] \
  [--description "<description>"]
```

Parse the JSON output:
- If exit code is 2 → STOP: show `error` from JSON
- If exit code is 0 → save `repo`, `clone_path`, `url`, `visibility`

---

### Phase 2 — Configure

```bash
bash "$SKILL_DIR/scripts/configure-repo.sh" --repo "<repo>"
```

Where `<repo>` is the `owner/repo` string from Phase 1.

Parse the JSON output:
- If exit code is 2 → STOP: show `error` from JSON
- If exit code is 0 → save `ruleset_action` (created/updated)

---

### Final Output

Print a summary (max 6 lines):

- Repository: `owner/repo` (visibility)
- Template: template used
- Clone path: where the repo was cloned
- Merge: rebase only, auto-merge enabled, delete branch on merge
- Ruleset: protect-default-branch (created/updated)
- URL: link to the repository
