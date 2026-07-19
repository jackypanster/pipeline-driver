#!/usr/bin/env bash
# Hermetic tests for the machine-readable role/agent bindings (drive.defaults
# CC/IMPL/REVIEW _AGENT + _MODEL_EXPECT, coordinate.config overrides) and doctor's
# fail-closed pane-footer model verification. Fixture shape follows
# test/coordinate-doctor.sh (bare remote + 4 clones + stub herdr); the stub gains a
# `pane read` clause (env-controlled footer, call log) in the e2e-herdr pattern.
# DRIVE_DEFAULTS is always pinned — the operator's real defaults must not leak in.
# Run: bash test/coordinate-bindings.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Hermetic: this test may itself run inside a Herdr pane (HERDR_* injected) — drop
# them so coordinate.sh's COORD_SELF_PANE does not pick up the test runner's pane.
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
# Physical temp base (macOS $TMPDIR sits behind the /var -> /private/var symlink;
# the state-root parent-chain check correctly flags a symlinked parent, so the
# suite must not construct its OWN state dirs behind one).
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Per-test subdir (incremented in the MAIN shell — $(fresh) would subshell it).
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; DD="$T/defaults"; }

# stub_herdr <root>: pane list cats $HERDR_STUB_LIST_JSON; agent explain returns
# authoritative; pane read prints $HERDR_STUB_FOOTER (default: a fixed tail line)
# or fails when HERDR_STUB_READ_FAILS=1. Every invocation is appended one-per-line
# to $HERDR_STUB_CALL_LOG when set (so a test can assert NO `pane read` happened).
stub_herdr() {
  mkdir -p "$1/bin"
  cat > "$1/bin/herdr" <<'S'
#!/usr/bin/env bash
[ -n "${HERDR_STUB_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$HERDR_STUB_CALL_LOG"
case "$1 $2" in
  "pane list") cat "$HERDR_STUB_LIST_JSON" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "agent explain")
    echo '{"agent":"x","state":"idle","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}' ;;
  "pane read")
    [ -n "${HERDR_STUB_READ_FAILS:-}" ] && exit 1
    printf '%s\n' "${HERDR_STUB_FOOTER:-stub tui tail line}" ;;
  *) exit 0 ;;
esac
S
  chmod +x "$1/bin/herdr"
}

# seed <root>: bare remote + 4 clones + committed current/control/journal + cfg +
# happy-path pane list (one agent-bearing pane per role workdir) + stub herdr.
# (Same fixture shape as test/coordinate-doctor.sh.)
seed() {
  local root=$1 c
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
  ( cd "$root/obs"; git checkout -q -b main
    mkdir -p .pipeline/hello-cli
    printf '{"feature":"hello-cli","stage":"impl"}' > .pipeline/current.json
    printf '{"schema_version":1,"mode":"coordinated","merge_gate":"human-direct"}' > .pipeline/hello-cli/control.json
    cp "$HERE/fixtures/coord-impl-impl.md" .pipeline/hello-cli/journal.md
    git add -A && git commit -qm seed && git push -q origin main )
  cat > "$root/cfg" <<EOF
OBSERVER_WORKDIR=$root/obs
BRANCH=main
CC_WORKDIR=$root/cc
PI_WORKDIR=$root/pi
CODEX_WORKDIR=$root/codex
CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='\$pipeline-review'
POLL_SECS=30
PANE_READY_TIMEOUT_MS=60000
STAGE_TIMEOUT_SECS=2700
EOF
  cat > "$root/list.json" <<EOF
{"result":{"panes":[
  {"pane_id":"wA:p1","agent":"claude","agent_status":"idle","cwd":"$root/cc","foreground_cwd":"$root/cc"},
  {"pane_id":"wB:p1","agent":"pi","agent_status":"idle","cwd":"$root/pi","foreground_cwd":"$root/pi"},
  {"pane_id":"wC:p1","agent":"codex","agent_status":"idle","cwd":"$root/codex","foreground_cwd":"$root/codex"}
]}}
EOF
  stub_herdr "$root"
}

