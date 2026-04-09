---
name: infra-monitor
description: Monitor Kubernetes cluster health and create fix PRs via Claude Code for GitOps-fixable issues.
user-invocable: false
allowed-tools: Bash, Read, Glob, Grep, Edit, Write
---

## Infra Monitor

Monitors Kubernetes cluster health by collecting pod status,
events, node metrics, and Prometheus alerts. If issues are
detected, clones the GitOps repo and creates a fix PR.

**Required env vars:** `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`REPO` (GitOps repo `owner/repo`), `PROMETHEUS_URL`.

---

### Step 1 — Collect cluster state

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/infra-monitor/SKILL.md)")" && pwd)"
source "$SKILL_DIR/scripts/common.sh"
setup_git
require_env GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN REPO PROMETHEUS_URL

STATE="$(bash "$SKILL_DIR/scripts/collect-state.sh")"
```

The output is plain text (not JSON) — it's a human-readable
cluster state report for Claude to analyze.

---

### Step 2 — Evaluate

Check the collected state for issues:
- Non-running pods (skip header/empty lines)
- Firing Prometheus alerts

If no issues are found, log "Cluster healthy, no action needed"
and exit.

---

### Step 3 — Create fix PR

Save state to a temp file and run the fix script:

```bash
STATE_FILE="$(mktemp)"
echo "$STATE" > "$STATE_FILE"
bash "$SKILL_DIR/scripts/create-fix-pr.sh" --repo "$REPO" --state-file "$STATE_FILE"
rm -f "$STATE_FILE"
```

Parse JSON output:
- `status: "pr_created"` → show PR URL
- `status: "no_issues"` → log, no action needed

---

### Output

Print a summary:
- Cluster state: healthy / issues detected
- Action: PR created (URL) / no GitOps-fixable issues / no action needed
