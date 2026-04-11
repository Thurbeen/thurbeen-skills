---
name: create-repo
description: Create a GitHub repository from template with full configuration (merge settings, branch protection, profile READMEs).
user-invocable: true
allowed-tools: Bash
---

## Create Repo

Create a new GitHub repository from a template, configure it
with standardized settings (rebase-only merges, branch protection
ruleset), and update GitHub profile READMEs with the new project.

**Input:** `$ARGUMENTS` — repo name (required), plus optional
`--visibility`, `--description`, `--org`, `--emoji` flags.

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

### Phase 3 — Update Profile READMEs

```bash
echo "skip_profiles=$(config_get 'create-repo.skip_profiles' 'false')"
```

If `skip_profiles` is `true`, skip this phase entirely.

Determine which profile repos to update based on the repo owner and
visibility from Phase 1. Extract the owner from the `repo` value
(`owner/name` → `owner`).

**If owner is `Thurbeen`:**

| Profile Repo | File | Section match | Condition |
|---|---|---|---|
| `Thurbeen/.github-private` | `profile/README.md` | `## Projects` | always |
| `Thurbeen/.github` | `profile/README.md` | `## Projects` | visibility = public |
| `LeTuR/LeTuR` | `README.md` | `Projects — [Thurbeen]` | always |

**If owner is `LeTuR`:**

| Profile Repo | File | Section match |
|---|---|---|
| `LeTuR/LeTuR` | `README.md` | `Projects — Personal` |

Pick an emoji that fits the project description. If the user provided
`--emoji` in `$ARGUMENTS`, use that instead.

Build the entry line:

```
- <emoji> [<name>](https://github.com/<repo>) — <description>
```

If no `--description` was provided, use the repo name as description.

For each profile repo that qualifies, run:

```bash
bash "$SKILL_DIR/scripts/update-profile.sh" \
  --profile-repo "<profile_repo>" \
  --file "<file>" \
  --section "<section>" \
  --entry "<entry_line>" \
  --source-repo "<repo>"
```

Parse the JSON output:
- Exit code 0 → save `pr_url` for the summary
- Exit code 1 → entry already exists, note as skipped
- Exit code 2 → warn but do not stop (profile update is non-fatal)

---

### Final Output

Print a summary:

- Repository: `owner/repo` (visibility)
- Template: template used
- Clone path: where the repo was cloned
- Merge: rebase only, auto-merge enabled, delete branch on merge
- Ruleset: protect-default-branch (created/updated)
- Profiles: list each profile repo updated (PR link) or skipped
- URL: link to the repository
