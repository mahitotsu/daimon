---
name: claude-observability
description: Answer questions about local Claude Code usage -- token/cost usage, tool-call frequency/duration, turn/trace structure, and session content search -- using the local otel-lgtm stack (Prometheus + Loki + Tempo) set up by this repo. Use when asked things like "how many tokens did I use today", "what tools have I been calling most", "why was that turn slow", "find the session where I discussed X", "what was I working on / doing before", or "recall the last session / before the restart". Prefer this over `git log` for recalling past conversation content -- commits only capture what got committed, not what was discussed.
---

# Claude Code observability

Data sources (see repo README.md for how they're populated):
- **Prometheus** (`claude_code_*` metrics) -- token usage and cost, exported by Claude Code's OTel integration.
- **Tempo, `{resource.service.name="claude-code"}`** -- Claude Code's OTel *trace* spans (beta): `claude_code.interaction` (one turn) -> `claude_code.llm_request` / `claude_code.tool` (has `tool_use_id`) -> `claude_code.tool.execution` / `claude_code.tool.blocked_on_user`. Spans carry `tool_name`, `success`, `duration_ms` (plus the native `span:duration` intrinsic), `session.id`, `interaction.sequence`, `model`, `input_tokens`/`output_tokens`/`cache_read_tokens`/`cache_creation_tokens`, `ttft_ms`, `decision`, `error`, `attempt`, `tool_use_id`/`gen_ai.tool.call.id`. This is the preferred source for anything about call *structure*, *sequencing*, or *duration/error-rate aggregation* -- prefer it over hand-rolled Loki aggregation (see below). `user_prompt` on spans is redacted the same way as the Loki log stream, so it is not a content-search source.
- **Loki, `{service_name="claude-code"}`** -- Claude Code's own OTel *log* events (`claude_code.tool_result`, `tool_decision`, `user_prompt`, `assistant_response`, ...), exported directly via OTLP and ingested through Loki's native OTLP endpoint. Now mainly useful for the two things Tempo spans don't carry: `tool_input_size_bytes`/`tool_result_size_bytes` (payload sizes), and cross-checking/backfilling if a trace turns out incomplete (see "Trace completeness" below). `user_prompt`/`assistant_response` bodies stay `"<REDACTED>"` unless `OTEL_LOG_USER_PROMPTS`/`OTEL_LOG_ASSISTANT_RESPONSES` are set, and even then are capped at 60KB -- don't rely on this stream for full conversation content.
- **Loki, `{job="claude-code-sessions"}`** -- full session transcripts, tailed from `~/.claude/projects/*/*.jsonl` by Grafana Alloy. This is the only source for untruncated tool-call input/output and full conversation content.

Query all three through the official `grafana` MCP server (`query_prometheus`, `query_loki_logs`, `list_prometheus_metric_names`; for Tempo: `tempo_traceql-search`, `tempo_traceql-metrics-instant`/`-range`, `tempo_get-trace`, `tempo_get-attribute-names`, `tempo_docs-traceql`). The Tempo datasource's `uid` is `tempo` (confirmed 2026-07-07 via `list_datasources`).

## Usage summary dashboard (token/cost/active-time/session-count/tool-frequency)

For questions like "how much have I used today/this week", "what's my cost breakdown", "how productive was today" -- anything wanting the headline usage numbers rather than a specific narrow figure -- don't reconstruct all of it from scratch with a chain of `query_prometheus`/`query_loki_logs` calls. A bundled dashboard (`docker/grafana-dashboard-claude-code-usage.json`, uid `claude-code-usage-summary`) already has these panels wired up, adjustable to any time range via Grafana's picker. Confirmed 2026-07-06: answering this kind of question by hand took ~10 separate tool calls (one per metric/breakdown); that cost is the reason this dashboard exists.

Preferred pattern: run at most one or two `query_prometheus`/`query_loki_logs` calls for the specific headline number(s) the user asked about (if any), then call `generate_deeplink` with `resourceType: "dashboard"`, `dashboardUid: "claude-code-usage-summary"`, and a `timeRange` matching what was asked (e.g. `{"from": "now/d", "to": "now"}` for "today" -- see calendar-day note below, `{"from": "now-7d", "to": "now"}` for "this week"), and hand the link back for the visual/detailed breakdown. Don't re-derive each panel's PromQL/LogQL by hand when a link to the already-built panel will do.

**"Today" means calendar day, not a rolling 24h window** (decided 2026-07-08, per `docs/scenarios.md` scenario 4). `now/d` in a `generate_deeplink` `timeRange` is Grafana's own relative-time syntax for "start of today," resolved server-side against the Grafana host's local timezone -- pass it as-is, no client-side math needed for the dashboard link. "This week"/"this month" are still rolling windows (`now-7d`, `now-30d`) -- only "today" has been redefined so far; revisit the others if the same mismatch shows up there.

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

**"Today" is the one case that needs a calendar-day window, not a fixed duration like `[24h]`.** Unlike `generate_deeplink` (which accepts Grafana's `now/d` relative-time syntax natively), `query_prometheus` has no such variable -- a PromQL range vector needs a literal duration. So for an in-chat "today" figure: get the current local time (e.g. `date +%H:%M`), compute elapsed time since local midnight, and use that as the literal range, e.g. if it's 15:37 local, `increase(claude_code_cost_usage_USD_total[15h37m])`. This only matters for the immediate chat answer; the dashboard link itself just takes `now/d`.

**Do not use `increase()` on `claude_code_session_count_total`** -- confirmed broken (2026-07-06, Claude Code v2.1.201): unlike the other three metrics, this one is emitted as a single fixed sample (value `1`) per unique `session_id` label, so each session gets its own flat, never-changing time series. `increase()` measures the delta *within* a series, which is always ~0 here regardless of how many sessions actually ran -- summing it across sessions still gives 0. To count sessions in a window, count distinct `session_id` series instead:

```promql
count(count by (session_id) (last_over_time(claude_code_session_count_total[24h])))
```

Also treat this metric as an approximate lower bound, not authoritative: it's emitted once at session start with no repeat, so it's more fragile than the continuously-re-exported counters (e.g. to a startup race with the OTLP exporter). Confirmed 2026-07-06: a session with heavy, clearly-active `claude_code_token_usage_tokens_total` data had zero `claude_code_session_count_total` samples anywhere in the 7-day retention window. If a session count looks suspiciously low, cross-check with `count(count by (session_id) (last_over_time(claude_code_token_usage_tokens_total[<range>])))`, which is more reliable since it's tied to a continuously-repeated counter.

## Tool-call frequency and duration

Use Tempo TraceQL metrics against `claude_code.tool` spans, not hand-rolled LogQL -- Tempo has `tool_name`/`success`/`duration` as native span fields (no `unwrap` needed), and supports percentiles LogQL can't do cleanly. Via `tempo_traceql-metrics-instant`/`-range` (`datasourceUid: "tempo"`):

```
{ resource.service.name = "claude-code" && name = "claude_code.tool" } | count_over_time() by (span.tool_name)
{ resource.service.name = "claude-code" && span.tool_name != nil && span.success = "false" } | count_over_time() by (span.tool_name)
{ resource.service.name = "claude-code" && span.tool_name != nil } | quantile_over_time(span:duration, .50, .95, .99) by (span.tool_name)
{ resource.service.name = "claude-code" && span:status = error } | rate() by (span.tool_name)
```

Add `&& span.session.id = "<id>"` to scope any of these to one session (matches the `session_id` label used in Loki/Prometheus, so it's a direct cross-reference key -- confirmed 2026-07-07 by filtering a known session's `session.id` and getting the expected per-tool counts back). Use `tempo_get-attribute-names` if a query returns nothing -- attribute names can shift with Claude Code versions, same caveat as the Prometheus metric names above.

**3-hour cap on TraceQL metrics queries**: confirmed 2026-07-07 -- `tempo_traceql-metrics-instant`/`-range` reject any `start`/`end` spanning more than 3h with `metrics query time range exceeds the maximum allowed duration of 3h0m0s`. `tempo_traceql-search` (non-metrics) doesn't have this cap. For "today"/"this week"-scale tool-frequency questions, either issue multiple 3h queries and sum client-side, or just use the Loki fallback below for that window instead -- don't retry a >3h metrics query with a different query shape, the range itself is the problem.

Only fall back to Loki (`{service_name="claude-code"} | event_name="tool_result"`, `count_over_time`) for things Tempo spans don't carry: `tool_input_size_bytes`/`tool_result_size_bytes` (payload sizes). E.g.:

```
sum by (tool_name) (count_over_time({service_name="claude-code"} | event_name="tool_result" [24h]))
```

(`event_name` is structured metadata, not an indexed label, so it must be a pipeline filter `| event_name=...`, not a stream selector.)

This whole area used to run through a bundled JSON-parsing script (scanning JSONL `tool_use` blocks), then through Loki LogQL once the OTel `tool_result` log event shipped as one flat event per call. Tempo traces are now the more native fit for frequency/duration/error-rate questions specifically, since they carry duration and status as first-class span fields rather than an attribute needing `unwrap`; don't reintroduce custom parsing or prefer LogQL here when TraceQL covers it directly.

## Turn/interaction structure (waterfall, "why was this slow", retries)

For questions about a specific turn's internal structure -- why it was slow, whether a tool was retried, error propagation from a tool up to the interaction -- reconstruct the waterfall from Tempo instead of manually cross-referencing Loki/JSONL timestamps:

1. Find the trace: `tempo_traceql-search` with `{ resource.service.name = "claude-code" && span.session.id = "<id>" }` (add `&& span.interaction.sequence = <n>` if you know which turn, or narrow the time range) against `datasourceUid: "tempo"`.
2. Pull the full span tree: `tempo_get-trace` with that `trace_id`. This gives the actual parent/child waterfall (`interaction` -> `llm_request`/`tool` -> `tool.execution`/`tool.blocked_on_user`) with real durations and parent-child timing, rather than something reconstructed by hand from flat log lines.
3. `attempt` on a span indicates a retried call; `span:status = error` / the `error` attribute marks failures; `tool_use_id`/`gen_ai.tool.call.id` is the same ID used by the JSONL `tool_result`/`tool_decision` entries, so only cross into Loki/JSONL if you need the actual prompt/tool-argument content behind a given span (Tempo redacts that the same way the Loki log stream does).

### Trace completeness ("root span not yet received")

A `tempo_traceql-search` result can show `rootServiceName: "<root span not yet received>"` for a trace. Confirmed 2026-07-07: this is normal for a trace whose `claude_code.interaction` root span hasn't closed yet (it only closes when the turn finishes), not a data-loss bug -- it's almost always the turn currently in progress. If it persists for a turn that has clearly finished, that's the actual anomaly worth investigating (check Loki `tool_result` events for the same window as a cross-check before assuming Tempo dropped data).

Known gap (per README.md, tracking [anthropics/claude-code#53954](https://github.com/anthropics/claude-code/issues/53954), closed as not planned): under the Agent SDK's `query()` / ACP streaming-json path, `claude_code.interaction`/`tool` spans are missing entirely and only `llm_request` spans show up. Not expected to affect normal CLI/VS Code usage, but worth ruling out if a session's trace looks unusually sparse.

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
