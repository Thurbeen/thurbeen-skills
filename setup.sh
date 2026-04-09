#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# Symlink skills
if [ -d "$SCRIPT_DIR/skills" ]; then
    mkdir -p "$CLAUDE_DIR/skills"
    for skill in "$SCRIPT_DIR/skills"/*/; do
        [ -d "$skill" ] || continue
        name="$(basename "$skill")"
        link="$CLAUDE_DIR/skills/$name"
        if [ -L "$link" ]; then
            rm "$link"
        elif [ -e "$link" ]; then
            echo "WARN: $link exists and is not a symlink — skipping"
            continue
        fi
        ln -s "$skill" "$link"
        echo "Linked skill: $name"
    done
fi

# Symlink commands
if [ -d "$SCRIPT_DIR/commands" ]; then
    mkdir -p "$CLAUDE_DIR/commands"
    for cmd in "$SCRIPT_DIR/commands"/*.md; do
        [ -f "$cmd" ] || continue
        name="$(basename "$cmd")"
        link="$CLAUDE_DIR/commands/$name"
        if [ -L "$link" ]; then
            rm "$link"
        elif [ -e "$link" ]; then
            echo "WARN: $link exists and is not a symlink — skipping"
            continue
        fi
        ln -s "$cmd" "$link"
        echo "Linked command: $name"
    done
fi

# Ensure all .sh files are executable
find "$SCRIPT_DIR" -name '*.sh' -type f -exec chmod +x {} +
