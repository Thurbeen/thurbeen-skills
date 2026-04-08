# thurbeen-skills

Centralized Claude Code skills and commands shared across all repositories. Skills are symlinked into `~/.claude/skills/` and commands into `~/.claude/commands/` via the setup script.

## Installation

```bash
git clone git@github.com:Thurbeen/thurbeen-skills.git
cd thurbeen-skills
./setup.sh
```

The installer is idempotent — safe to re-run after pulling updates.

## Structure

```
skills/       Skill directories (each contains SKILL.md)
commands/     Slash command files (*.md)
setup.sh      Symlink installer
scripts/      Repository configuration scripts
```

### Skills

| Skill | Description |
|-------|-------------|
| `publish` | Refactor, ship as a PR with auto-merge, and monitor CI |

### Commands

| Command | Description |
|---------|-------------|
| `/refactor` | Multi-pass refactoring of newly implemented code |
| `/ship` | Commit, sync, push, and create/update a PR |
| `/sync` | Sync the current branch with the remote default branch |

## Repository Setup

Configure a GitHub repository with standardized settings (rebase-only merges, auto-merge, branch protection):

```bash
./scripts/setup-repo.sh
```

Requires the `gh` CLI with repo admin permissions.

## License

[Apache-2.0](LICENSE)
