#!/usr/bin/env bash
# Scenario 3: 手直し・訂正傾向の可視化 -- see SPEC.md.
#
# No setup step, and none is possible: AskUserQuestion is unconditionally
# denied under `claude -p` even with --permission-mode bypassPermissions
# (confirmed 2026-07-08 -- see lib.sh header), so a synthetic fixture can't
# be manufactured. This grades against whatever real AskUserQuestion history
# already exists in the project (12+ events confirmed as of 2026-07-08). If
# a project is too new to have any, the judge is instructed to mark that
# explicitly rather than accept a fabricated-sounding breakdown.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-3"
echo "== $SCENARIO_ID: correction-tendency visibility ==" >&2

PROMPT="これまでの作業で、Claude Codeに安心して任せられている領域と、まだ細かい指摘・訂正が多い領域はどこ?"
RUBRIC="- 印象論ではなく、履歴から機械的に取り出せる具体的なシグナル(例:AskUserQuestionの回答が推奨案通りだったか、別の選択肢だったか、自由記述で退けたか)に基づいていること
- 単一の曖昧な一文ではなく、何らかの内訳・分類が示されていること
- この手法の限界(AskUserQuestionを介さない暗黙の訂正は拾えない、サンプル数が少ない場合は参考程度であること)に触れているか、少なくとも過度に断定的な言い切りになっていないこと
- 対象プロジェクトに十分な履歴が無い場合は、その旨を正直に述べていて、無理に断定的な答えを作っていないこと"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