# write_defaults <root>: the pinned defaults file with ALL SIX binding fields.
write_defaults() {
  cat > "$1/defaults" <<EOF
CC_AGENT=claude
CC_MODEL_EXPECT=fable-5
IMPL_AGENT=pi
IMPL_MODEL_EXPECT=glm-5.2
REVIEW_AGENT=codex
REVIEW_MODEL_EXPECT=gpt-5.6
EOF
}

# run_doctor / run_status: read $T + $DD (set by fresh/write_defaults); DRIVE_DEFAULTS
# always pinned. run_status keeps stdout clean (the 2-line contract); run_status_err
# merges stderr (where the human-readable bindings block goes).
run_doctor() {
  env STATE_DIR="$T/state" HERDR_STUB_LIST_JSON="$T/list.json" \
      DRIVE_DEFAULTS="$DD" \
      HERDR_STUB_FOOTER="${HERDR_STUB_FOOTER:-}" \
      HERDR_STUB_READ_FAILS="${HERDR_STUB_READ_FAILS:-}" \
      HERDR_STUB_CALL_LOG="${HERDR_STUB_CALL_LOG:-}" \
      PATH="$T/bin:/usr/bin:/bin" \
      bash "$COORD" doctor --config "$T/cfg" 2>&1
}
run_status() {
  env STATE_DIR="$T/state" DRIVE_DEFAULTS="$DD" \
      PATH=/usr/bin:/bin bash "$COORD" status --config "$T/cfg"
}
run_status_err() {
  env STATE_DIR="$T/state" DRIVE_DEFAULTS="$DD" \
      PATH=/usr/bin:/bin bash "$COORD" status --config "$T/cfg" 2>&1 >/dev/null
}

# ===== 1. status prints the bindings block sourced from the pinned defaults file
#      (all six fields) — on STDERR, so stdout keeps the 2-line contract. =====
fresh; seed "$T"; write_defaults "$T"
out=$(run_status); rc=$?
err=$(run_status_err)
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | sed -n '1p' | grep -q 'idle' \
   && printf '%s' "$out" | sed -n '2p' | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ] \
   && printf '%s' "$err" | grep -q -- '--- machine bindings' \
   && printf '%s' "$err" | grep -q "defaults file: $T/defaults" \
   && printf '%s' "$err" | grep -q '^prd/arch/task (CC pane): *agent=claude *expect=fable-5' \
   && printf '%s' "$err" | grep -q '^impl .*(PI pane): *agent=pi *expect=glm-5.2' \
   && printf '%s' "$err" | grep -q '^review .*(CODEX pane): *agent=codex *expect=gpt-5.6' \
   && printf '%s' "$err" | grep -q 'impl transport: <unset> *yolo: <unset>'; then
  ok "status: bindings block from pinned defaults (all six fields) on stderr, stdout contract intact"
else
  bad "status bindings block" "rc=$rc; stdout=$(printf '%s' "$out" | head -3); stderr: $(printf '%s' "$err" | head -8)"
fi

# ===== 2. coordinate.config override wins over the defaults value for the same field =====
fresh; seed "$T"; write_defaults "$T"
printf 'IMPL_AGENT=kimi\nIMPL_MODEL_EXPECT=kimi-k3\n' >> "$T/cfg"
err=$(run_status_err); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$err" | grep '^impl ' | grep -q 'agent=kimi *expect=kimi-k3' \
   && ! printf '%s' "$err" | grep '^impl ' | grep -q 'agent=pi '; then
  ok "coordinate.config override wins over drive.defaults (impl: pi/glm-5.2 -> kimi/kimi-k3)"
else
  bad "config override wins" "rc=$rc; impl line: $(printf '%s' "$err" | grep '^impl ')"
fi

# ===== 3. absent defaults file: <absent> line, every field <unset>, NOT a MISS —
#      doctor and status otherwise unchanged. =====
fresh; seed "$T"; DD=/nonexistent
out=$(run_doctor); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'defaults file: <absent> (cp drive.defaults.example — see README §Setup)' \
   && [ "$(printf '%s' "$out" | grep -c 'agent=<unset>')" = "3" ] \
   && [ "$(printf '%s' "$out" | grep -c 'expect=<unset>')" = "3" ] \
   && printf '%s' "$out" | grep -q 'config valid' \
   && printf '%s' "$out" | grep -q 'CC pane resolved: wA:p1' \
   && printf '%s' "$out" | grep -q 'doctor: 0 blocking'; then
  ok "absent defaults file -> <absent> + all <unset>, doctor unchanged (0 blocking)"
