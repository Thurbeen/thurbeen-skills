# thurbeen-skills

Centralized Claude Code skills and commands shared across all repositories. Skills are **agent-native**: each `SKILL.md` is a single instruction file that Claude executes using its built-in tools (Bash, Read, Edit, Write, Grep, Agent, Skill). No shell-script layer, no JSON IPC, no shared utility library.

Each skill is **self-contained** — copy the folder into any `.claude/skills/` and it works.

The only exception is `orchestrate`, which still ships `scripts/` for its bd-backed state tracking and session plumbing (its supervisor-pattern workflow needs them).

## Installation

```bash
git clone git@github.com:Thurbeen/thurbeen-skills.git
cd thurbeen-skills
./setup.sh
```

The installer is idempotent — safe to re-run after pulling updates. It symlinks:
- `skills/*` → `~/.claude/skills/`
- `commands/*.md` → `~/.claude/commands/`

## Structure

```
skills/
  publish/
    SKILL.md                 Refactor → ship → monitor CI → validate deploy
  bump-pr-fixer/
    SKILL.md                 Find failed Renovate PRs → diagnose → /ship
  infra-monitor/
    SKILL.md                 Collect K8s state → create GitOps fix PR
  code-security/
    SKILL.md                 Diff-scoped security review and fix
  docs-update/
    SKILL.md                 Diff-scoped doc drift review and fix
  create-repo/
    SKILL.md                 Create from template, configure, update profiles
  test-driven-development/
    SKILL.md
    testing-anti-patterns.md
  orchestrate/
    SKILL.md                 Supervisor / worker decomposition
    scripts/                 bd-helpers, session-create, result parsing
    templates/
commands/
  refactor.md                Multi-pass refactoring
  ship.md                    Commit, sync, push, create/update a PR
  sync.md                    Rebase current branch on default
scripts/
  setup-repo.sh              GitHub repo configuration
```

### Skills

| Skill | Description | User-invocable |
|-------|-------------|----------------|
| `publish` | Refactor, ship as PR with auto-merge, monitor CI | Yes |
| `create-repo` | Create a configured GitHub repo from template | Yes |
| `code-security` | Diff-scoped security review and fix | Yes |
| `docs-update` | Diff-scoped doc drift review and fix | Yes |
| `test-driven-development` | TDD workflow guidance | Yes |
| `orchestrate` | Decompose a goal into parallel worker sessions | Yes |
| `bump-pr-fixer` | Fix failing Renovate dependency PRs | No (job) |
| `infra-monitor` | Monitor K8s cluster, create GitOps fix PRs | No (job) |

### Commands

| Command | Description |
|---------|-------------|
| `/refactor` | Multi-pass refactoring of newly implemented code |
| `/ship` | Commit, sync, push, and create/update a PR |
| `/sync` | Sync the current branch with the remote default branch |

## Per-Repo Config

Skills read `.claude/config.yaml` from the current repo for overrides:

```yaml
publish:
  skip_refactor: false        # skip refactor phase
  max_fix_attempts: 3         # CI fix retry limit
  monitor_rounds: 10          # max poll rounds
  merge_method: rebase        # rebase | squash | merge

ship:
  auto_merge: true            # enable auto-merge on PR

refactor:
  passes: 3                   # number of review passes
  include_tests: true         # whether to run test pass
```

Each skill documents the keys it reads in its own `SKILL.md`. All values are optional with sensible defaults; no config file is needed for default behavior.

## Drop-in Skills

Add project-local skills by copying a skill folder into `.claude/skills/` of any repo:

```
your-repo/
  .claude/
    skills/
      my-skill/
        SKILL.md             # everything lives here
    config.yaml              # optional per-repo overrides
```

Project-local skills override global skills of the same name.

## Repository Setup

Configure a GitHub repository with standardized settings (rebase-only merges, auto-merge, branch protection):

```bash
./scripts/setup-repo.sh
```

Requires the `gh` CLI with repo admin permissions.

## License

[Apache-2.0](LICENSE)
