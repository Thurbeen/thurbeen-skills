# CLAUDE.md

This file provides guidance to Claude Code when working with
this repository.

## Project

Centralized Claude Code skills and commands shared across all
repositories. Skills are symlinked into `~/.claude/skills/`
and commands into `~/.claude/commands/` via `setup.sh`.

## Structure

- `skills/` — Self-contained skill directories
- `commands/` — Slash command files (`*.md`)
- `scripts/` — Repository configuration scripts
- `setup.sh` — Symlink installer (idempotent)

## Skill Architecture

Each skill is a **self-contained directory** that can be
copied as-is into any `.claude/skills/` folder:

```
skills/<name>/
  SKILL.md       Orchestrator (Claude-driven decisions)
  scripts/
    common.sh    Shared utilities (logging, config, JSON)
    *.sh         Deterministic shell scripts
```

Each skill has its own copy of `common.sh`. CI enforces
all copies stay identical.

### Script Contract

- **Input**: CLI args + env vars (no interactive input)
- **Output**: JSON on stdout, logs on stderr
- **Exit codes**: 0=success, 1=recoverable, 2=fatal
- **Source**: `source "$(dirname "$0")/common.sh"` (scripts are co-located in `scripts/`)

### Per-Repo Config

Skills read `.claude/config.yaml` from the current repo for
overrides. All values are optional with sensible defaults.

### Drop-in Skills

Copy a skill directory into `.claude/skills/` of any repo.
Project-local skills override global skills of the same name.

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
