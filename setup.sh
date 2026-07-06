#!/usr/bin/env bash
# One-shot, idempotent setup for the local Claude Code self-observability
# stack: Claude Code OTel -> otel-lgtm (Docker) for metrics and tool-call
# aggregation (frequency/success/duration), Grafana Alloy (native,
# systemd --user) tailing session JSONL -> Loki for full conversation/tool
# content, and the official Grafana MCP server (+ a bundled skill) for
# querying both in natural language.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/4: merging telemetry env into ~/.claude/settings.json =="
"$REPO_ROOT/scripts/merge-settings-env.sh"

echo
echo "== 2/4: starting otel-lgtm (Docker) =="
docker compose -f "$REPO_ROOT/docker/docker-compose.yml" up -d

echo
echo "== 3/4: installing/starting Grafana Alloy (systemd --user) =="
"$REPO_ROOT/scripts/install-alloy.sh"

echo
echo "== 4/4: registering the Grafana MCP server (user scope) =="
"$REPO_ROOT/scripts/setup-grafana-mcp.sh"

cat <<EOF

Setup complete. Restart Claude Code so the new env vars and MCP server
take effect, then verify with:

  docker ps                                   # otel-lgtm container Up
  curl -s localhost:3100/ready                 # Loki ready
  curl -s localhost:9090/-/healthy             # Prometheus healthy
  systemctl --user status claude-alloy         # Alloy active (running)
  claude mcp list                              # 'grafana' Connected

See README.md for the full verification checklist and how to uninstall.
EOF
