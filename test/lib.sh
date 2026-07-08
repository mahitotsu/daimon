#!/usr/bin/env bash
# Shared helpers for the regression harness described in SPEC.md. Sourced by
# run-all.sh and each scenario-N.sh -- not meant to be run directly.
#
# Design decisions (see the conversation that designed this harness for the
# full reasoning; kept here so a future reader doesn't have to rediscover
# them):
#
# - AskUserQuestion is unconditionally denied under `claude -p`, even with
#   --permission-mode bypassPermissions (confirmed 2026-07-08 against
#   v2.1.162: the call shows up in the JSON result's `permission_denials`
#   with no prompt ever surfaced). There is no TTY to present options to, so
#   the harness blocks it regardless of permission mode. Scenario 3
#   therefore never tries to synthesize AskUserQuestion fixtures -- it grades
#   against whatever real history already exists in the project.
#
# - Prometheus's cost/token/session-count metrics are NOT project-scoped, so
#   synthesizing fixture usage for scenarios 4/5 would permanently pollute
#   the real personal usage numbers this tool exists to report accurately,
#   with no way to delete just the synthetic rows afterward. Only scenario 1
#   gets an explicit setup step (spawning a throwaway Task subagent), because
#   its premise specifically requires a separate execution unit to review
#   that can't be assumed to already exist. Scenarios 2/3 rely on ambient
#   real history (skip/PARTIAL if a project is too new to have any); 4/5
#   need no setup at all since the harness's own execution call already
#   generates fresh, real token/cost data to query.
#
# - --no-session-persistence is used for every execution/judge call so the
#   harness's own prompts and verdicts don't get written under
#   ~/.claude/projects and pollute future full-text session search
#   (scenario 2) with synthetic conversation content. Scenario 1's setup
#   call deliberately omits this flag -- its entire point is to leave a real,
#   Alloy-tailed JSONL transcript for the execution call to find later.
set -euo pipefail

RESULTS_LOG="${REGRESSION_RESULTS_LOG:-$HOME/.local/share/claude-observability/regression-results.jsonl}"

# project_filter [cwd] -- the Loki `filename` regex for the current
# project's own session directory. Claude Code names
# ~/.claude/projects/<dir> by replacing every "/" in the project's cwd with
# "-" (confirmed against this repo's own directory:
# /home/akring/daimon -> -home-akring-daimon). Defaults to the git repo
# toplevel, not plain $PWD -- every scenario-N.sh `cd`s into
# test/ before sourcing this file (to reliably find lib.sh via
# a relative path), so bare $PWD would resolve to test/ itself
# rather than the actual Claude Code project directory (confirmed
# 2026-07-09: this silently produced zero matches instead of an error).
project_filter() {
  local cwd="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
  echo ".*$(echo "$cwd" | tr '/' '-')/.*"
}

# pick_recall_topic [cwd] -- returns one real past session's `ai-title`
# (Claude Code's own short auto-generated session summary) for the given
# project, queried directly against Loki's HTTP API (no `claude -p` call --
# fast, free, deterministic). This is the "prompt override" scenario 2 needs:
# a topic hardcoded as a literal string decays as soon as it gets written
# into a doc/comment (confirmed 2026-07-09: two hardcoded topics got burned
# this way in the same sitting, once each), so instead of
# picking one topic and hoping it stays clean, pick from whatever's actually
# in Loki at run time. Skips anything from the last 6h so it can't pick the
# still-running session or the harness's own just-finished setup calls (in
# practice execution/judge calls never show up here at all -- they use
# --no-session-persistence and so never get an ai-title). Prints nothing
# (caller must treat empty as "not enough history yet") if no candidate
# exists in the last 30 days.
pick_recall_topic() {
  local filter
  # Forward args as-is (not defaulted here) so an omitted arg reaches
  # project_filter's own default (git toplevel) instead of being
  # pre-resolved to $PWD here and shadowing it (confirmed 2026-07-09: that
  # was the actual bug the fix above was for -- this call site still had
  # the old $PWD default hardcoded even after project_filter itself was
  # fixed).
  filter="$(project_filter "$@")"
  local now cutoff start
  now="$(date +%s)"
  cutoff=$(( (now - 6*3600) * 1000000000 ))
  start=$(( (now - 30*86400) * 1000000000 ))
  curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
    --data-urlencode "query={job=\"claude-code-sessions\", filename=~\"${filter}\"} |= \"\\\"type\\\":\\\"ai-title\\\"\"" \
    --data-urlencode 'limit=500' \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$cutoff" \
  | jq -r '.data.result[]?.values[]?[1]' \
  | jq -sc '[.[] | select(.aiTitle != null and .aiTitle != "")] | unique_by(.sessionId)' \
  | jq -r 'if length > 0 then .[(now | floor) % length].aiTitle else empty end'
}

