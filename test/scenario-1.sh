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
# unpersisted session with no hint about what just ran.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-1"
echo "== $SCENARIO_ID: away-from-keyboard / autonomous review ==" >&2

echo "-- setup: spawning a throwaway read-only subagent --" >&2
run_prompt_persisted \
  "Task/Agentツールでサブエージェントに委任して、docs/配下のMarkdownファイルにリンク切れがないか読み取り専用で調査させて。完了したら結果を一言で報告して。" \
  sonnet >/dev/null

echo "-- waiting for Alloy to tail the new session JSONL into Loki --" >&2
sleep 20

PROMPT="さっき裏で走らせていたタスクは結局どこまでやってくれた?想定外のことはなかった?"
RUBRIC="- 今のセッションとは別の実行単位(サブエージェント)の内容だと、こちらから何も指定していないのに正しく特定できていること
- 何をしたかが、Claude自身の記憶ではなく実際の実行ログ(JSONL)からの要約として書かれていること(単なる相槌や一般論ではなく具体的な作業内容が書かれていること)
- 「想定外のことはなかったか」という問いにも、同じ回答の中で具体的に答えていること
- 応答が生ログの引用の羅列ではなく、要約された自然言語になっていること"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
