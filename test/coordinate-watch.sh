#!/usr/bin/env bash
# Phase 3: watch lifecycle semantics — lock, no-redeliver, ref-moved discard,
# AGENT_ENDED_WITHOUT_HANDOFF, STAGE_TIMEOUT, graceful SIGTERM. Hermetic.
# Run: bash test/coordinate-watch.sh
set -u
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
. "$(cd "$(dirname "$0")" && pwd)/coord-lib.sh"
J="$TMP/journal.md"

# ===== 1. (scenario 9) no-redeliver while the journal is unchanged: the stub
#      reports "working" once the dispatch was typed (WORKING_AFTER_RUN), so watch
#      sits in WAITING across many cycles. Exactly ONE typed command. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
CL_WATCH_EXTRA="HERDR_STUB_WORKING_AFTER_RUN=1" CL_WATCH_BUDGET=6 cl_run_watch "$T" >/dev/null 2>&1 || true
n=$(wc -l < "$T/runs.txt" 2>/dev/null | awk '{print $1}')
if [ "${n:-0}" -eq 1 ]; then ok "unchanged journal -> exactly one send across many cycles (scenario 9)"
else bad "no-redeliver" "typed ${n:-0} commands: $(cat "$T/runs.txt" 2>/dev/null)"; fi

# ===== 2. AGENT_ENDED_WITHOUT_HANDOFF: default idle stub — dispatched stage reads
#      authoritatively idle with the journal unchanged on the next cycle. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
out=$(cl_run_watch "$T" 2>&1); rc=$?
fd="$(cl_featdir "$T" hello)"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AGENT_ENDED_WITHOUT_HANDOFF' \
   && [ "$(jq -r .code "$fd/halt.json" 2>/dev/null)" = "AGENT_ENDED_WITHOUT_HANDOFF" ]; then
  ok "idle + unchanged journal after dispatch -> AGENT_ENDED_WITHOUT_HANDOFF + halt.json"
else bad "AGENT_ENDED" "rc=$rc; halt=$(cat "$fd/halt.json" 2>/dev/null); $(printf '%s' "$out" | grep -i fatal -A2 | head -4)"; fi

