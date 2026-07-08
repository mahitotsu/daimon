#!/usr/bin/env bash
# Runs all 5 regression checks described in SPEC.md back to back and prints
# a summary. Each scenario makes 2 real `claude -p` calls (execute + judge),
# plus scenario 1's extra setup call -- about 11 calls per full run. Not
# meant for tight/high-frequency cron loops; run it after touching
# .claude/skills/claude-observability/SKILL.md, the dashboard JSON, or the
# Alloy config, per CLAUDE.md's regression-check guidance.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

check_connectivity

overall_pass=true
for n in 1 2 3 4 5; do
  echo
  if ! ./scenario-"$n".sh; then
    echo "scenario-$n.sh exited with an error (a script/tool failure, not just a FAIL verdict)" >&2
    overall_pass=false
  fi
done

echo
echo "== summary (last 5 entries in $RESULTS_LOG) =="
tail -n 5 "$RESULTS_LOG" | jq -r '"\(.scenario): \(.verdict) -- \(.summary)"'

if [ "$overall_pass" = true ]; then
  exit 0
else
  exit 1
fi
