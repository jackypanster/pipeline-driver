#!/usr/bin/env bash
# Hermetic tests for `coordinate.sh doctor` (design §12 / §24.2). A stub `herdr`
# (pane list + agent explain canned JSON) stands in for the real transport; a
# bare "remote" + observer + three role clones stand in for the topology. The
# happy path exits 0; then one prerequisite is broken per case and the exact §14
# code must surface with a non-zero exit. Run: bash test/coordinate-doctor.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Hermetic: this test may itself run inside a Herdr pane (HERDR_* injected) — drop
# them so coordinate.sh's COORD_SELF_PANE does not pick up the test runner's pane.
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Per-test subdir (incremented in the MAIN shell — $(fresh) would subshell it).
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; }

# stub_herdr <root>: pane list cats $HERDR_STUB_LIST_JSON; agent explain returns
# authoritative by default, or the exact Herdr 0.7.3 always-idle-fallback shape
# when HERDR_STUB_NO_AUTHORITY=1 (loaded manifest, NO matched rule).
stub_herdr() {
  mkdir -p "$1/bin"
  cat > "$1/bin/herdr" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pane list") cat "$HERDR_STUB_LIST_JSON" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "agent explain")
    if [ -n "${HERDR_STUB_NO_AUTHORITY:-}" ]; then
      echo '{"agent":"x","state":"idle","matched_rule":null,"manifest_source":"remote:x.toml","screen_detection_skip_reason":null,"fallback_reason":"default_known_agent_idle_fallback"}'
    else
      echo '{"agent":"x","state":"idle","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}'
    fi ;;
  *) exit 0 ;;
esac
S
  chmod +x "$1/bin/herdr"
}

# seed <root>: bare remote + 4 clones + committed current/control/journal + cfg +
# happy-path pane list (one agent-bearing pane per role workdir) + stub herdr.
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

# run_doctor: reads $T (set by fresh/seed); extra env passed via DOCTOR_ENV.
run_doctor() {
  env STATE_DIR="$T/state" HERDR_STUB_LIST_JSON="$T/list.json" \
      HERDR_PANE_ID="${HERDR_PANE_ID:-}" \
      PATH="$T/bin:/usr/bin:/bin" \
      bash "$COORD" doctor --config "$T/cfg" 2>&1
}

assert_ok() {  # <label>: happy path — rc 0 + key d_ok lines present
  local label=$1 out rc
  out=$(run_doctor); rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s' "$out" | grep -q 'config valid' \
     && printf '%s' "$out" | grep -q 'journal tail: SEQ=7' \
     && printf '%s' "$out" | grep -q 'control.json valid' \
     && printf '%s' "$out" | grep -q 'CC pane resolved: wA:p1' \
     && printf '%s' "$out" | grep -q 'CODEX pane lifecycle authority: confirmed' \
     && printf '%s' "$out" | grep -q 'doctor: 0 blocking'; then
    ok "$label"
  else
    bad "$label" "rc=$rc; output: $(printf '%s' "$out" | tail -25)"
  fi
}

assert_code() {  # <label> <code>: doctor MUST carry [code] + exit non-zero
  local label=$1 code=$2 out rc
  out=$(run_doctor); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "\[$code\]"; then
    ok "$label"
  else
    bad "$label" "expected rc!=0 + [$code]; rc=$rc; output: $(printf '%s' "$out" | grep -E '\[|doctor:' | head -10)"
  fi
}

# ===== happy path: deps + config + remote + journal + 3 panes + 3 authority =====
fresh; seed "$T"
assert_ok "happy path: full preflight passes (rc 0)"

# ===== 1. remote mismatch (codex clone tracks a different origin) =====
fresh; seed "$T"
git init -q --bare "$T/other.git"
git -C "$T/codex" remote set-url origin "$T/other.git"
assert_code "remote mismatch -> REMOTE_MISMATCH" REMOTE_MISMATCH

# ===== 2. missing pane (no agent-bearing pane in the CODEX workdir) =====
fresh; seed "$T"
cat > "$T/list.json" <<EOF
{"result":{"panes":[
  {"pane_id":"wA:p1","agent":"claude","agent_status":"idle","cwd":"$T/cc","foreground_cwd":"$T/cc"},
  {"pane_id":"wB:p1","agent":"pi","agent_status":"idle","cwd":"$T/pi","foreground_cwd":"$T/pi"}
]}}
EOF
assert_code "missing CODEX pane -> PANE_NOT_FOUND" PANE_NOT_FOUND

