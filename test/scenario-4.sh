#!/usr/bin/env bash
# Scenario 4: コスト・トークン消費の実績把握 -- see SPEC.md.
#
# No setup step: unlike scenario 1, this doesn't need a fixture we control
# the shape of -- it just needs *some* recent usage to exist in the window
# being asked about, and this very script's own execution call (below) is
# real, freshly-metered usage that satisfies that. Synthesizing anything
# beyond that would only add noise to the real personal cost/token numbers
# this tool exists to report accurately (see lib.sh header).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-4"
echo "== $SCENARIO_ID: cost/token usage ==" >&2

PROMPT="今日のコストはどれくらい?モデル別の内訳も教えて。"
RUBRIC="- 具体的なコストの数値(USD)がチャット上の回答に含まれていること
- 同じ回答の中に、Grafanaダッシュボードへのリンクが含まれていること
- モデル別の内訳が示されていること
- 『今日』が暦日(ローカル深夜0時起点)として扱われていて、単純な直近24時間のローリング窓と混同されていないこと"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
