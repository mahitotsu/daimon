#!/usr/bin/env bash
# Registers the official grafana/mcp-grafana MCP server (via `uvx`) against
# the local otel-lgtm Grafana instance, creating a dedicated Grafana
# service account + token for it if needed. Idempotent: does nothing if
# the MCP server is already registered.
set -euo pipefail

GRAFANA_URL="http://localhost:3000"
SA_NAME="claude-code-mcp"
MCP_NAME="grafana"

if claude mcp get "$MCP_NAME" >/dev/null 2>&1; then
  echo "MCP server '$MCP_NAME' already registered, skipping"
  exit 0
fi

if ! command -v uvx >/dev/null 2>&1; then
  echo "error: uvx (from the 'uv' Python tool) is required but not installed" >&2
  exit 1
fi

echo "waiting for Grafana at $GRAFANA_URL ..."
for _ in $(seq 1 30); do
  curl -sf "$GRAFANA_URL/api/health" >/dev/null 2>&1 && break
  sleep 2
done

sa_id="$(curl -sf "$GRAFANA_URL/api/serviceaccounts/search?query=$SA_NAME" \
  | jq -r --arg name "$SA_NAME" '.serviceAccounts[]? | select(.name == $name) | .id' | head -1)"

if [ -z "$sa_id" ]; then
  sa_id="$(curl -sf -X POST "$GRAFANA_URL/api/serviceaccounts" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$SA_NAME\",\"role\":\"Viewer\"}" | jq -r '.id')"
  echo "created Grafana service account '$SA_NAME' (id $sa_id)"
else
  echo "reusing existing Grafana service account '$SA_NAME' (id $sa_id)"
fi

token_name="mcp-token-$(date +%s)"
token="$(curl -sf -X POST "$GRAFANA_URL/api/serviceaccounts/$sa_id/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$token_name\"}" | jq -r '.key')"

if [ -z "$token" ] || [ "$token" = "null" ]; then
  echo "error: failed to create a Grafana service account token" >&2
  exit 1
fi

claude mcp add "$MCP_NAME" -s user \
  -e "GRAFANA_URL=$GRAFANA_URL" \
  -e "GRAFANA_SERVICE_ACCOUNT_TOKEN=$token" \
  -- uvx mcp-grafana

echo "registered MCP server '$MCP_NAME'"
