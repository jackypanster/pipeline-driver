#!/usr/bin/env bash
# Regression tests for the bounded-exec watchdog + CLI surface, all via the
# SHIPPED `doctor` CLI (no internal hooks — finding 1 removed `__bounded-run`).
#   - finding 1: `coordinate.sh __bounded-run ...` is GONE — invoking it exits
#     nonzero and executes/creates nothing.
#   - finding 9: COORD_*_TIMEOUT_MS=0 is CONFIG_INVALID (ualarm(0) would disable
#     the watchdog); and a child killed by a signal propagates nonzero (a crashed
#     agent explain must NOT authorize off truncated output).
#   - sanity: a hung `herdr pane list` (immortal descendant holding stdout) is
#     bounded — doctor returns within budget, not hanging on the descendant.
# Run: bash test/coordinate-watchdog.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
export DRIVE_DEFAULTS="$TMP/.absent-drive-defaults"   # hermetic: never read the operator's real file
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
now() { perl -MTime::HiRes=time -e 'print time'; }
elapsed() { awk -v s="$1" -v e="$2" 'BEGIN{printf "%.3f", e-s}'; }

# ===== finding 1: __bounded-run is gone from the shipped CLI. Invoking it must
#      exit nonzero and create NOTHING (old head executed it and created a file). =====
M="$TMP/marker"
out=$(bash "$COORD" __bounded-run 1000 /usr/bin/touch "$M" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$M" ]; then
  ok "__bounded-run removed: rc=$rc, nothing created"
else
  bad "__bounded-run removed" "rc=$rc; marker exists=$([ -e "$M" ] && echo yes || echo no)"
fi

# seed <root>: bare remote + 4 clones + committed current/control/journal + cfg +
# happy-path pane list + a stub herdr whose behavior is tuned per-test via env.
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
EOF
  cat > "$root/list.json" <<EOF
{"result":{"panes":[
  {"pane_id":"wA:p1","agent":"claude","cwd":"$root/cc"},
  {"pane_id":"wB:p1","agent":"pi","cwd":"$root/pi"},
  {"pane_id":"wC:p1","agent":"codex","cwd":"$root/codex"}
]}}
EOF
}
# stub_herdr <root> <mode>: mode = "fast" (authoritative), "sigterm" (print JSON
# then self-SIGTERM), or "hung-pane" (pane list forks sleep 30 holding stdout).
stub_herdr() {
  mkdir -p "$1/bin"
  cat > "$1/bin/herdr" <<S
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane list")
    if [ -n "\${HERDR_STUB_HUNG_PANE:-}" ]; then sleep 30 & exit 0; fi
    if [ -n "\${HERDR_STUB_BLOCKING_LEADER:-}" ]; then sleep 20; exit 0; fi
    cat "\$HERDR_STUB_LIST_JSON" 2>/dev/null || echo '{"result":{"panes":[]}}'
    ;;
  "agent explain")
    echo '{"agent":"x","state":"idle","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}'
    if [ -n "\${HERDR_STUB_SIGTERM:-}" ]; then kill -15 \$\$; fi
    ;;
esac
S
  chmod +x "$1/bin/herdr"
}
run_doctor() {  # [env...] doctor on $T
  env HERDR_STUB_LIST_JSON="$T/list.json" \
      PATH="$T/bin:/usr/bin:/bin" bash "$COORD" doctor --config "$T/cfg" 2>&1
}

# ===== finding 9: COORD_AUTH_TIMEOUT_MS=0 is CONFIG_INVALID (ualarm(0) disables the
#      watchdog). Old head accepted 0 and ran unbounded. =====
T="$TMP/t2"; seed "$T"; stub_herdr "$T"   # fast stub — no hang on either head
out=$(COORD_AUTH_TIMEOUT_MS=0 run_doctor); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\].*AUTH_TIMEOUT_MS'; then
  ok "AUTH_TIMEOUT_MS=0 -> CONFIG_INVALID"
else
  bad "AUTH_TIMEOUT_MS=0" "expected CONFIG_INVALID mentioning AUTH_TIMEOUT_MS; rc=$rc; $(printf '%s' "$out" | grep -iE 'timeout|config_invalid' | head -4)"
fi

# ===== finding 9: an agent-explain child that prints authoritative JSON then
#      self-SIGTERMs must NOT report rc=0 — else authority_of keeps the sample and
#      authorizes a crashed agent. Old head did ($? >> 8 == 0). =====
T="$TMP/t3"; seed "$T"; stub_herdr "$T"
out=$(HERDR_STUB_SIGTERM=1 run_doctor); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[AGENT_STATUS_INVALID\]'; then
  ok "signal-killed agent explain -> AGENT_STATUS_INVALID (no rc=0 authorization)"
else
  bad "signal-killed agent explain" "expected AGENT_STATUS_INVALID; rc=$rc; $(printf '%s' "$out" | grep -iE 'authority|agent_status|panes' | head -5)"
fi

# ===== sanity (round-1 behavior, kept): a hung pane list with an immortal
#      descendant holding stdout is bounded — doctor returns within budget. =====
T="$TMP/t4"; seed "$T"; stub_herdr "$T"
s=$(now); out=$(HERDR_STUB_HUNG_PANE=1 COORD_PANE_LIST_TIMEOUT_MS=600 run_doctor); rc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[DEPENDENCY_MISSING\]' \
   && awk -v x="$el" 'BEGIN{exit !(x < 8)}'; then
  ok "hung pane list bounded -> DEPENDENCY_MISSING in ${el}s (no 30s hang)"
else
  bad "hung pane list bounded" "rc=$rc elapsed=${el}s; $(printf '%s' "$out" | grep -i 'pane list' | head -2)"
fi

# ===== round-3 F1: a ZERO budget must never be USED, not merely reported. The
#      round-2 zero test used a fast stub, so it proved only the diagnostic; with a
#      BLOCKING pane-list leader the old head ran ualarm(0) (deadline disabled) and
#      hung in waitpid for the leader's full 20s. The fix skips every Herdr read
#      after the invalid-budget MISS (and bounded_run_ms refuses rc=125 as backstop),
#      so doctor returns fast with CONFIG_INVALID. =====
T="$TMP/t5"; seed "$T"; stub_herdr "$T"
s=$(now); out=$(HERDR_STUB_BLOCKING_LEADER=1 COORD_PANE_LIST_TIMEOUT_MS=0 run_doctor); rc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\].*PANE_LIST_TIMEOUT_MS' \
   && awk -v x="$el" 'BEGIN{exit !(x < 8)}'; then
  ok "zero budget + blocking leader -> CONFIG_INVALID in ${el}s (never calls Herdr unbounded)"
else
  bad "zero budget + blocking leader" "rc=$rc elapsed=${el}s; $(printf '%s' "$out" | grep -iE 'timeout|config_invalid|pane list' | head -4)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
