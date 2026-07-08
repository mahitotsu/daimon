#!/usr/bin/env bash
# Scenario 2: 過去の対話の想起 -- see SPEC.md.
#
# No setup step: relies on real, already-existing project history rather
# than a synthesized fixture (see lib.sh header for why). Loki's compactor
# retention is disabled for this stack (confirmed 2026-07-08 via
# `curl localhost:3100/config`: `retention_enabled: false`), so session
# content doesn't age out the way Prometheus's 15d TSDB retention does --
# any real past topic stays findable indefinitely, capped only by local disk
# space.
#
# The topic is picked dynamically at run time via lib.sh's
# pick_recall_topic (a real session's own auto-generated `ai-title`),
# NOT hardcoded -- a hardcoded topic string decays as soon as it gets
# written into a doc/comment, since the execution call can then answer from
# that pre-existing text instead of actually searching Loki (confirmed
# 2026-07-09: this burned two hardcoded topics in the same sitting -- see
# git history of this file). Picking from whatever's actually in Loki at run
# time sidesteps that: it's never the same topic twice in a row, and it's
# never something this repo's own docs happened to just absorb.
#
# Known, accepted limitation (confirmed 2026-07-09, still applies even with
# dynamic topic selection): not every session has a clean "decision + reason"
# to recall -- some are simple mechanical sessions ("コミットしてください").
# The rubric below is written to accept "there was no real decision to
# recall, and the response correctly said so" as satisfying the
# reason-criterion, rather than demanding a decision+reason pair that may
# not exist in the picked session.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SCENARIO_ID="scenario-2"
echo "== $SCENARIO_ID: recall a past conversation ==" >&2

TOPIC="$(pick_recall_topic)"
if [ -z "$TOPIC" ]; then
  echo "SKIP: no past session history (older than 6h) found for this project -- too new to test recall" >&2
  exit 0
fi
echo "-- picked topic: $TOPIC --" >&2

PROMPT="前に「${TOPIC}」について相談したと思うけど、結局どういう話になった?決まったことがあれば、その理由も含めて教えて。"
RUBRIC="- セッションIDや日付を一切与えていない(トピックの手がかりだけの)問いかけに対して、内容が実際に該当する過去セッションと一致していること。回答文中で検索方法そのものを説明している必要はない -- 結果として正しいセッションの内容を反映していれば満たされる
- そのセッションで実際に何らかの結論・決定があった場合は、結論だけでなく理由も含まれていること。セッションの内容が単純な事実確認・作業依頼で、そもそも『決定とその理由』と呼べるものが無い場合は、その旨を正直に述べていれば良い(無理に理由をでっち上げていないこと)
- 生ログの引用そのままではなく、要約として返っていること
- 明らかな誤り(セッションの実際の内容と食い違う断定)がないこと"

response="$(run_prompt "$PROMPT" sonnet)"
verdict="$(judge "$PROMPT" "$response" "$RUBRIC")"
log_result "$SCENARIO_ID" "$verdict"
echo "$verdict" | jq .