# ===== 3. ambiguous pane (two agent-bearing panes in the CC workdir) =====
fresh; seed "$T"
cat > "$T/list.json" <<EOF
{"result":{"panes":[
  {"pane_id":"wA:p1","agent":"claude","agent_status":"idle","cwd":"$T/cc","foreground_cwd":"$T/cc"},
  {"pane_id":"wA:p2","agent":"claude","agent_status":"idle","cwd":"$T/cc","foreground_cwd":"$T/cc"},
  {"pane_id":"wB:p1","agent":"pi","agent_status":"idle","cwd":"$T/pi","foreground_cwd":"$T/pi"},
  {"pane_id":"wC:p1","agent":"codex","agent_status":"idle","cwd":"$T/codex","foreground_cwd":"$T/codex"}
]}}
EOF
assert_code "ambiguous CC pane -> PANE_AMBIGUOUS" PANE_AMBIGUOUS

# ===== 4. self pane (a role pinned to the pane running coordinate.sh) =====
fresh; seed "$T"
printf 'CC_PANE_ID=wA:p1\n' >> "$T/cfg"
HERDR_PANE_ID="wA:p1" assert_code "pinned CC pane == coordinator pane -> PANE_SELF" PANE_SELF
unset HERDR_PANE_ID

# ===== 5. non-authoritative agent status (always-idle fallback) = launch-blocker =====
fresh; seed "$T"
HERDR_STUB_NO_AUTHORITY=1 assert_code "non-authoritative status -> AGENT_STATUS_INVALID" AGENT_STATUS_INVALID

# ===== 6. malformed control.json (violates the schema) =====
fresh; seed "$T"
( cd "$T/obs"
  printf '{"schema_version":2,"mode":"coordinated","merge_gate":"human-direct"}' > .pipeline/hello-cli/control.json
  git commit -qam badctl && git push -q origin main )
assert_code "malformed control.json -> CONTROL_MALFORMED" CONTROL_MALFORMED

# ===== 7. malformed journal tail (missing arrow) -> JOURNAL_MALFORMED =====
fresh; seed "$T"
( cd "$T/obs"
  cp "$HERE/fixtures/coord-malformed.md" .pipeline/hello-cli/journal.md
  git commit -qam badjournal && git push -q origin main )
assert_code "malformed journal tail -> JOURNAL_MALFORMED" JOURNAL_MALFORMED

# ===== 8. (finding 5) coordinated mode + MISSING journal.md -> BLOCKING =====
fresh; seed "$T"
( cd "$T/obs"
  git rm -q .pipeline/hello-cli/journal.md
  git commit -qm nojournal && git push -q origin main )
assert_code "coordinated + missing journal -> JOURNAL_MALFORMED" JOURNAL_MALFORMED

# ===== 9. (finding 5) coordinated mode + EMPTY journal (no entries) -> BLOCKING =====
fresh; seed "$T"
( cd "$T/obs"
  : > .pipeline/hello-cli/journal.md   # committed but empty -> awk: no-entries
  git commit -qam emptyjournal && git push -q origin main )
assert_code "coordinated + empty journal -> JOURNAL_MALFORMED" JOURNAL_MALFORMED

# ===== 10. (finding 5) HUMAN mode + missing journal -> informational (NOT blocking)
#           control.json mode=human, journal removed: doctor must NOT emit
#           JOURNAL_MALFORMED for the journal, and with panes otherwise happy it
#           exits 0 with a warning (not a miss). =====
fresh; seed "$T"
( cd "$T/obs"
  printf '{"schema_version":1,"mode":"human","merge_gate":"human-direct"}' > .pipeline/hello-cli/control.json
  git rm -q .pipeline/hello-cli/journal.md
  git commit -aqm human && git push -q origin main )
hr_out=$(run_doctor); hr_rc=$?
if [ "$hr_rc" -eq 0 ] \
   && ! printf '%s' "$hr_out" | grep -q '\[JOURNAL_MALFORMED\]' \
   && printf '%s' "$hr_out" | grep -qi 'no journal.md'; then
  ok "human + missing journal -> informational (rc=0, no JOURNAL_MALFORMED)"
else
  bad "human + missing journal" "rc=$hr_rc; expected rc=0 + no JOURNAL_MALFORMED + 'no journal.md' warn; got: $(printf '%s' "$hr_out" | grep -i 'journal\|doctor:' | head -6)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
