#!/usr/bin/env bash
# Regression test for finding 7: bounded_run_ms must (a) bound `herdr pane list`
# too, and (b) keep the watchdog alive for descendants — a leader that forks a
# long-lived child HOLDING STDOUT and then exits must not let the caller's $(...)
# outlive the budget. The reviewer measured 2.04s for a 100ms budget and noted an
# immortal descendant hangs forever. The fix kills the WHOLE child process group
# on both timeout AND normal leader exit, then drains the group.
# Run: bash test/coordinate-watchdog.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
now() { perl -MTime::HiRes=time -e 'print time'; }
elapsed() { awk -v s="$1" -v e="$2" 'BEGIN{printf "%.3f", e-s}'; }

stub_herdr() {  # <root> <mode>
  mkdir -p "$1/bin"
  cat > "$1/bin/herdr" <<S
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane list")
    $2
    ;;
  "agent explain")
    echo '{"agent":"x","state":"idle","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}'
    ;;
  *) exit 0 ;;
esac
S
  chmod +x "$1/bin/herdr"
}

# Warm the stub binaries once so the test is not dominated by macOS first-exec
# (dyld/code-signing) warming — we are measuring the WATCHDOG, not process spawn.
# Warming the immortal binary via the helper also reaps its lingering sleep child.
warm() { PATH="$TMP/bin:/usr/bin:/bin" bash "$COORD" __bounded-run 2000 "$1" >/dev/null 2>&1 || true; }

# ===== 1. immortal descendant holding stdout: $(...) must return within a small
#      bound, NOT wait for the 30s sleep. Old code let $(...) block ~30s. =====
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nsleep 30 &\nexit 0\n' > "$TMP/bin/immortal"; chmod +x "$TMP/bin/immortal"
warm "$TMP/bin/immortal"
s=$(now); out=$(PATH="$TMP/bin:/usr/bin:/bin" bash "$COORD" __bounded-run 500 "$TMP/bin/immortal" 2>/dev/null); rc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if awk -v x="$el" 'BEGIN{exit !(x < 5)}'; then
  ok "immortal descendant: returned in ${el}s (<<30s); rc=$rc"
else
  bad "immortal descendant" "watchdog did NOT bound the call: elapsed=${el}s rc=$rc (expected <5s)"
fi

# ===== 2. healthy leader that writes output and exits 0: rc 0 + output within budget =====
s=$(now); out=$(PATH="$TMP/bin:/usr/bin:/bin" bash "$COORD" __bounded-run 3000 /bin/sh -c 'echo healthy-output; exit 0' 2>/dev/null); rc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if [ "$rc" -eq 0 ] && [ "$out" = "healthy-output" ] && awk -v x="$el" 'BEGIN{exit !(x < 3)}'; then
  ok "healthy leader: rc=0 + output captured, returned in ${el}s"
else
  bad "healthy leader" "rc=$rc out=[$out] elapsed=${el}s"
fi

# ===== 3. timeout: a leader that itself sleeps past the budget -> rc 124 (within budget) =====
s=$(now); out=$(PATH="$TMP/bin:/usr/bin:/bin" bash "$COORD" __bounded-run 400 /bin/sh -c 'sleep 5; echo late' 2>/dev/null); rc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if [ "$rc" -eq 124 ] && awk -v x="$el" 'BEGIN{exit !(x < 3 && x >= 0.3)}'; then
  ok "timeout path: rc=124 in ${el}s (budget 400ms)"
else
  bad "timeout path" "rc=$rc elapsed=${el}s (expected rc=124, 0.3<=t<3)"
fi

# ===== 4. doctor integration: a HUNG `herdr pane list` (forks sleep 30, no JSON)
#      must NOT hang doctor — it returns within budget and reports the missing JSON
#      as DEPENDENCY_MISSING. =====
R="$TMP/d"; mkdir -p "$R"
git init -q --bare "$R/origin.git"
for c in obs cc pi codex; do git clone -q "$R/origin.git" "$R/$c" >/dev/null 2>&1; done
( cd "$R/obs"; git checkout -q -b main
  mkdir -p .pipeline/hello-cli
  printf '{"feature":"hello-cli","stage":"impl"}' > .pipeline/current.json
  printf '{"schema_version":1,"mode":"coordinated","merge_gate":"human-direct"}' > .pipeline/hello-cli/control.json
  cp "$HERE/fixtures/coord-impl-impl.md" .pipeline/hello-cli/journal.md
  git add -A && git commit -qm seed && git push -q origin main )
cat > "$R/cfg" <<EOF
OBSERVER_WORKDIR=$R/obs
BRANCH=main
CC_WORKDIR=$R/cc
PI_WORKDIR=$R/pi
CODEX_WORKDIR=$R/codex
CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='\$pipeline-review'
POLL_SECS=30
PANE_READY_TIMEOUT_MS=60000
STAGE_TIMEOUT_SECS=2700
EOF
# pane list hangs (sleep 30 holding stdout, NO json); agent explain stays fast.
mkdir -p "$R/bin"
cat > "$R/bin/herdr" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pane list") sleep 30 &; echo "not json, descendant holds the pipe"; exit 0 ;;
  "agent explain") echo '{"agent":"x","state":"idle"}' ;;
  *) exit 0 ;;
esac
S
chmod +x "$R/bin/herdr"
PATH="$R/bin:/usr/bin:/bin" true   # warm
s=$(now); dout=$(env STATE_DIR="$R/state" COORD_PANE_LIST_TIMEOUT_MS=600 COORD_AUTH_TIMEOUT_MS=600 \
    PATH="$R/bin:/usr/bin:/bin" bash "$COORD" doctor --config "$R/cfg" 2>&1); drc=$?; e=$(now)
el=$(elapsed "$s" "$e")
if [ "$drc" -ne 0 ] && printf '%s' "$dout" | grep -q '\[DEPENDENCY_MISSING\].*pane list' \
   && awk -v x="$el" 'BEGIN{exit !(x < 8)}'; then
  ok "doctor bounds hung pane list: rc!=0 + DEPENDENCY_MISSING in ${el}s (no 30s hang)"
else
  bad "doctor bounds hung pane list" "rc=$drc elapsed=${el}s; out: $(printf '%s' "$dout" | grep -i 'pane list' | head -3)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
