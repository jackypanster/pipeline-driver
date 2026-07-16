#!/usr/bin/env bash
# Phase 3: the §7 route allowlist + §15 mechanical card validation + §6 authorization
# transitions, all through the SHIPPED watch CLI (no internal hooks). Hermetic:
# local bare remote + stub herdr + physical temp base.
# Run: bash test/coordinate-route.sh
set -u
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
. "$(cd "$(dirname "$0")" && pwd)/coord-lib.sh"

J="$TMP/journal.md"

# route_case <label> <from> <to> <status> <next-line> <expect> [card-spec…]
#   expect = a grep pattern that MUST appear (a typed command for happy dispatches,
#   or a fatal code) plus the polarity encoded by prefix: "RUN:<pat>" asserts the
#   pattern in runs.txt; "CODE:<pat>" asserts the fatal code in output + nonzero rc
#   + NO send. card-spec entries are "<nn>:<status>:<attempts>".
route_case() {
  local label=$1 from=$2 to=$3 status=$4 next=$5 expect=$6; shift 6
  fresh; cl_seed_clones "$T"
  cl_mkjournal "$J" "$from" "$to" "$status" "$next"
  cl_feature "$T" hello "$J"
  local cs
  for cs in "$@"; do cl_card "$T" hello "${cs%%:*}" "$(printf '%s' "$cs" | cut -d: -f2)" "${cs##*:}"; done
  cl_stub_herdr "$T"
  local out rc
  out=$(cl_run_watch "$T" 2>&1); rc=$?
  case "$expect" in
    RUN:*)
      if grep -q "${expect#RUN:}" "$T/runs.txt" 2>/dev/null; then ok "$label"
      else bad "$label" "expected typed '${expect#RUN:}'; runs: $(cat "$T/runs.txt" 2>/dev/null || echo none); out: $(printf '%s' "$out" | grep -iE 'fatal|code' | head -3)"; fi ;;
    CODE:*)
      if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "${expect#CODE:}" && [ ! -s "$T/runs.txt" ]; then ok "$label"
      else bad "$label" "rc=$rc; runs=$(cat "$T/runs.txt" 2>/dev/null || echo none); out: $(printf '%s' "$out" | grep -iE 'fatal|code:' -A2 | head -6)"; fi ;;
  esac
}

# ===== §7 happy rows (typed dispatches; PI rows live in coordinate-span.sh) =====
route_case "prd->arch dispatches CC /pipeline-arch" "$CL_GENESIS" prd completed "Run pipeline-arch" \
  "RUN:/pipeline-arch repo="
route_case "arch->task dispatches CC /pipeline-task" prd arch completed "Run pipeline-task" \
  "RUN:/pipeline-task repo="
route_case "hunt->task dispatches CC /pipeline-task" hunt task completed "Run pipeline-task" \
  "RUN:/pipeline-task repo="
route_case "impl->review (all cards review) dispatches CODEX" impl review completed "Run pipeline-review" \
  'RUN:pipeline-review repo=' 01:review:1 02:review:0
route_case "impl->hunt blocked dispatches CC /pipeline-hunt" impl hunt blocked "Run pipeline-hunt" \
  "RUN:/pipeline-hunt repo=" 01:blocked:3
# the integration-report variant needs the report committed before watch runs — do it manually:
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" review hunt blocked "Run pipeline-hunt"
cl_feature "$T" hello "$J"
cl_card "$T" hello 01 review 1
( cd "$T/obs"; mkdir -p .pipeline/hello/reviews; echo x > .pipeline/hello/reviews/integration-01.md
  git add -A && git commit -qm rep && git push -q origin main ) >/dev/null 2>&1
cl_stub_herdr "$T"
out=$(cl_run_watch "$T" 2>&1) || true
if grep -q "/pipeline-hunt repo=" "$T/runs.txt" 2>/dev/null; then
  ok "review->hunt with integration-NN.md (no blocked card) dispatches hunt"
else bad "hunt integration report" "runs=$(cat "$T/runs.txt" 2>/dev/null || echo none)"; fi

# NB the earlier review->hunt case above (card review:1, no report) must actually
# FAIL card validation — rewrite it as the negative it is:
route_case "review->hunt blocked WITHOUT blocked card or report -> CARD_STATE_INVALID" review hunt blocked "Run pipeline-hunt" \
  "CODE:CARD_STATE_INVALID" 01:review:1

# ===== merge gate + terminal (asserted on the audit/ledger files) =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" review review completed "Await human-direct merge confirmation in this reviewer session."
cl_feature "$T" hello "$J"; cl_card "$T" hello 01 review 1; cl_stub_herdr "$T"
CL_WATCH_BUDGET=4 cl_run_watch "$T" >/dev/null 2>&1 || true
fd="$(cl_featdir "$T" hello)"
if grep -q '"event":"waiting_human_merge"' "$fd/events.jsonl" 2>/dev/null \
   && [ "$(jq -r .delivery "$fd/ledger.json" 2>/dev/null)" = waiting ] \
   && [ ! -s "$T/runs.txt" ]; then
  ok "merge-wait marker -> waiting_human_merge + ledger waiting + NO send (scenario 7)"
else bad "merge-wait" "events: $(cat "$fd/events.jsonl" 2>/dev/null | tail -2); ledger: $(cat "$fd/ledger.json" 2>/dev/null)"; fi

