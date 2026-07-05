#!/usr/bin/env python3
"""
Count Claude Code tool-call frequency over a time range.

Queries Loki (fed by Grafana Alloy tailing ~/.claude/projects/*.jsonl) for
lines containing "tool_use", parses each line as a Claude Code transcript
entry, and tallies tool_use blocks by tool name and by session. This
aggregation isn't available as a generic Grafana/Loki MCP tool -- the
official grafana-mcp only returns raw matching log lines -- so it's kept
as a small script instead of duplicating this logic in a custom MCP server.

Usage:
  tool_usage.py --since 2026-07-05T00:00:00Z [--until ...] [--limit 300]
  tool_usage.py --hours 24
"""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

LOKI_URL = "http://localhost:3100"
LOKI_JOB = "claude-code-sessions"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--since", help="ISO 8601 start time")
    p.add_argument("--until", help="ISO 8601 end time (default: now)")
    p.add_argument("--hours", type=float, help="shorthand: last N hours (default 24 if --since omitted)")
    p.add_argument("--limit", type=int, default=300, help="max transcript lines to scan (default 300)")
    return p.parse_args()


def resolve_range(args):
    until = datetime.now(timezone.utc) if not args.until else datetime.fromisoformat(args.until.replace("Z", "+00:00"))
    if args.since:
        since = datetime.fromisoformat(args.since.replace("Z", "+00:00"))
    else:
        since = until - timedelta(hours=args.hours or 24)
    if since > until:
        sys.exit(f"error: since ({since.isoformat()}) must not be after until ({until.isoformat()})")
    return since, until


def loki_query_range(logql, since, until, limit):
    params = {
        "query": logql,
        "start": str(int(since.timestamp() * 1e9)),
        "end": str(int(until.timestamp() * 1e9)),
        "limit": str(limit),
        "direction": "forward",
    }
    url = f"{LOKI_URL}/loki/api/v1/query_range?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as res:
        body = json.load(res)
    if body.get("status") != "success":
        sys.exit(f"error: loki query failed: {body}")
    lines = []
    for stream in body["data"]["result"]:
        session_path = stream["stream"].get("filename", "")
        for ts_ns, line in stream["values"]:
            lines.append((ts_ns, session_path, line))
    return lines


def session_id_from_path(path):
    return path.rsplit("/", 1)[-1].removesuffix(".jsonl") if path else path


def main():
    args = parse_args()
    since, until = resolve_range(args)
    try:
        lines = loki_query_range(f'{{job="{LOKI_JOB}"}} |= "tool_use"', since, until, args.limit)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        if "ResourceExhausted" in body:
            sys.exit(
                f"error: too much transcript data for one query ({e.code}): {body}\n"
                "Retry with a narrower --since/--until range or a smaller --limit."
            )
        sys.exit(f"error: loki query failed ({e.code}): {body}")

    counts = {}
    by_session = {}
    for _, session_path, line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use" and isinstance(block.get("name"), str):
                name = block["name"]
                counts[name] = counts.get(name, 0) + 1
                sid = session_id_from_path(session_path)
                by_session.setdefault(sid, {})
                by_session[sid][name] = by_session[sid].get(name, 0) + 1

    print(json.dumps({
        "since": since.isoformat(),
        "until": until.isoformat(),
        "totalByTool": counts,
        "bySession": by_session,
    }, indent=2))


if __name__ == "__main__":
    main()
