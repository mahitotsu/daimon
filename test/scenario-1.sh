#!/usr/bin/env bash
# Scenario 1: 離席中・自律実行の振り返り -- see SPEC.md.
#
# The only scenario with an explicit setup step: the PRFAQ's premise ("寝て
# いる間に別セッションで走らせていたタスク") requires a separate execution
# unit to exist before the check can mean anything, and it can't be assumed
# to already be there. So this spawns a real, throwaway, read-only Task
# subagent first (session persistence deliberately left ON here -- Alloy
# only tails what actually lands under ~/.claude/projects), waits for Alloy
# to pick up the JSONL, then asks the actual scenario question from a fresh,
# unpersisted session.
#
# The execution question stays generic/situational (no quote, no topic
# hint) -- quoting the setup's own summary back into the question was tried
# and rejected (confirmed 2026-07-09): handing the model the full answer
# text gave it no reason to actually search Loki at all, and it just
# reasoned from the quote ("this is a new session, I can't access that
# task's log directly, I'll only tell you what the report text says")
# instead of looking anything up -- which defeats the entire point of this
# scenario.
#
# Instead, the setup's captured summary is used only as ground truth
# handed to the JUDGE (not the execution question), to check whether the
# response's content actually matches the real fixture. This is how the
# recency confound documented in SPEC.md (recency-based discovery finding
# this suite's own live driving conversation instead of the throwaway
# fixture, since that conversation's JSONL is always more recently modified)
# gets surfaced: instead of silently avoiding it, a wrong-session answer
# now fails a concrete, checkable criterion rather than being an
# unverifiable PARTIAL.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-1"
echo "== $SCENARIO_ID: away-from-keyboard / autonomous review ==" >&2

echo "-- setup: spawning a throwaway read-only subagent --" >&2
setup_summary="$(run_prompt_persisted \
  "Task/Agentツールでサブエージェントに委任して、docs/配下のMarkdownファイルにリンク切れがないか読み取り専用で調査させて。完了したら結果を一言で報告して。" \
  sonnet)"
echo "-- setup summary (ground truth for judging, not shown to the execution call): $setup_summary --" >&2

echo "-- waiting for Alloy to tail the new session JSONL into Loki --" >&2
sleep 20

PROMPT="さっき裏で走らせてたタスクは結局どこまでやってくれた?想定外のことはなかった?"
RUBRIC="- 今のセッションとは別の実行単位(サブエージェント)の内容だと、こちらから何も指定していないのに正しく特定できていること
- 何をしたかが、Claude自身の記憶ではなく実際の実行ログ(JSONL)からの要約として書かれていること(単なる相槌や一般論ではなく具体的な作業内容が書かれていること)
- 「想定外のことはなかったか」という問いにも、同じ回答の中で具体的に答えていること
- 応答が生ログの引用の羅列ではなく、要約された自然言語になっていること
- 【正解データとの整合性】実際にセットアップで実行され、次のように報告されたタスクの内容と、応答が食い違っていないこと(応答がこれと明らかに違う話題――例えば今進行中の別の会話について述べている場合は、このセッション取り違えとして基準を満たしていないとみなす): ${setup_summary}"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$PROMPT" "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
