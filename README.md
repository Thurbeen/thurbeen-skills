# thurbeen-skills

Centralized Claude Code skills and commands shared across all repositories.
Each `SKILL.md` is a set of instructions Claude follows directly through its
native tools (Bash, Edit, Read, Agent, …); shell scripts are reserved for
the few routines that genuinely benefit from being atomic or are reused by
non-Claude callers (e.g. `publish/scripts/ship.sh`, used by `bump-pr-fixer`
and `infra-monitor` from cron / CI contexts).

Each skill is **self-contained** — copy the folder into any `.claude/skills/`
and it works. Skills that ship a `scripts/common.sh` keep it identical
across copies; CI enforces the sync.

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
    SKILL.md               Refactor → ship → monitor CI (Claude-driven)
    scripts/
      common.sh            Shared helpers (logging, config, JSON output)
      ship.sh              Atomic commit → rebase → push → PR → auto-merge
  bump-pr-fixer/           Find failed Renovate PRs → claude -p → ship.sh
  infra-monitor/           Collect cluster state → claude -p → ship.sh
  code-security/           Diff-scoped security review (Claude-driven)
  docs-update/             Diff-scoped doc drift review (Claude-driven)
  create-repo/             Bootstrap a GitHub repo from template
  orchestrate/             Supervisor-pattern multi-session orchestration
commands/
  refactor.md              Multi-pass refactoring
  ship.md                  Thin wrapper → publish/scripts/ship.sh
  sync.md                  Direct git fetch + rebase
scripts/
  setup-repo.sh            GitHub repo configuration
```

### Skills

| Skill | Description | User-invocable |
|-------|-------------|----------------|
| `publish` | Refactor, ship as PR with auto-merge, monitor CI | Yes |
| `bump-pr-fixer` | Fix failing Renovate dependency PRs | No (job) |
| `infra-monitor` | Monitor K8s cluster, create GitOps fix PRs | No (job) |
| `code-security` | Diff-scoped security review and fix | Yes |
| `docs-update` | Diff-scoped doc drift review and fix | Yes |
| `create-repo` | Create a configured GitHub repo from template | Yes |
| `orchestrate` | Decompose a goal into parallel worker sessions | Yes |

### Commands

| Command | Description |
|---------|-------------|
| `/refactor` | Multi-pass refactoring of newly implemented code |
| `/ship` | Commit, sync, push, and create/update a PR |
| `/sync` | Sync the current branch with the remote default branch |

## Script Contract

Where a skill does ship a `.sh` file, it follows:

| Aspect | Convention |
|--------|-----------|
| Input | CLI args + env vars, no interactive input |
| Output | JSON on stdout, human-readable logs on stderr |
| Exit codes | 0=success, 1=recoverable (Claude handles), 2=fatal |
| Source | `source "$(dirname "$0")/common.sh"` |

## Per-Repo Config

Skills read `.claude/config.yaml` from the current repo for overrides:

```yaml
publish:
  skip_refactor: false        # skip refactor phase
  max_fix_attempts: 3         # CI fix retry limit
  monitor_rounds: 10          # max poll rounds
  merge_method: rebase        # rebase | squash | merge

refactor:
  passes: 3                   # number of review passes
  include_tests: true         # whether to run test pass

ship:
  auto_merge: true            # enable auto-merge on PR
```

All values are optional with sensible defaults. No config file needed for default behavior.

## Drop-in Skills

Add project-local skills by copying a skill folder into `.claude/skills/` of any repo:

```
your-repo/
  .claude/
    skills/
      my-skill/
        SKILL.md
        scripts/
          common.sh
          do-stuff.sh
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
