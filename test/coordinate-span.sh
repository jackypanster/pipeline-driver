#!/usr/bin/env bash
# Phase 3: impl-span delegation to drive.sh (design decision 6 / §20). The shipped
# CLI has NO drive-path knob: tests copy coordinate.sh + parse-tail.awk into a temp
# app dir with a STUB drive.sh beside them, so $HERE resolves to the stub. Hermetic.
# Run: bash test/coordinate-span.sh
set -u
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
. "$(cd "$(dirname "$0")" && pwd)/coord-lib.sh"
J="$TMP/journal.md"
REAL_HERE="$(cd "$(dirname "$0")" && pwd)"

# mk_app <root>: temp $HERE with the real coordinate.sh/parse-tail.awk + stub drive.sh.
# The stub records its argv + the DRIVE_DEFAULTS it saw, copies the generated config
# (coordinate.sh deletes it afterwards), and exits DRIVE_STUB_RC.
mk_app() {
  mkdir -p "$1/app"
  cp "$REAL_HERE/../coordinate.sh" "$1/app/coordinate.sh"
  cp "$REAL_HERE/../parse-tail.awk" "$1/app/parse-tail.awk"
  cat > "$1/app/drive.sh" <<'S'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "DRIVE_DEFAULTS:${DRIVE_DEFAULTS:-unset}"; } >> "${DRIVE_STUB_OUT:?}/calls.txt"
cp "$1" "${DRIVE_STUB_OUT}/config.copy" 2>/dev/null || true
[ -n "${DRIVE_STUB_MSG:-}" ] && echo "$DRIVE_STUB_MSG" >&2
exit "${DRIVE_STUB_RC:-0}"
S
  chmod +x "$1/app/drive.sh" "$1/app/coordinate.sh"
  COORD="$1/app/coordinate.sh"
}

# ===== 1. task->impl delegates to $HERE/drive.sh with a generated 0600 config:
#      WORKDIR=observer, IMPL_TRANSPORT=herdr, the RESOLVED Pi pane pinned, the
#      command prefix quoted verbatim, DRIVE_DEFAULTS isolated to /dev/null;
#      ledger ends sent with command name drive.sh (audit pending->sent). =====
fresh; cl_seed_clones "$T"; mk_app "$T"
sed -i.bak "s|^PI_IMPL_CMD=.*|PI_IMPL_CMD='\$pipeline-impl --deep go'|" "$T/cfg" && rm -f "$T/cfg.bak"
cl_mkjournal "$J" arch task completed "Run pipeline-impl"
cl_feature "$T" hello "$J"; cl_card "$T" hello 01 todo 0; cl_stub_herdr "$T"
mkdir -p "$T/stub-out"
CL_WATCH_EXTRA="DRIVE_STUB_OUT=$T/stub-out" cl_run_watch "$T" >/dev/null 2>&1 || true
fd="$(cl_featdir "$T" hello)"
if grep -q "^ARGS:" "$T/stub-out/calls.txt" 2>/dev/null \
   && grep -q "^DRIVE_DEFAULTS:/dev/null$" "$T/stub-out/calls.txt"; then
  ok "task->impl invokes \$HERE/drive.sh with DRIVE_DEFAULTS=/dev/null (span delegated)"
else bad "span invocation" "calls: $(cat "$T/stub-out/calls.txt" 2>/dev/null || echo none)"; fi
if grep -q "WORKDIR='$T/obs'" "$T/stub-out/config.copy" 2>/dev/null \
   && grep -q "IMPL_TRANSPORT=herdr" "$T/stub-out/config.copy" \
   && grep -q "HERDR_PANE_ID='wB:p1'" "$T/stub-out/config.copy" \
   && grep -q "FEATURE='hello'" "$T/stub-out/config.copy" \
   && grep -q "IMPL_SLASH_CMD='\$pipeline-impl --deep go'" "$T/stub-out/config.copy"; then
  ok "generated drive.config: observer workdir + herdr transport + pinned Pi pane + verbatim quoted command"
else bad "generated config" "$(cat "$T/stub-out/config.copy" 2>/dev/null || echo none)"; fi
if jq -e '.delivery=="sent" and .command=="drive.sh" and .target_role=="PI"' "$fd/ledger.json" >/dev/null 2>&1 \
   && grep -q '"event":"dispatch_sent".*"action":"drive.sh"' "$fd/events.jsonl" 2>/dev/null; then
  ok "span audited + ledgered as drive.sh (pending -> sent)"
else bad "span ledger/audit" "ledger: $(cat "$fd/ledger.json" 2>/dev/null); events: $(tail -2 "$fd/events.jsonl" 2>/dev/null)"; fi
# no direct pipeline-impl typing: the span owner types, not the coordinator.
if ! grep -q "pipeline-impl" "$T/runs.txt" 2>/dev/null; then
  ok "coordinator never types the impl command itself (drive.sh owns the span)"
else bad "direct impl typing" "$(cat "$T/runs.txt")"; fi

# ===== 2. review->impl · failed (one todo card) also delegates. =====
fresh; cl_seed_clones "$T"; mk_app "$T"
cl_mkjournal "$J" review impl failed "Run pipeline-impl"
cl_feature "$T" hello "$J"; cl_card "$T" hello 01 todo 1; cl_stub_herdr "$T"
mkdir -p "$T/stub-out"
CL_WATCH_EXTRA="DRIVE_STUB_OUT=$T/stub-out" cl_run_watch "$T" >/dev/null 2>&1 || true
if grep -q "^ARGS:" "$T/stub-out/calls.txt" 2>/dev/null; then
  ok "review->impl · failed delegates the retry span to drive.sh"
else bad "retry span" "calls: $(cat "$T/stub-out/calls.txt" 2>/dev/null || echo none)"; fi

# ===== 3. drive.sh nonzero exit -> fatal with the sanitized tail; ledger stays
#      pending (the ambiguity mark — resume decides). =====
fresh; cl_seed_clones "$T"; mk_app "$T"
cl_mkjournal "$J" arch task completed "Run pipeline-impl"
cl_feature "$T" hello "$J"; cl_card "$T" hello 01 todo 0; cl_stub_herdr "$T"
mkdir -p "$T/stub-out"
out=$(CL_WATCH_EXTRA="DRIVE_STUB_OUT=$T/stub-out DRIVE_STUB_RC=3 DRIVE_STUB_MSG=drive-halted-at-stop-point" cl_run_watch "$T" 2>&1); rc=$?
fd="$(cl_featdir "$T" hello)"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AGENT_ENDED_WITHOUT_HANDOFF' \
   && printf '%s' "$out" | grep -q 'drive-halted-at-stop-point' \
   && [ "$(jq -r .delivery "$fd/ledger.json" 2>/dev/null)" = "pending" ]; then
  ok "drive.sh nonzero -> fatal carrying its tail; ledger stays pending (resume decides)"
else bad "span failure" "rc=$rc; ledger=$(jq -r .delivery "$fd/ledger.json" 2>/dev/null); $(printf '%s' "$out" | grep -i fatal -A3 | head -5)"; fi

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
