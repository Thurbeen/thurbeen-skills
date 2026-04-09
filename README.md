# thurbeen-skills

Centralized Claude Code skills and commands shared across all repositories. Uses a **script-first** approach: deterministic operations run as shell scripts, while `SKILL.md` files orchestrate Claude-driven decisions.

Each skill is **self-contained** — copy the folder into any `.claude/skills/` and it works. Skills share an identical `common.sh`; CI enforces they stay in sync.

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
    SKILL.md               Orchestrator: refactor → ship → monitor CI
    common.sh              Shared utilities (logging, config, JSON output)
    preflight.sh           Fetch, detect branches, rebase
    ship.sh                Commit, push, PR, auto-merge
    monitor.sh             Single CI poll round
    validate.sh            Post-merge deployment check
  bump-pr-fixer/
    SKILL.md               Orchestrator: find failed Renovate PRs → fix
    common.sh              Shared utilities
    find-failed-prs.sh     Find Renovate PRs with failing CI
    fix-pr.sh              Checkout PR, run Claude, push fix
  infra-monitor/
    SKILL.md               Orchestrator: collect cluster state → fix
    common.sh              Shared utilities
    collect-state.sh       kubectl + Prometheus data collection
    create-fix-pr.sh       Clone repo, branch, commit, create PR
commands/
  refactor.md              Multi-pass refactoring (pure Claude-driven)
  ship.md                  Thin wrapper → publish/ship.sh
  sync.md                  Thin wrapper → publish/preflight.sh
scripts/
  setup-repo.sh            GitHub repo configuration
```

### Skills

| Skill | Description | User-invocable |
|-------|-------------|----------------|
| `publish` | Refactor, ship as PR with auto-merge, monitor CI | Yes |
| `bump-pr-fixer` | Fix failing Renovate dependency PRs | No (job) |
| `infra-monitor` | Monitor K8s cluster, create GitOps fix PRs | No (job) |

### Commands

| Command | Description |
|---------|-------------|
| `/refactor` | Multi-pass refactoring of newly implemented code |
| `/ship` | Commit, sync, push, and create/update a PR |
| `/sync` | Sync the current branch with the remote default branch |

## Script Contract

All `.sh` files in each skill follow:

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
