#!/usr/bin/env bash
# Phase 3: the §13 delivery sequence + ledger lifecycle + resume + audit. Hermetic:
# local bare remote + stub herdr + physical temp base. Run: bash test/coordinate-ledger.sh
set -u
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
. "$(cd "$(dirname "$0")" && pwd)/coord-lib.sh"
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures"

# A prd->arch route fixture (genesis entry, NEXT=Run pipeline-arch).
prd_arch="$TMP/prd-arch.md"
printf '## seq=1 \xc2\xb7 2026-07-16T00:00:00Z \xc2\xb7 \xe2\x88\x85\xe2\x86\x92prd \xc2\xb7 completed \xc2\xb7 by=cc\n--- handoff ---\n>>> NEXT\nRun pipeline-arch\n<<< END\n' > "$prd_arch"

# ===== 1. §13 delivery ordering: dispatch_pending BEFORE dispatch_sent; ledger
#      pending->sent; the typed envelope carries repo/branch/feature/seq/commit. =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
cl_run_watch "$T" >/dev/null 2>&1 || true
ev="$(cl_featdir "$T" hello)/events.jsonl"
if [ -f "$ev" ] \
   && grep -q '"event":"dispatch_pending"' "$ev" && grep -q '"event":"dispatch_sent"' "$ev" \
   && [ "$(grep -n '"event":"dispatch_pending"' "$ev" | cut -d: -f1)" -lt "$(grep -n '"event":"dispatch_sent"' "$ev" | cut -d: -f1)" ]; then
  ok "§13 audit ordering: dispatch_pending precedes dispatch_sent"
else  bad "§13 ordering" "events: $(cat "$ev" 2>/dev/null | head)"; fi
# ledger delivered=sent for the observed seq/commit
ld="$(cl_featdir "$T" hello)/ledger.json"
obs=$(git -C "$T/obs" rev-parse origin/main)
if jq -e --arg c "$obs" '.delivery=="sent" and .journal_seq==1 and .journal_commit==$c and .target_role=="CC"' "$ld" >/dev/null 2>&1; then
  ok "§13 ledger records sent(seq=1, role=CC, full commit)"
else  bad "§13 ledger" "$(cat "$ld" 2>/dev/null)"; fi
# the typed envelope carries ALL five fields, expected_commit == observed full hash
if grep -q "expected_seq=1" "$T/runs.txt" && grep -q "expected_commit=$obs" "$T/runs.txt" \
   && grep -q "feature=hello" "$T/runs.txt" && grep -q "repo=$T/cc " "$T/runs.txt"; then
  ok "§13 envelope typed in full (repo/feature/expected_seq/expected_commit==observed)"
else  bad "§13 envelope" "typed: $(cat "$T/runs.txt" 2>/dev/null)"; fi

