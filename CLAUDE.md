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

Each skill is a single `SKILL.md` that Claude executes using its
native tools (Bash, Read, Edit, Write, Grep, Agent, Skill). No
shell-script layer, no JSON IPC, no shared utility library.
`SKILL.md` contains both the orchestration and the inline commands
Claude runs — Claude reads tool output directly and decides what
to do next.

```
skills/<name>/
  SKILL.md       The whole skill
  templates/     Optional data assets (e.g. worker prompts)
```

Exception: `skills/orchestrate/` still uses `scripts/` for its
bd-backed state tracking and session plumbing — it is the
supervisor-pattern workflow and has its own architecture.

### Per-Repo Config

Skills read `.claude/config.yaml` from the current repo via
the Read tool (or `yq` inside inline Bash). Keys are flat
two-level (`<section>.<key>`); all values are optional with
sensible defaults documented in each `SKILL.md`.

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