check_connectivity() {
  echo "== connectivity precheck ==" >&2
  [ "$(docker inspect --format='{{.State.Health.Status}}' claude-otel-lgtm 2>/dev/null || echo missing)" = "healthy" ] \
    || { echo "FAIL: claude-otel-lgtm container not Up/healthy" >&2; return 1; }
  curl -sf localhost:3100/ready >/dev/null \
    || { echo "FAIL: Loki not ready" >&2; return 1; }
  curl -sf localhost:9090/-/healthy >/dev/null \
    || { echo "FAIL: Prometheus not healthy" >&2; return 1; }
  [ "$(systemctl --user is-active claude-alloy 2>/dev/null || true)" = "active" ] \
    || { echo "FAIL: claude-alloy systemd --user service not active" >&2; return 1; }
  claude mcp list 2>&1 | grep -q '^grafana:.*Connected' \
    || { echo "FAIL: grafana MCP server not Connected" >&2; return 1; }
  echo "OK: otel-lgtm up, Loki/Prometheus healthy, Alloy active, grafana MCP connected" >&2
}

# run_prompt <prompt> <model> -- prints the response text on stdout, logs
# cost/session_id to stderr. See file header for why
# --no-session-persistence + --permission-mode bypassPermissions are used.
run_prompt() {
  local prompt="$1" model="$2"
  local out
  out="$(claude -p "$prompt" --model "$model" --permission-mode bypassPermissions \
    --output-format json --no-session-persistence)"
  echo "$out" | jq -r '"  (cost $" + (.total_cost_usd | tostring) + ", session " + .session_id + ")"' >&2
  echo "$out" | jq -r '.result'
}

# run_prompt_persisted <prompt> <model> -- same as run_prompt but keeps
# session persistence on. Only scenario-1's setup step should use this: it
# needs a real JSONL transcript under ~/.claude/projects for Alloy to tail
# and for the later execution call to discover.
run_prompt_persisted() {
  local prompt="$1" model="$2"
  local out
  out="$(claude -p "$prompt" --model "$model" --permission-mode bypassPermissions \
    --output-format json)"
  echo "$out" | jq -r '"  (cost $" + (.total_cost_usd | tostring) + ", session " + .session_id + ")"' >&2
  echo "$out" | jq -r '.result'
}

# judge <question> <response> <rubric-text> -- grades response against a
# rubric using Haiku (a different checkpoint than the Sonnet call that
# produced the response). This is a partial, not complete, mitigation of
# LLM-as-judge self-preference bias: research on the topic (arXiv:2410.21819)
# finds the bias tracks familiarity/perplexity with a judge's own generation
# style, which is reduced but not eliminated by a different checkpoint in the
# same model family. A genuinely independent judge would need a different
# vendor, which isn't practical inside Claude Code -- see conversation.
# Uses --json-schema for a structured, parseable verdict rather than
# free-text (confirmed 2026-07-08: schema-validated fields land in
# `.structured_output`; `.result` is empty in that mode).
#
# QUESTION is passed alongside RESPONSE (confirmed 2026-07-09: without it,
# criteria like "found this without being given a session ID/date hint"
# were unverifiable to the judge, since it could see the answer but not
# whether the question itself contained hints -- this showed up as
# consistent PARTIAL verdicts on that specific criterion across scenarios
# 1 and 2).
judge() {
  local question="$1" response="$2" rubric="$3"
  local schema='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL","PARTIAL"]},"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"met":{"type":"boolean"},"reason":{"type":"string"}},"required":["criterion","met","reason"]}},"summary":{"type":"string"}},"required":["verdict","criteria","summary"]}'
  local prompt
  prompt="Grade the RESPONSE strictly against each item in CRITERIA, in light of the QUESTION it was answering. Do not be lenient just because the response reads fluently -- check each criterion independently and cite what in the response satisfies or fails it. If a criterion can't be evaluated because of missing data (e.g. not enough history yet), mark it not met and say why in the reason, don't skip it.

CRITERIA:
$rubric

QUESTION:
$question

RESPONSE:
$response"
  claude -p "$prompt" --model haiku --permission-mode bypassPermissions \
    --output-format json --no-session-persistence --json-schema "$schema" \
    | jq '.structured_output'
}

log_result() {
  local scenario_id="$1" verdict_json="$2"
  mkdir -p "$(dirname "$RESULTS_LOG")"
  jq -nc --arg id "$scenario_id" --arg date "$(date -Iseconds)" \
    --arg version "$(claude --version 2>/dev/null | awk '{print $1}')" \
    --argjson verdict "$verdict_json" \
    '{scenario: $id, date: $date, claude_code_version: $version, verdict: $verdict.verdict, criteria: $verdict.criteria, summary: $verdict.summary}' \
    >> "$RESULTS_LOG"
  echo "logged to $RESULTS_LOG" >&2
}