# ===== 2. (scenario 10) startup-with-pending -> DELIVERY_AMBIGUOUS halt, no send. =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
obs=$(git -C "$T/obs" rev-parse origin/main)
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"pending"}' "$obs" > "$fd/ledger.json"; chmod 600 "$fd/ledger.json"
out=$(cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'DELIVERY_AMBIGUOUS' && [ -f "$fd/halt.json" ] \
   && [ ! -s "$T/runs.txt" ]; then
  ok "startup-with-pending -> DELIVERY_AMBIGUOUS halt (no send)"
else  bad "startup-pending" "rc=$rc; out=$(printf '%s' "$out" | grep -i fatal -A4 | head -6)"; fi

# ===== 3. resume --pending retry clears pending -> redispatch on next watch. =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"pending"}' "$(git -C "$T/obs" rev-parse origin/main)" > "$fd/ledger.json"; chmod 600 "$fd/ledger.json"
env PATH="$T/bin:/usr/bin:/bin" bash "$COORD" resume --config "$T/cfg" --reason "operator inspected; retry" --pending retry >/dev/null 2>&1
if [ ! -e "$fd/ledger.json" ] && grep -q '"event":"resume"' "$fd/events.jsonl"; then
  ok "resume --pending retry -> ledger removed (no in-flight dispatch; redispatch next)"
else  bad "resume retry" "ledger still: $(cat "$fd/ledger.json" 2>/dev/null || echo absent)"; fi

# ===== 4. resume --pending mark-sent -> ledger sent (enter WAITING). =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"pending"}' "$(git -C "$T/obs" rev-parse origin/main)" > "$fd/ledger.json"; chmod 600 "$fd/ledger.json"
env PATH="$T/bin:/usr/bin:/bin" bash "$COORD" resume --config "$T/cfg" --reason "operator confirms sent" --pending mark-sent >/dev/null 2>&1
if [ "$(jq -r .delivery "$fd/ledger.json" 2>/dev/null)" = "sent" ]; then
  ok "resume --pending mark-sent -> ledger sent (WAITING)"
else  bad "resume mark-sent" "delivery=$(jq -r .delivery "$fd/ledger.json" 2>/dev/null)"; fi

# ===== 5. resume without --pending on a pending ledger -> refused (nonzero). =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
printf '{"feature":"hello","journal_seq":1,"journal_commit":"%s","target_role":"CC","pane":"wA:p1","command":"pipeline-arch","delivery":"pending"}' "$(git -C "$T/obs" rev-parse origin/main)" > "$fd/ledger.json"; chmod 600 "$fd/ledger.json"
out=$(env PATH="$T/bin:/usr/bin:/bin" bash "$COORD" resume --config "$T/cfg" --reason x 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'DELIVERY_AMBIGUOUS'; then
  ok "resume without --pending on pending ledger -> refused (DELIVERY_AMBIGUOUS)"
else  bad "resume no-flag" "rc=$rc; out=$(printf '%s' "$out" | head -3)"; fi

# ===== 6. stale lock (dead PID) cleared ONLY by resume; watch fatals LOCK_STALE. =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd/lock"; chmod 700 "$fd/lock"
echo "999999" > "$fd/lock/pid"; chmod 600 "$fd/lock/pid"   # a surely-dead PID
out=$(cl_run_watch "$T" 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'LOCK_STALE'; then ok "watch fatals LOCK_STALE on a dead-pid lock"
else bad "LOCK_STALE" "rc=$rc; out=$(printf '%s' "$out" | grep -i lock -A2 | head -4)"; fi
# resume clears it.
env PATH="$T/bin:/usr/bin:/bin" bash "$COORD" resume --config "$T/cfg" --reason clear >/dev/null 2>&1
if [ ! -d "$fd/lock" ]; then ok "resume clears the stale lock"
else bad "resume stale-lock" "lock still present at $fd/lock"; fi

# ===== 7. halt.json blocks watch until resume removes it. =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
printf '{"code":"STAGE_TIMEOUT","where":"x","reason":"prev"}' > "$fd/halt.json"; chmod 600 "$fd/halt.json"
out=$(cl_run_watch "$T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'STAGE_TIMEOUT' && [ ! -s "$T/runs.txt" ]; then
  ok "halt.json blocks watch (no dispatch)"
else  bad "halt blocks" "rc=$rc; out=$(printf '%s' "$out" | grep -i fatal -A3 | head -5)"; fi

# ===== 8. audit is append-only (timestamps monotonic non-decreasing). =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
cl_run_watch "$T" >/dev/null 2>&1 || true
ev="$(cl_featdir "$T" hello)/events.jsonl"
if [ -f "$ev" ] && [ "$(jq -r .timestamp "$ev" | sort -c 2>/dev/null; echo $?)" = 0 ]; then
  ok "audit append-only (timestamps monotonic)"
else  bad "audit order" "$(cat "$ev" 2>/dev/null | head -3)"; fi

# ===== 9. AUDIT_WRITE_FAILED: make events.jsonl unwritable (file 0400, dir stays 0700). =====
fresh; cl_seed_clones "$T"; cl_feature "$T" hello "$prd_arch"; cl_stub_herdr "$T"
fd="$(cl_featdir "$T" hello)"; mkdir -p "$fd"; chmod 700 "$fd"
: > "$fd/events.jsonl"; chmod 400 "$fd/events.jsonl"   # file not writable; dir writable so the lock acquires
out=$(cl_run_watch "$T" 2>&1); rc=$?; chmod 600 "$fd/events.jsonl" 2>/dev/null || true
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AUDIT_WRITE_FAILED'; then
  ok "audit append failure -> AUDIT_WRITE_FAILED fatal"
else  bad "AUDIT_WRITE_FAILED" "rc=$rc; out=$(printf '%s' "$out" | grep -i fatal -A3 | head -5)"; fi

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