else
  bad "absent defaults (doctor)" "rc=$rc; output: $(printf '%s' "$out" | tail -25)"
fi
out=$(run_status); rc=$?
err=$(run_status_err)
if [ "$rc" -eq 0 ] \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ] \
   && printf '%s' "$err" | grep -q 'defaults file: <absent>'; then
  ok "absent defaults file -> status unchanged (rc 0, 2-line stdout, <absent> on stderr)"
else
  bad "absent defaults (status)" "rc=$rc; stdout=$(printf '%s' "$out" | head -3); stderr=$(printf '%s' "$err" | head -3)"
fi

# ===== 4. invalid field value: doctor CONFIG_INVALID MISS naming the field + rule;
#      status prints <invalid> and still exits 0. =====
fresh; seed "$T"; write_defaults "$T"
printf "IMPL_AGENT='a b'\n" >> "$T/defaults"
out=$(run_doctor); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && printf '%s' "$out" | grep -q 'input: IMPL_AGENT' \
   && printf '%s' "$out" | grep -q 'IMPL_AGENT must match \[A-Za-z0-9\]'; then
  ok "invalid IMPL_AGENT -> doctor CONFIG_INVALID MISS (field + rule named)"
else
  bad "invalid field (doctor)" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'CONFIG_INVALID|IMPL_AGENT|agent=' | head -6)"
fi
out=$(run_status); rc=$?
err=$(run_status_err)
if [ "$rc" -eq 0 ] \
   && printf '%s' "$err" | grep '^impl ' | grep -q 'agent=<invalid>' \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ]; then
  ok "invalid IMPL_AGENT -> status prints <invalid>, exits 0 (read-only never dies)"
else
  bad "invalid field (status)" "rc=$rc; impl line: $(printf '%s' "$err" | grep '^impl ')"
fi

# ===== 5a. doctor MODEL_MISMATCH: footer WITHOUT the expected substring -> the
#      five-field record naming role, pane, expected value, and the fix. =====
fresh; seed "$T"
cat > "$T/defaults" <<EOF
IMPL_AGENT=pi
IMPL_MODEL_EXPECT=glm-5.2
EOF
HERDR_STUB_FOOTER='pi · llama-9 · ready'
out=$(run_doctor); rc=$?
unset HERDR_STUB_FOOTER
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[MODEL_MISMATCH\]' \
   && printf '%s' "$out" | grep -q 'where: doctor:panes:PI' \
   && printf '%s' "$out" | grep -q 'input: wB:p1' \
   && printf '%s' "$out" | grep -q "footer does not contain expected 'glm-5.2'" \
   && printf '%s' "$out" | grep -q 'next_action: open the intended TUI/model in this pane, or update \*_MODEL_EXPECT / coordinate.config' \
   && printf '%s' "$out" | grep -q 'resume_guard:' \
   && printf '%s' "$out" | grep -q 'CC pane model: no \*_MODEL_EXPECT set — skipping footer check' \
   && ! printf '%s' "$out" | grep -q 'llama-9'; then
  ok "footer without expect -> five-field MODEL_MISMATCH (role/pane/expect/fix; raw footer never echoed)"
else
  bad "MODEL_MISMATCH miss" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'MODEL_MISMATCH|pane model|where:|llama' | head -8)"
fi

# ===== 5b. footer WITH the substring (different case) -> the d_ok line, rc 0 =====
fresh; seed "$T"
cat > "$T/defaults" <<EOF
IMPL_AGENT=pi
IMPL_MODEL_EXPECT=glm-5.2
EOF
HERDR_STUB_FOOTER='GLM-5.2 · pi · idle'
out=$(run_doctor); rc=$?
unset HERDR_STUB_FOOTER
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q "PI pane model: footer matches expect 'glm-5.2'" \
   && ! printf '%s' "$out" | grep -q 'MODEL_MISMATCH' \
   && printf '%s' "$out" | grep -q 'doctor: 0 blocking'; then
  ok "footer with expect (case-insensitive literal) -> d_ok, doctor stays green"
