# CLAUDE.md

This file provides guidance to Claude Code when working with
this repository.

## Project

Centralized Claude Code skills and commands shared across all
repositories. Skills are symlinked into `~/.claude/skills/`
and commands into `~/.claude/commands/` via `setup.sh`.

## Structure

- `skills/` — Skill directories (each contains `SKILL.md`)
- `commands/` — Slash command files (`*.md`)
- `setup.sh` — Symlink installer (idempotent)
- `scripts/setup-repo.sh` — GitHub repo configuration

## Installation

```bash
./setup.sh
```

## Conventional Commits

All commits must follow
[Conventional Commits](https://www.conventionalcommits.org/).
Enforced by pre-commit hooks.

- **Types**: feat, fix, perf, refactor, docs, style, test,
  chore, ci, build, revert