# ===== 3. authoritative blocked pane mid-stage -> same fatal, immediately. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
obs=$(git -C "$T/obs" rev-parse origin/main)
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"sent","sent_at":%s}' "$obs" "$(date +%s)" > "$fd/ledger.json"
chmod 600 "$fd/ledger.json"
out=$(CL_WATCH_EXTRA="HERDR_STUB_STATE=blocked" cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AGENT_ENDED_WITHOUT_HANDOFF'; then
  ok "authoritatively blocked pane mid-stage -> immediate fatal (no stage-timeout wait)"
else bad "blocked mid-stage" "rc=$rc; $(printf '%s' "$out" | grep -i fatal -A2 | head -4)"; fi

# ===== 4. STAGE_TIMEOUT: sent long ago (stale sent_at), pane working. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
obs=$(git -C "$T/obs" rev-parse origin/main)
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"sent","sent_at":%s}' "$obs" "$(( $(date +%s) - 4000 ))" > "$fd/ledger.json"
chmod 600 "$fd/ledger.json"
out=$(CL_WATCH_EXTRA="HERDR_STUB_STATE=working" cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'STAGE_TIMEOUT'; then
  ok "stage exceeded STAGE_TIMEOUT_SECS -> STAGE_TIMEOUT fatal"
else bad "STAGE_TIMEOUT" "rc=$rc; $(printf '%s' "$out" | grep -i fatal -A2 | head -4)"; fi

# ===== 5. (scenario 14) ref moved before send -> the stale decision is DISCARDED:
#      hold the pane busy so wait_ready spins, advance the remote meanwhile; the
#      envelope eventually typed must carry the NEW seq/commit, never the old. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
sed -i.bak 's/^PANE_READY_TIMEOUT_MS=.*/PANE_READY_TIMEOUT_MS=20000/' "$T/cfg" && rm -f "$T/cfg.bak"
echo 30 > "$T/busy"          # a bounded busy window while we advance the remote
CL_WATCH_EXTRA="HERDR_STUB_BUSY_N_FILE=$T/busy" CL_WATCH_BUDGET=30 cl_spawn_watch "$T"
sleep 1
cl_mkjournal "$J" prd arch completed "Run pipeline-task" 2
cl_commit_journal "$T" hello "$J"
newc=$(git -C "$T/obs" rev-parse origin/main)
for _i in $(seq 1 250); do [ -s "$T/runs.txt" ] && break; sleep 0.1; done
kill -TERM "$CL_WATCH_PID" 2>/dev/null || true; wait "$CL_WATCH_PID" 2>/dev/null || true
if [ -s "$T/runs.txt" ] && grep -q "expected_seq=2" "$T/runs.txt" && grep -q "expected_commit=$newc" "$T/runs.txt" \
   && ! grep -q "expected_seq=1" "$T/runs.txt" && ! grep -q "pipeline-arch" "$T/runs.txt"; then
  ok "ref moved mid-decision -> stale envelope never typed; new seq/commit dispatched (scenario 14)"
else bad "ref-moved discard" "typed: $(cat "$T/runs.txt" 2>/dev/null || echo none)"; fi

# ===== 6. graceful SIGTERM: watch_stopped audited, lock released. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
CL_WATCH_EXTRA="HERDR_STUB_WORKING_AFTER_RUN=1" cl_spawn_watch "$T"
fd="$(cl_featdir "$T" hello)"
for _i in $(seq 1 100); do [ -f "$fd/ledger.json" ] && break; sleep 0.1; done
kill -TERM "$CL_WATCH_PID" 2>/dev/null
for _i in $(seq 1 50); do kill -0 "$CL_WATCH_PID" 2>/dev/null || break; sleep 0.1; done
kill -9 "$CL_WATCH_PID" 2>/dev/null || true; wait "$CL_WATCH_PID" 2>/dev/null || true
if grep -q '"event":"watch_stopped"' "$fd/events.jsonl" 2>/dev/null && [ ! -d "$fd/lock" ]; then
  ok "SIGTERM -> watch_stopped audited + lock released"
else bad "graceful stop" "events tail: $(tail -1 "$fd/events.jsonl" 2>/dev/null); lock: $([ -d "$fd/lock" ] && echo held || echo released)"; fi

# ===== 7. LOCK_HELD: a live watcher's lock refuses a second watch. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
cl_feature "$T" hello "$J"; cl_stub_herdr "$T"
CL_WATCH_EXTRA="HERDR_STUB_WORKING_AFTER_RUN=1" cl_spawn_watch "$T"
fd="$(cl_featdir "$T" hello)"
for _i in $(seq 1 100); do [ -d "$fd/lock" ] && break; sleep 0.1; done
out=$(CL_WATCH_EXTRA="HERDR_STUB_WORKING_AFTER_RUN=1" cl_run_watch "$T" 2>&1); rc=$?
kill -TERM "$CL_WATCH_PID" 2>/dev/null || true; wait "$CL_WATCH_PID" 2>/dev/null || true
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'LOCK_HELD'; then
  ok "second watch against a live lock -> LOCK_HELD"
else bad "LOCK_HELD" "rc=$rc; $(printf '%s' "$out" | grep -i lock -A2 | head -4)"; fi

# ===== 8. no control.json at all -> observed, never dispatched, no state created. =====
fresh; cl_seed_clones "$T"
cl_mkjournal "$J" "$CL_GENESIS" prd completed "Run pipeline-arch"
( cd "$T/obs"; git checkout -q -b main 2>/dev/null || git checkout -q main
  mkdir -p .pipeline/hello
  printf '{"feature":"hello","stage":"prd"}' > .pipeline/current.json
  cp "$J" .pipeline/hello/journal.md
  git add -A && git commit -qm seed && git push -q origin main ) >/dev/null 2>&1
cl_stub_herdr "$T"
CL_WATCH_BUDGET=3 cl_run_watch "$T" >/dev/null 2>&1 || true
if [ ! -s "$T/runs.txt" ] && [ ! -d "$T/state" ]; then
  ok "absent control.json -> observe-only, nothing typed, no state created (scenario 15)"
else bad "no-control observe" "runs: $(cat "$T/runs.txt" 2>/dev/null); state: $(ls "$T/state" 2>/dev/null)"; fi

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
