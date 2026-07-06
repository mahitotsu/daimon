---
name: claude-observability
description: Answer questions about local Claude Code usage -- token/cost usage, tool-call frequency, and session content search -- using the local otel-lgtm stack (Prometheus + Loki) set up by this repo. Use when asked things like "how many tokens did I use today", "what tools have I been calling most", "find the session where I discussed X", "what was I working on / doing before", or "recall the last session / before the restart". Prefer this over `git log` for recalling past conversation content -- commits only capture what got committed, not what was discussed.
---

# Claude Code observability

Data sources (see repo README.md for how they're populated):
- **Prometheus** (`claude_code_*` metrics) -- token usage and cost, exported by Claude Code's OTel integration.
- **Loki, `{service_name="claude-code"}`** -- Claude Code's own OTel *log* events (`claude_code.tool_result`, `tool_decision`, `user_prompt`, `assistant_response`, ...), exported directly via OTLP and ingested through Loki's native OTLP endpoint. `tool_name`, `success`, `duration_ms`, `tool_input_size_bytes`, `tool_result_size_bytes` etc. are present as structured metadata on every `tool_result`/`tool_decision` event unconditionally (no extra env var needed) -- use this for tool-call frequency/duration, not the script below (there is no script anymore). `user_prompt`/`assistant_response` bodies stay `"<REDACTED>"` unless `OTEL_LOG_USER_PROMPTS`/`OTEL_LOG_ASSISTANT_RESPONSES` are set, and even then are capped at 60KB -- don't rely on this stream for full conversation content.
- **Loki, `{job="claude-code-sessions"}`** -- full session transcripts, tailed from `~/.claude/projects/*/*.jsonl` by Grafana Alloy. This is the only source for untruncated tool-call input/output and full conversation content.

Query both through the official `grafana` MCP server (`query_prometheus`, `query_loki_logs`, `list_prometheus_metric_names`, etc.).

## Usage summary dashboard (token/cost/active-time/session-count/tool-frequency)

For questions like "how much have I used today/this week", "what's my cost breakdown", "how productive was today" -- anything wanting the headline usage numbers rather than a specific narrow figure -- don't reconstruct all of it from scratch with a chain of `query_prometheus`/`query_loki_logs` calls. A bundled dashboard (`docker/grafana-dashboard-claude-code-usage.json`, uid `claude-code-usage-summary`) already has these panels wired up, adjustable to any time range via Grafana's picker. Confirmed 2026-07-06: answering this kind of question by hand took ~10 separate tool calls (one per metric/breakdown); that cost is the reason this dashboard exists.

Preferred pattern: run at most one or two `query_prometheus`/`query_loki_logs` calls for the specific headline number(s) the user asked about (if any), then call `generate_deeplink` with `resourceType: "dashboard"`, `dashboardUid: "claude-code-usage-summary"`, and a `timeRange` matching what was asked (e.g. `{"from": "now-24h", "to": "now"}` for "today", `{"from": "now-7d", "to": "now"}` for "this week"), and hand the link back for the visual/detailed breakdown. Don't re-derive each panel's PromQL/LogQL by hand when a link to the already-built panel will do.

This does not apply to tool-call frequency questions framed narratively ("what have I been doing", "where do I keep failing") or full-text session search -- those stay in-chat per the sections below, since they're about narrative/judgment, not headline numbers.

## Token / cost usage

Known metric names (verify with `list_prometheus_metric_names` filtered on `claude_code` if a query returns nothing -- names can change with Claude Code versions):

- `claude_code_token_usage_tokens_total` (labels include `model`, `session_id`, `type`: input/output/cacheRead/cacheCreation)
- `claude_code_cost_usage_USD_total` (labels include `model`, `session_id`)
- `claude_code_session_count_total`
- `claude_code_active_time_seconds_total`

These are Cumulative counters (the collector converts Claude Code's native Delta export to Cumulative -- see README.md). To get usage over a window, use `increase()`, e.g. via `query_prometheus`:

```promql
sum(increase(claude_code_token_usage_tokens_total[24h])) by (model)
sum(increase(claude_code_cost_usage_USD_total[24h]))
```

Adjust the range (`[24h]`, `[7d]`, ...) to match what the user asked for. If the range is very recent (metric only started existing minutes ago), `increase()` may need 2+ scrape samples to return a value -- an empty result doesn't necessarily mean zero usage.

**Do not use `increase()` on `claude_code_session_count_total`** -- confirmed broken (2026-07-06, Claude Code v2.1.201): unlike the other three metrics, this one is emitted as a single fixed sample (value `1`) per unique `session_id` label, so each session gets its own flat, never-changing time series. `increase()` measures the delta *within* a series, which is always ~0 here regardless of how many sessions actually ran -- summing it across sessions still gives 0. To count sessions in a window, count distinct `session_id` series instead:

```promql
count(count by (session_id) (last_over_time(claude_code_session_count_total[24h])))
```

Also treat this metric as an approximate lower bound, not authoritative: it's emitted once at session start with no repeat, so it's more fragile than the continuously-re-exported counters (e.g. to a startup race with the OTLP exporter). Confirmed 2026-07-06: a session with heavy, clearly-active `claude_code_token_usage_tokens_total` data had zero `claude_code_session_count_total` samples anywhere in the 7-day retention window. If a session count looks suspiciously low, cross-check with `count(count by (session_id) (last_over_time(claude_code_token_usage_tokens_total[<range>])))`, which is more reliable since it's tied to a continuously-repeated counter.

## Tool-call frequency

Use `query_loki_logs` against the `{service_name="claude-code"}` stream with a LogQL metric query (`queryType: instant`), filtering to `tool_result` events via structured metadata and grouping by `tool_name`:

```
sum by (tool_name) (count_over_time({service_name="claude-code"} | event_name="tool_result" [24h]))
```

Note the pipeline filter (`| event_name="tool_result"`) rather than a stream-selector label (`{event_name="tool_result"}`) -- `event_name` is structured metadata, not an indexed label, so it only matches inside `| ...` filters. Swap `count_over_time(...)` grouping/range as needed, e.g. add `, session_id` to `by (...)` to break down per session, or filter `| success="false"` for failures, or aggregate `avg by (tool_name) (avg_over_time(... | unwrap duration_ms [24h]))` for latency. Session frequency breakdowns work the same way with `by (session_id, tool_name)`.

This replaced a bundled JSON-parsing script that used to scan JSONL transcripts for `tool_use` blocks -- the OTel `tool_result` event is one flat event per tool call (unlike a JSONL message, which can embed several `tool_use` blocks in one line), so plain LogQL aggregation is sufficient and no custom parsing is needed anymore.

## Session content search

Use `query_loki_logs` with LogQL directly, e.g.:

```
{job="claude-code-sessions"} |~ "docker-compose"
```

Each matching line is a raw JSONL transcript entry (full message content, tool_use blocks, etc.) -- read and summarize it yourself; don't expect a pre-summarized answer from the query.

Broad queries (wide time range, permissive regex like `error|failed`) can match many lines, and any single line can itself be huge -- a transcript line embeds the full content of that message, including large tool outputs. This can blow the response past the token budget and return nothing at all instead of a partial result. `limit` alone does not fix this -- it caps line *count*, not size, and a single huge line can still blow the budget.

Do **not** try `| line_format "{{ trunc 300 .Line }}"` to cap line length -- confirmed broken against the `grafana` MCP server's `query_loki_logs`: adding *any* `line_format` stage (even a no-op `{{ .Line }}`) makes the tool drop the `line` field from every result entry entirely, so you get timestamps/labels back with no content. This looks like the MCP tool failing to re-parse Loki's response shape once `line_format` changes it, not a LogQL problem -- a raw `curl` against Loki's HTTP API would presumably work fine.

Instead, cap size by excluding the huge entries with negative line filters, since giant lines are almost always `tool_use`/`tool_result` payloads:

```
{job="claude-code-sessions"} != "tool_result" != "toolUseResult" |~ "docker-compose"
```

This keeps short entries (user prompts, assistant text replies, `last-prompt`/`ai-title`/`mode` marker lines) and drops large tool I/O. Combine with a small `limit` (5-15) and narrow the time range. If a query still errors as too large, tighten the regex or filters further rather than retrying as-is -- don't fall back to reading the session's local `.jsonl` file directly with Bash/Read, since that bypasses the tool this skill exists to exercise.

To scope a search to a specific prior session (e.g. "what was I doing before the last restart"), find that session's local file under `~/.claude/projects/<project>/*.jsonl` by mtime, then bound the Loki query with `filename="<path>"` plus `endRfc3339` set to the *next* session's start timestamp (get that via a `limit: 1, direction: forward` query on the current session's filename) so you don't pull in the session you're currently running in.