else
  bad "MODEL_MISMATCH ok" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'pane model|MODEL_MISMATCH|doctor:' | head -6)"
fi

# ===== 6. EXPECT unset everywhere -> the skip d_info per role, and NO `pane read`
#      is ever attempted (fake-herdr call log). =====
fresh; seed "$T"
cat > "$T/defaults" <<EOF
IMPL_AGENT=pi
REVIEW_AGENT=codex
EOF
HERDR_STUB_CALL_LOG="$T/calls.log"
out=$(run_doctor); rc=$?
unset HERDR_STUB_CALL_LOG
if [ "$rc" -eq 0 ] \
   && [ "$(printf '%s' "$out" | grep -c 'no \*_MODEL_EXPECT set — skipping footer check')" = "3" ] \
   && ! grep -q '^pane read' "$T/calls.log"; then
  ok "EXPECT unset -> skip d_info per role, zero \`pane read\` calls (no EXPECT, no read)"
else
  bad "unset EXPECT skip" "rc=$rc; infos=$(printf '%s' "$out" | grep -c 'skipping footer check'); calls: $(cat "$T/calls.log" 2>/dev/null)"
fi

# ===== 7. footer unreadable while herdr is otherwise OK -> FAIL CLOSED:
#      MODEL_MISMATCH 'footer unreadable', not a skip. =====
fresh; seed "$T"
cat > "$T/defaults" <<EOF
IMPL_MODEL_EXPECT=glm-5.2
EOF
HERDR_STUB_READ_FAILS=1
out=$(run_doctor); rc=$?
unset HERDR_STUB_READ_FAILS
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[MODEL_MISMATCH\]' \
   && printf '%s' "$out" | grep -q 'footer unreadable — cannot verify expected model'; then
  ok "footer unreadable with EXPECT set -> fail-closed MODEL_MISMATCH (never a skip)"
else
  bad "footer unreadable" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'MODEL_MISMATCH|pane model' | head -5)"
fi

# ===== R1a. internal LF in IMPL_AGENT -> CONFIG_INVALID; the raw value is NEVER
#      echoed (was: line-oriented grep passed line 1 'codex', and binding_token
#      then echoed both lines into the block). =====
fresh; seed "$T"
{ printf "IMPL_AGENT='codex"; printf '\n'; printf "!!!'\n"; } > "$T/defaults"
out=$(run_doctor); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && printf '%s' "$out" | grep -q 'input: IMPL_AGENT' \
   && ! printf '%s' "$out" | grep -qF '!!!' \
   && printf '%s' "$out" | grep '^impl ' | grep -q 'agent=<invalid>'; then
  ok "internal LF in IMPL_AGENT -> CONFIG_INVALID, one-line diagnostic, value never echoed"
else
  bad "LF in IMPL_AGENT" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'CONFIG_INVALID|impl |!!!' | head -6)"
fi

# ===== R1b. internal LF in IMPL_MODEL_EXPECT -> CONFIG_INVALID, and with the
#      fake-herdr footer containing 'pi' there is NO match-ok line — the
#      reviewer's false-match repro ($'definitely-absent\npi' became two grep
#      patterns and matched 'pi'). =====
fresh; seed "$T"
{ printf "IMPL_MODEL_EXPECT='definitely-absent"; printf '\n'; printf "pi'\n"; } > "$T/defaults"
HERDR_STUB_FOOTER='pi footer'
out=$(run_doctor); rc=$?
unset HERDR_STUB_FOOTER
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && printf '%s' "$out" | grep -q 'input: IMPL_MODEL_EXPECT' \
   && ! printf '%s' "$out" | grep -q 'footer matches expect'; then
  ok "internal LF in IMPL_MODEL_EXPECT -> CONFIG_INVALID; NO false footer match (reviewer repro)"
