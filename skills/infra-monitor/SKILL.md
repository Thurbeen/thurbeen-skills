---
name: infra-monitor
description: Monitor Kubernetes cluster health and create fix PRs via Claude Code for GitOps-fixable issues.
user-invocable: false
allowed-tools: Bash, Read, Glob, Grep, Edit, Write, Agent, Skill
---

## Infra Monitor

Monitors Kubernetes cluster health by collecting pod status, events,
node metrics, and Prometheus alerts. If issues are detected, clones
the GitOps repo and creates a fix PR.

**Required env vars:** `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`REPO` (GitOps repo `owner/repo`), `PROMETHEUS_URL`.

---

### Step 1 — Setup

Verify required env vars and configure git for the CI runner:

```bash
[[ -n "$GH_TOKEN" && -n "$CLAUDE_CODE_OAUTH_TOKEN" \
  && -n "$REPO" && -n "$PROMETHEUS_URL" ]] \
  || { echo "Missing required env vars"; exit 1; }

git config --global user.name  "claude-code-bot"
git config --global user.email "claude-code-bot@users.noreply.github.com"
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
```

---

### Step 2 — Collect cluster state

Run these commands and read the output directly. Partial data is fine —
continue on any individual failure.

```bash
echo '=== Non-Running Pods ==='
kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>&1 || true

echo; echo '=== Recent Warning Events ==='
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>&1 | tail -50 || true

echo; echo '=== Node Status ==='
kubectl get nodes -o wide 2>&1 || true
kubectl top nodes 2>&1 || true

echo; echo '=== Pod Resource Usage (top 20 by memory) ==='
kubectl top pods -A --sort-by=memory 2>&1 | head -20 || true

echo; echo '=== Prometheus Alerts Firing ==='
curl -sf "${PROMETHEUS_URL}/api/v1/alerts" \
  | jq -r '
      .data.alerts[]
      | select(.state=="firing")
      | "\(.labels.alertname) [\(.labels.severity)] - \(.annotations.summary // .annotations.description // "no description")"
    ' 2>/dev/null || true

echo; echo '=== High Restart Count Pods (>3) ==='
kubectl get pods -A -o json \
  | jq -r '
      .items[]
      | select(.status.containerStatuses[]?.restartCount > 3)
      | "\(.metadata.namespace)/\(.metadata.name) restarts=\(.status.containerStatuses[].restartCount)"
    ' 2>/dev/null || true
```

---

### Step 3 — Evaluate

Inspect the output for non-running pods (skip header/empty lines) and
firing Prometheus alerts. If nothing is found, log
"Cluster healthy, no action needed" and exit.

---

### Step 4 — Clone and branch

```bash
workdir="/workspace/$(echo "$REPO" | tr '/' '-')"
rm -rf "$workdir"
git clone --depth=1 "https://github.com/${REPO}.git" "$workdir"
cd "$workdir"
branch="fix/infra-monitor-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$branch"
```

---

### Step 5 — Delegate fix to a sub-agent

Use the Agent tool with the cluster state from Step 2 as input. Prompt:

> You are a Kubernetes cluster monitor for a bare-metal Talos Linux
> cluster managed by ArgoCD GitOps. Working directory: `<workdir>`,
> already on a fix branch.
>
> Here is the current cluster state:
>
> ```
> <cluster state from Step 2>
> ```
>
> Analyze the cluster state and identify issues that can be fixed via
> GitOps changes in this repo. Focus on:
>
> - Pods in CrashLoopBackOff, Error, or Pending state
> - Firing Prometheus alerts indicating misconfigurations
> - Resource limit/request mismatches causing OOMKills
> - Configuration issues visible in events
>
> For each fixable issue, make the minimal targeted change in the
> appropriate Kubernetes manifest. Do not refactor unrelated code. Do
> not fix issues that require manual intervention outside GitOps. If
> there are no GitOps-fixable issues, do nothing.
>
> After making changes, stage them with `git add`. Do not commit or
> push; the lead will handle that.

Allowed tools for the sub-agent: `Bash, Read, Edit, Write, Glob, Grep`.

---

### Step 6 — Ship or clean up

After the sub-agent returns:

```bash
git diff --cached --quiet && echo "no changes" || echo "changes staged"
```

- **No changes** → `rm -rf "$workdir"` and report
  "no GitOps-fixable issues found".
- **Changes staged** → invoke `/ship` via the Skill tool with message
  `fix: infra-monitor auto-remediation $(date +%Y-%m-%d)`. Capture the
  PR URL from the output.

---

### Output

Print a summary:
- Cluster state: healthy / issues detected
- Action: PR created (URL) / no GitOps-fixable issues / no action needed
