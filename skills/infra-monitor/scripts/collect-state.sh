#!/usr/bin/env bash
# collect-state.sh — Collect Kubernetes cluster state and Prometheus alerts.
#
# Usage: collect-state.sh
#
# Required env vars:
#   PROMETHEUS_URL - Prometheus endpoint URL
#
# Exit codes: 0=success (always, partial data is fine), 2=fatal
# Output: cluster state text to stdout (not JSON — consumed by Claude for analysis)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_env PROMETHEUS_URL

log "Collecting cluster state"

printf '=== Non-Running Pods ===\n'
kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>&1 || true

printf '\n=== Recent Warning Events ===\n'
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>&1 | tail -50 || true

printf '\n=== Node Status ===\n'
kubectl get nodes -o wide 2>&1 || true
kubectl top nodes 2>&1 || true

printf '\n=== Pod Resource Usage (top 20 by memory) ===\n'
kubectl top pods -A --sort-by=memory 2>&1 | head -20 || true

printf '\n=== Prometheus Alerts Firing ===\n'
curl -sf "${PROMETHEUS_URL}/api/v1/alerts" \
  | jq -r '
      .data.alerts[]
      | select(.state=="firing")
      | "\(.labels.alertname) [\(.labels.severity)] - \(.annotations.summary // .annotations.description // "no description")"
    ' 2>/dev/null || true

printf '\n=== High Restart Count Pods (>3) ===\n'
kubectl get pods -A -o json \
  | jq -r '
      .items[]
      | select(.status.containerStatuses[]?.restartCount > 3)
      | "\(.metadata.namespace)/\(.metadata.name) restarts=\(.status.containerStatuses[].restartCount)"
    ' 2>/dev/null || true

log "State collection complete"
