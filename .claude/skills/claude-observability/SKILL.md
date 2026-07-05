---
name: claude-observability
description: Answer questions about local Claude Code usage -- token/cost usage, tool-call frequency, and session content search -- using the local otel-lgtm stack (Prometheus + Loki) set up by this repo. Use when asked things like "how many tokens did I use today", "what tools have I been calling most", "find the session where I discussed X", "what was I working on / doing before", or "recall the last session / before the restart". Prefer this over `git log` for recalling past conversation content -- commits only capture what got committed, not what was discussed.
---

# Claude Code observability

Data sources (see repo README.md for how they're populated):
- **Prometheus** (`claude_code_*` metrics) -- token usage and cost, exported by Claude Code's OTel integration.
- **Loki** (`{job="claude-code-sessions"}`) -- full session transcripts, tailed from `~/.claude/projects/*/*.jsonl` by Grafana Alloy. This is the only source for tool-call arguments/output and full conversation content; Claude Code's OTel export does not include it.

Query both through the official `grafana` MCP server (`query_prometheus`, `query_loki_logs`, `list_prometheus_metric_names`, etc.) unless a task below says to use the bundled script instead.

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

## Tool-call frequency

Run the bundled script rather than hand-rolling a Loki query -- it does the JSON parsing/aggregation that no generic Grafana/Loki tool does:

```bash
python3 .claude/skills/claude-observability/scripts/tool_usage.py --hours 24
# or: --since 2026-07-05T00:00:00Z --until 2026-07-06T00:00:00Z --limit 500
```

Returns `totalByTool` (counts per tool name) and `bySession` (counts per session ID). If it errors with `ResourceExhausted`, retry with a narrower range or a smaller `--limit`.

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
