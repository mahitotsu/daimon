#!/usr/bin/env bash
# Scenario 5: 積み重ねてきた実績の実感 -- see SPEC.md.
#
# No setup step, same reasoning as scenario 4: this queries cumulative
# counters that already exist from real usage; nothing needs to be seeded.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-5"
echo "== $SCENARIO_ID: cumulative usage ==" >&2

PROMPT="これまでClaude Codeをどれだけ使い込んできた?セッション数と使用時間を教えて。"
RUBRIC="- セッション数が、claude_code_session_count_totalへのincrease()のような既知の不具合のある集計方法ではなく、正しい方法(あるいは少なくともtoken_usageベースの値とのクロスチェック)に基づいていそうなこと。回答文面からは集計方法の詳細までは分からないこともあるが、明らかに0や非現実的な値をそのまま報告していないこと
- 累計のアクティブ時間または利用時間に触れていること
- 『これまで全部』の範囲がPrometheusの保持期間(15日)を超える場合、その制約に触れて『全期間』であるかのように断定していないこと(15日以内に収まっている場合はこの点は問わない)
- Grafanaダッシュボードへのリンクが含まれていること"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