fresh; cl_seed_clones "$T"
cl_mkjournal "$J" review done completed "Feature complete."
cl_feature "$T" hello "$J"; cl_card "$T" hello 01 done 1; cl_stub_herdr "$T"
CL_WATCH_BUDGET=4 cl_run_watch "$T" >/dev/null 2>&1 || true
fd="$(cl_featdir "$T" hello)"
if grep -q '"event":"completed"' "$fd/events.jsonl" 2>/dev/null && [ ! -e "$fd/ledger.json" ] && [ ! -s "$T/runs.txt" ]; then
  ok "review->done -> completed event + ledger cleared + idle (scenario 8 tail)"
else bad "terminal done" "events: $(tail -2 "$fd/events.jsonl" 2>/dev/null); ledger: $(cat "$fd/ledger.json" 2>/dev/null || echo absent)"; fi

# ===== illegal transitions / NEXT (§7 allowlist is closed) =====
route_case "impl->review · failed -> TRANSITION_ILLEGAL" impl review failed "Run pipeline-review" \
  "CODE:TRANSITION_ILLEGAL" 01:review:1
route_case "unknown stage in NEXT -> NEXT_INVALID" impl review completed "Run pipeline-deploy" \
  "CODE:NEXT_INVALID" 01:review:1
route_case "merge-wait marker on a non-review transition -> NEXT_INVALID" impl impl completed \
  "Await human-direct merge confirmation in this reviewer session." \
  "CODE:NEXT_INVALID" 01:todo:1
route_case "prose NEXT (no Run/marker) -> NEXT_INVALID" prd arch completed "please continue with the architecture" \
  "CODE:NEXT_INVALID"
route_case "run-impl with to=done · blocked -> TRANSITION_ILLEGAL" task done blocked "Run pipeline-impl" \
  "CODE:TRANSITION_ILLEGAL" 01:todo:0
route_case "review->impl · completed (never legal) -> TRANSITION_ILLEGAL" review impl completed "Run pipeline-impl" \
  "CODE:TRANSITION_ILLEGAL" 01:todo:0
route_case "hunt->task with NEXT=run-impl (route disagreement) -> TRANSITION_ILLEGAL" hunt task completed "Run pipeline-impl" \
  "CODE:TRANSITION_ILLEGAL" 01:todo:0

# ===== §15 card evidence =====
route_case "impl->review with a still-todo card -> CARD_STATE_INVALID" impl review completed "Run pipeline-review" \
  "CODE:CARD_STATE_INVALID" 01:review:1 02:todo:0
route_case "review->impl failed with NO todo card -> CARD_STATE_INVALID" review impl failed "Run pipeline-impl" \
  "CODE:CARD_STATE_INVALID" 01:review:1
route_case "todo card with attempts>=3 (counter/status disagreement) -> CARD_STATE_INVALID" review impl failed "Run pipeline-impl" \
  "CODE:CARD_STATE_INVALID" 01:todo:5
route_case "blocked card with attempts<3 -> CARD_STATE_INVALID" impl hunt blocked "Run pipeline-hunt" \
  "CODE:CARD_STATE_INVALID" 01:blocked:1
route_case "non-integer attempts -> CARD_STATE_INVALID" review impl failed "Run pipeline-impl" \
  "CODE:CARD_STATE_INVALID" 01:todo:x

# ===== §6 authorization =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J" bogus
cl_stub_herdr "$T"
out=$(cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'CONTROL_MALFORMED' && [ ! -s "$T/runs.txt" ]; then
  ok "control.json mode=bogus -> CONTROL_MALFORMED (never downgraded to human)"
else bad "bogus mode" "rc=$rc; $(printf '%s' "$out" | grep -i fatal -A3 | head -5)"; fi

# human mode: observed, never dispatched (scenario 15 counterpart lives in watch suite).
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J" human
cl_stub_herdr "$T"
CL_WATCH_BUDGET=3 cl_run_watch "$T" >/dev/null 2>&1 || true
if [ ! -s "$T/runs.txt" ]; then ok "mode=human -> observed, never dispatched (scenario 15)"
else bad "human observe-only" "typed: $(cat "$T/runs.txt")"; fi

# AUTOMATION_AUTH_CHANGED: dispatch once (coordinated; the default idle stub then
# fatals AGENT_ENDED_WITHOUT_HANDOFF, leaving a sent ledger + halt), then flip
# control to human — a RESTARTED watch must fatal AUTOMATION_AUTH_CHANGED, never
# treat the downgrade as a silent pause.
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"
cl_stub_herdr "$T"
cl_run_watch "$T" >/dev/null 2>&1 || true
fd="$(cl_featdir "$T" hello)"
if [ ! -f "$fd/ledger.json" ]; then bad "auth-changed setup" "no ledger after first dispatch"; else
( cd "$T/obs"; printf '{"schema_version":1,"mode":"human","merge_gate":"human-direct"}' > .pipeline/hello/control.json
  git add -A && git commit -qm downgrade && git push -q origin main ) >/dev/null 2>&1
rm -f "$fd/halt.json" 2>/dev/null || true   # operator resolved the prior fatal (resume equivalent)
out=$(cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AUTOMATION_AUTH_CHANGED'; then
  ok "control downgraded after dispatch -> AUTOMATION_AUTH_CHANGED across a restart"
else bad "AUTOMATION_AUTH_CHANGED" "rc=$rc; $(printf '%s' "$out" | grep -i fatal -A3 | head -5)"; fi
fi

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