else
  bad "LF in IMPL_MODEL_EXPECT" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'CONFIG_INVALID|pane model|footer matches' | head -6)"
fi

# ===== R2. a raw 0xff byte in the value -> CONFIG_INVALID (was: 0xff is not a
#      C-locale control char, so it passed). =====
fresh; seed "$T"
printf 'IMPL_MODEL_EXPECT=glm\xff5.2\n' > "$T/defaults"
out=$(run_doctor); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && printf '%s' "$out" | grep -q 'input: IMPL_MODEL_EXPECT'; then
  ok "raw 0xff byte in IMPL_MODEL_EXPECT -> CONFIG_INVALID"
else
  bad "0xff byte" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'CONFIG_INVALID|pane model' | head -5)"
fi

# ===== R3. non-ASCII (É, UTF-8 multibyte) -> CONFIG_INVALID: the charset is
#      printable ASCII now (no Unicode case-folding in bash). =====
fresh; seed "$T"
printf 'IMPL_MODEL_EXPECT=\xc3\x89model\n' > "$T/defaults"
out=$(run_doctor); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && printf '%s' "$out" | grep -q 'input: IMPL_MODEL_EXPECT'; then
  ok "non-ASCII É in IMPL_MODEL_EXPECT -> CONFIG_INVALID (printable ASCII only)"
else
  bad "non-ASCII É" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'CONFIG_INVALID|pane model' | head -5)"
fi

# ===== R4. ASCII case-insensitivity still works: expect GLM-5.2 matches footer
#      glm-5.2 (LC_ALL=C tr fold + fixed-string grep). =====
fresh; seed "$T"
printf 'IMPL_MODEL_EXPECT=GLM-5.2\n' > "$T/defaults"
HERDR_STUB_FOOTER='glm-5.2 · pi · idle'
out=$(run_doctor); rc=$?
unset HERDR_STUB_FOOTER
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q "PI pane model: footer matches expect 'GLM-5.2'"; then
  ok "ASCII case-insensitivity: expect GLM-5.2 matches footer glm-5.2"
else
  bad "ASCII fold" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'pane model|MODEL_MISMATCH|doctor:' | head -5)"
fi

# ===== R5. leading-dash value '-v' is printable ASCII and LEGAL — and treated as
#      a LITERAL string (grep -F --, no option injection): a footer with -v
#      matches; a footer without it MISSes. =====
fresh; seed "$T"
printf 'IMPL_MODEL_EXPECT=-v\n' > "$T/defaults"
HERDR_STUB_FOOTER='has -v inside'
out=$(run_doctor); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q "PI pane model: footer matches expect '-v'"; then
  ok "leading-dash expect '-v' is a literal string (footer with -v matches)"
else
  bad "leading-dash match" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'pane model|MODEL_MISMATCH|doctor:' | head -5)"
fi
HERDR_STUB_FOOTER='no such flag here'
out=$(run_doctor); rc=$?
unset HERDR_STUB_FOOTER
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q '\[MODEL_MISMATCH\]' \
   && ! printf '%s' "$out" | grep -q 'footer matches expect'; then
  ok "leading-dash expect '-v' MISSes a footer without it (no grep option injection)"
else
  bad "leading-dash miss" "rc=$rc; output: $(printf '%s' "$out" | grep -E 'pane model|MODEL_MISMATCH|doctor:' | head -5)"
fi

# ===== R6. poisoned-environment hermeticity (the reviewer's exact repro):
#      DRIVE_DEFAULTS carrying IMPL_MODEL_EXPECT=glm-5.2 is exported while the
#      doctor suite runs — it pins its own absent defaults and stays fully green. =====
printf 'IMPL_MODEL_EXPECT=glm-5.2\n' > "$TMP/poison-defaults"
out=$(DRIVE_DEFAULTS="$TMP/poison-defaults" bash "$HERE/coordinate-doctor.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'failed=0'; then
  ok "poisoned DRIVE_DEFAULTS env -> coordinate-doctor.sh stays fully green (suite pins its own)"
else
  bad "poisoned-env hermeticity" "rc=$rc; tail: $(printf '%s' "$out" | tail -4)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
