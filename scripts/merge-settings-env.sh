#!/usr/bin/env bash
# Non-destructively merge the OTel env vars needed for Claude Code local
# observability into ~/.claude/settings.json. Existing keys are left
# untouched; if a key already exists with a *different* value, we warn
# and skip it rather than overwriting the user's configuration.
set -euo pipefail

SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# Metrics-only: this project doesn't use Claude Code's OTel *logs* export
# (tool-call/content detail comes from Alloy tailing ~/.claude/projects
# JSONL instead, see alloy/), so no *_LOGS_EXPORTER key is set.
#
# Two name variants are required for full coverage:
#   - plain OTEL_* is read by the standalone CLI.
#   - ANT_OTEL_* is read by the VS Code extension's bundled native binary,
#     which ignores the plain names (confirmed via `strings` on
#     native-binary/claude, which defines ANT_OTEL_METRICS_EXPORTER,
#     ANT_OTEL_EXPORTER_OTLP_PROTOCOL, and ANT_OTEL_EXPORTER_OTLP_ENDPOINT
#     as 1:1 counterparts of the standard names).
#
# Metric temporality (Delta vs Cumulative) is deliberately NOT configured
# here: Claude Code's VS Code extension has no ANT_-prefixed override for
# OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE, so it can't be forced
# from this side for that entrypoint. Instead, docker/otelcol-metrics-overlay.yaml
# converts Delta to Cumulative in the collector, which works regardless of
# what the sender does.
DESIRED_ENV='{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
  "ANT_OTEL_METRICS_EXPORTER": "otlp",
  "ANT_OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
  "ANT_OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317"
}'

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed" >&2
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "{}" > "$SETTINGS_FILE"
fi

if ! jq empty "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "error: $SETTINGS_FILE is not valid JSON, refusing to touch it" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq --argjson desired "$DESIRED_ENV" '
  .env = (.env // {}) |
  reduce ($desired | to_entries[]) as $e (
    .;
    if (.env[$e.key] // null) == null then
      .env[$e.key] = $e.value
    else
      .
    end
  )
' "$SETTINGS_FILE" > "$tmp"

# Report any conflicts (key exists with a different value than desired).
jq -r --argjson desired "$DESIRED_ENV" '
  .env as $env |
  ($desired | to_entries[]) |
  select(($env[.key] // null) != null and ($env[.key] != .value)) |
  "warning: \(.key) already set to \($env[.key] | tojson), leaving as-is (expected \(.value | tojson))"
' "$SETTINGS_FILE" >&2

mv "$tmp" "$SETTINGS_FILE"
echo "merged telemetry env into $SETTINGS_FILE"
