#!/usr/bin/env bash
# Hermetic end-to-end tests for the HERDR transport (IMPL_TRANSPORT=herdr) — a STUB
# `herdr` simulates the Herdr CLI; its `pane run` plays the TUI coder (advance the
# journal, flip a card, push to a local bare origin). No network, no real herdr, no
# real claude. Acceptance surface: .pipeline/herdr-transport/PRD.md (criteria 1-6).
# Run: bash test/e2e-herdr.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Hermetic: this test may itself run inside a Herdr pane (HERDR_* injected) — drop them.
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
pass=0 fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; }

# seed_repo <root> <ncards>  — same journal/card fixtures as test/e2e-orca.sh, herdr cfg
seed_repo() {
  local ROOT=$1 ncards=$2
  git init -q --bare "$ROOT/origin.git"
  git clone -q "$ROOT/origin.git" "$ROOT/work" 2>/dev/null
  ( cd "$ROOT/work"; git checkout -q -b master; mkdir -p .pipeline/f/tasks
    local n; for n in $(seq -w 1 "$ncards"); do
      printf 'status: todo\nattempts: 0\nspec-rev: AAA\nverify: ["true"]\n' > ".pipeline/f/tasks/$n.md"; done
    cat > .pipeline/f/journal.md <<'EOF'
## seq=5 · t · arch→task · completed · by=test
done:   froze cards, spec-rev=AAA
output: tasks
--- handoff ---
>>> NEXT
Run pipeline-impl on the coder TUI, FRESH session.
<<< END
EOF
    git add -A && git commit -qm seed && git push -q origin master ) >/dev/null 2>&1
  cat > "$ROOT/cfg" <<EOF
WORKDIR=$ROOT/work
BRANCH=master
FEATURE=f
IMPL_TRANSPORT=herdr
CARD_TIMEOUT=5
POLL_SECS=0
HERDR_IDLE_TIMEOUT_MS=1500
HERDR_RESET_SETTLE_MS=100
EOF
  # default: ONE agent-bearing pane for the worktree (socket envelope — `pane list`
  # prints it verbatim; there is no --json flag)
  cat > "$ROOT/list.json" <<EOF
{"id":"cli:pane:list","result":{"panes":[
  {"pane_id":"wA:p1","agent":"pi","agent_status":"idle","cwd":"$ROOT/work","foreground_cwd":"$ROOT/work"}
],"type":"pane_list"}}
EOF
}
stub_herdr() { mkdir -p "$1/bin"; cp "$STUB_HERDR" "$1/bin/herdr"; chmod +x "$1/bin/herdr"; }
# DRIVE_DEFAULTS pinned: the operator's real global defaults must not leak in.
run() { printf '%s\n' "${2:-AAA}" | DRIVE_DEFAULTS=/nonexistent PATH="$1/bin:$PATH" bash "$DRIVER/drive.sh" "$1/cfg" 2>&1; }

# --- stub herdr CLI: list/explain/read canned; `pane run` logs + optionally runs
# --- the coder hook. `agent explain` is the guard's single sample source (state +
# --- authority together): state flips to working after any run when
# --- HERDR_STUB_BUSY_AFTER_RUN=1 (simulates a reset keeping the TUI busy);
# --- HERDR_STUB_NO_AUTHORITY=1 serves the exact 0.7.3 unmatched-screen shape
# --- (manifest LOADED, rule NOT matched, always-idle fallback in effect).
STUB_HERDR=$(mktemp)
cat > "$STUB_HERDR" <<'S'
#!/usr/bin/env bash
sub="${1:-} ${2:-}"; shift 2 2>/dev/null || true
case "$sub" in
  "pane list") cat "$HERDR_STUB_LIST_JSON" ;;
  "agent explain")
    [ -n "${HERDR_STUB_HANG:-}" ] && sleep 60   # wedged daemon: never answers
    if [ -n "${HERDR_STUB_HANG_HARD:-}" ]; then  # wedged AND TERM-immune: only KILL ends it
      trap "" TERM; while :; do sleep 1; done
    fi
    st="${HERDR_STUB_STATUS:-idle}"
    if [ -n "${HERDR_STUB_BUSY_AFTER_RUN:-}" ] && [ -s "${HERDR_STUB_RUN_LOG:-/dev/null}" ]; then st="working"; fi
    if [ -n "${HERDR_STUB_FLIP_FILE:-}" ]; then
      # first call: authoritative WORKING (matched rule); later calls: the pane
      # drifted to an unmatched screen — fallback idle (authority lost mid-poll)
      if [ -f "$HERDR_STUB_FLIP_FILE" ]; then
        echo '{"agent":"codex","state":"idle","matched_rule":null,"manifest_source":"remote:codex.toml","screen_detection_skip_reason":null,"fallback_reason":"default_known_agent_idle_fallback"}'
      else
        : > "$HERDR_STUB_FLIP_FILE"
        echo '{"agent":"codex","state":"working","matched_rule":{"id":"osc_title_working","region":"osc_title","state":"working"},"manifest_source":"remote:codex.toml","screen_detection_skip_reason":null,"fallback_reason":null}'
      fi
      exit 0
    fi
    if [ -n "${HERDR_STUB_NO_AUTHORITY:-}" ]; then
      echo '{"agent":"codex","state":"idle","matched_rule":null,"manifest_source":"remote:codex.toml","screen_detection_skip_reason":null,"fallback_reason":"default_known_agent_idle_fallback"}'
    else
      printf '{"agent":"pi","state":"%s","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}\n' "$st"
    fi ;;
  "pane read") echo "stub tui tail line" ;;
  "pane run")
    text="${2:-}"
    [ -n "${HERDR_STUB_RUN_LOG:-}" ] && printf '%s\n' "$text" >> "$HERDR_STUB_RUN_LOG"
    [ -n "${HERDR_STUB_ON_RUN:-}" ] && "$HERDR_STUB_ON_RUN" "$text"
    exit 0 ;;
  *) exit 0 ;;
esac
S

# --- coder hook: on a /pipeline-impl run, act like the TUI finishing one card ----
CODER=$(mktemp)
cat > "$CODER" <<'S'
#!/usr/bin/env bash
text="$1"
case "$text" in *pipeline-impl*) ;; *) exit 0 ;; esac    # ignore reset cmds etc.
repo="${text#*repo=}"; repo="${repo%% *}"
cd "$repo" || exit 1
git pull -q --rebase origin master
card=$(grep -l '^status: todo' .pipeline/f/tasks/*.md 2>/dev/null | sort | head -1) || exit 0
[ -n "$card" ] || exit 0
sed -i.bak 's/^status: todo/status: review/' "$card"; rm -f "$card.bak"
rem=$(grep -l '^status: todo' .pipeline/f/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')
last=$(grep -Eo '^## seq=[0-9]+' .pipeline/f/journal.md | tail -1 | grep -Eo '[0-9]+'); s=$((last+1))
if [ "$rem" -gt 0 ]; then nc="Run pipeline-impl on the coder TUI, FRESH session."
else nc="Run pipeline-review on a FRESH CC session."; fi
printf '\n## seq=%s · t · impl→impl · completed · by=stub-tui\ndone: x\noutput: y\n--- handoff ---\n>>> NEXT\n%s\n<<< END\n' "$s" "$nc" >> .pipeline/f/journal.md
git add -A && git commit -qm "s=$s" && git push -q origin master
S
chmod +x "$CODER"
trap 'rm -f "$STUB_HERDR" "$CODER"' EXIT

# 1) happy path: 2 cards advance through the TUI -> HALT at review. agent_status=done
#    (finished-unviewed) must count as ready — the guard accepts {done,idle}.
R=$(mktemp -d); seed_repo "$R" 2; stub_herdr "$R"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_ON_RUN="$CODER" HERDR_STUB_STATUS=done
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && ok "herdr happy: 2 cards (status=done) -> review halt" || bad "herdr happy path: $out"
unset HERDR_STUB_ON_RUN HERDR_STUB_STATUS; rm -rf "$R"

# 2) TUI stalls (run does nothing) -> CARD_TIMEOUT -> halt with pane tail
R=$(mktemp -d); seed_repo "$R" 2; stub_herdr "$R"
printf 'CARD_TIMEOUT=1\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json"
out=$(run "$R")
echo "$out" | grep -q 'no journal progress' && echo "$out" | grep -q 'stub tui tail' \
  && ok "herdr timeout: stalled TUI -> halt + pane tail" || bad "herdr timeout: $out"
rm -rf "$R"

# 3) ambiguous panes (2 agent-bearing in the worktree) -> preflight halt before GATE 1
R=$(mktemp -d); seed_repo "$R" 2; stub_herdr "$R"
cat > "$R/list.json" <<EOF
{"id":"cli:pane:list","result":{"panes":[
  {"pane_id":"wA:p1","agent":"pi","agent_status":"idle","cwd":"$R/work","foreground_cwd":"$R/work"},
  {"pane_id":"wB:p1","agent":"codex","agent_status":"idle","cwd":"$R/work","foreground_cwd":"$R/work"}
],"type":"pane_list"}}
EOF
export HERDR_STUB_LIST_JSON="$R/list.json"
out=$(run "$R")
echo "$out" | grep -q 'cannot resolve the impl pane' && ok "herdr ambiguity -> preflight halt" || bad "herdr ambiguity: $out"
rm -rf "$R"

# 4) HERDR_PANE_CWD_MATCH: the TUI pane sits in a SUBDIR of the worktree, so the
#    default ==WORKDIR match finds nothing; the substring filter finds exactly it.
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
cat > "$R/list.json" <<EOF
{"id":"cli:pane:list","result":{"panes":[
  {"pane_id":"wA:p1","agent":"pi","agent_status":"idle","cwd":"$R/work/sub","foreground_cwd":"$R/work/sub"}
],"type":"pane_list"}}
EOF
export HERDR_STUB_LIST_JSON="$R/list.json"
out=$(run "$R")
echo "$out" | grep -q 'cannot resolve the impl pane' || bad "herdr cwd-match precondition (default should 0-match): $out"
printf 'HERDR_PANE_CWD_MATCH=%s/work\n' "$R" >> "$R/cfg"
export HERDR_STUB_ON_RUN="$CODER"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && ok "herdr HERDR_PANE_CWD_MATCH subdir pane -> review halt" || bad "herdr cwd match: $out"
unset HERDR_STUB_ON_RUN; rm -rf "$R"

# 5) HERDR_RESET_CMD is sent per card BEFORE the card, via pane run, in order
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
printf 'HERDR_RESET_CMD=/clear\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_ON_RUN="$CODER" HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && [ "$(sed -n 1p "$R/runs.log")" = "/clear" ] \
  && sed -n 2p "$R/runs.log" | grep -q '^/pipeline-impl ' \
  && ok "herdr reset cmd sent before the card (guard -> reset -> guard -> card)" || bad "herdr reset cmd: $out $(cat "$R/runs.log" 2>/dev/null)"
unset HERDR_STUB_ON_RUN HERDR_STUB_RUN_LOG; rm -rf "$R"

# 6) herdr CLI missing from PATH -> preflight halt
R=$(mktemp -d); seed_repo "$R" 1   # no stub installed
out=$(printf 'AAA\n' | DRIVE_DEFAULTS=/nonexistent PATH="$R/bin:/usr/bin:/bin" bash "$DRIVER/drive.sh" "$R/cfg" 2>&1)
echo "$out" | grep -q 'herdr CLI not on PATH' && ok "herdr missing -> preflight halt" || bad "herdr missing: $out"
rm -rf "$R"

# 7) discovery excludes the driver's OWN pane (Herdr injects HERDR_PANE_ID into every
#    pane, incl. the one running drive.sh): two matching panes, one IS the driver ->
#    capture/unset + exclusion leave exactly 1 -> happy path (criterion 6)
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
cat > "$R/list.json" <<EOF
{"id":"cli:pane:list","result":{"panes":[
  {"pane_id":"wS:p1","agent":"claude","agent_status":"idle","cwd":"$R/work","foreground_cwd":"$R/work"},
  {"pane_id":"wC:p1","agent":"pi","agent_status":"idle","cwd":"$R/work","foreground_cwd":"$R/work"}
],"type":"pane_list"}}
EOF
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_ON_RUN="$CODER" HERDR_PANE_ID="wS:p1"
out=$(run "$R")
unset HERDR_PANE_ID
echo "$out" | grep -q 'all cards in review' && echo "$out" | grep -q 'impl pane = wC:p1' \
  && ok "self pane excluded from discovery (injected HERDR_PANE_ID dropped)" || bad "self exclusion: $out"
unset HERDR_STUB_ON_RUN; rm -rf "$R"

# 8) pinned HERDR_PANE_ID == the driver's own pane -> preflight halt (criterion 6)
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
printf 'HERDR_PANE_ID=wS:p1\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_PANE_ID="wS:p1"
out=$(run "$R")
unset HERDR_PANE_ID
echo "$out" | grep -q 'cannot type into itself' && ok "pinned self-pane -> preflight halt" || bad "pinned self: $out"
rm -rf "$R"

# 9) PRE-reset guard failure (agent stays working) is FATAL: ZERO pane run calls
#    (criterion 3 — nothing may be typed into a busy TUI)
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
printf 'HERDR_RESET_CMD=/clear\nCARD_TIMEOUT=1\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_STATUS=working HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
unset HERDR_STUB_STATUS HERDR_STUB_RUN_LOG
{ echo "$out" | grep -q 'not ready within'; } && [ ! -s "$R/runs.log" ] \
  && ok "busy TUI + reset -> fatal, zero pane run calls" || bad "pre-reset guard fatal: $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 10) POST-reset guard failure (reset leaves the TUI busy) is FATAL: exactly ONE
#     pane run call (the reset) and NO card submission (criterion 3)
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
printf 'HERDR_RESET_CMD=/clear\nCARD_TIMEOUT=1\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_BUSY_AFTER_RUN=1 HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
unset HERDR_STUB_BUSY_AFTER_RUN HERDR_STUB_RUN_LOG
{ echo "$out" | grep -q 'not ready within'; } && [ "$(wc -l < "$R/runs.log" | tr -d ' ')" = "1" ] \
  && [ "$(sed -n 1p "$R/runs.log")" = "/clear" ] && ! grep -q 'pipeline-impl' "$R/runs.log" \
  && ok "post-reset busy -> fatal, exactly one run (the reset), no card" || bad "post-reset guard fatal: $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 11) IMPL_SLASH_CMD override (pi skill-command syntax) is submitted verbatim
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
printf 'IMPL_SLASH_CMD=/skill:pipeline-impl\n' >> "$R/cfg"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_ON_RUN="$CODER" HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && grep -q "^/skill:pipeline-impl repo=$R/work branch=master$" "$R/runs.log" \
  && ok "IMPL_SLASH_CMD override submitted verbatim" || bad "IMPL_SLASH_CMD override: $out $(cat "$R/runs.log" 2>/dev/null)"
unset HERDR_STUB_ON_RUN HERDR_STUB_RUN_LOG; rm -rf "$R"

# 12) FAIL CLOSED: state=idle but NOT authoritative — the exact Herdr 0.7.3
#     unmatched-screen shape (manifest_source SET, matched_rule null, always-idle
#     fallback in effect). A loaded-but-unmatched manifest must NOT count as
#     authority: the guard rejects every sample -> fatal, zero pane run calls.
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_NO_AUTHORITY=1 HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
unset HERDR_STUB_NO_AUTHORITY HERDR_STUB_RUN_LOG
echo "$out" | grep -q 'NOT authoritative' && [ ! -s "$R/runs.log" ] \
  && ok "loaded-but-unmatched manifest (fallback idle) -> fail closed, zero sends" || bad "fail closed: $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 13) mid-poll authority loss: first sample is authoritative WORKING (matched rule),
#     then the pane drifts to an unmatched screen and Herdr serves fallback idle.
#     Readiness + authority are validated from the SAME sample — the fallback idle
#     must NOT be accepted: fatal, zero sends.
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_FLIP_FILE="$R/flip" HERDR_STUB_RUN_LOG="$R/runs.log"
out=$(run "$R")
unset HERDR_STUB_FLIP_FILE HERDR_STUB_RUN_LOG
echo "$out" | grep -q 'NOT authoritative' && [ ! -s "$R/runs.log" ] \
  && ok "mid-poll authority loss -> fallback idle rejected, zero sends" || bad "authority loss: $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 14) doctor: IMPL_TRANSPORT=herdr -> herdr checked on PATH (ok with stub, MISS without).
#     PATH is RESTRICTED both times: doctor's info sections shell the real `orca`
#     when present, which hangs without a running Orca app — keep it hermetic.
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
out=$(DRIVE_DEFAULTS=/nonexistent PATH="$R/bin:/usr/bin:/bin" bash "$DRIVER/drive.sh" doctor "$R/cfg" 2>&1)
echo "$out" | grep -q 'ok    herdr on PATH (IMPL_TRANSPORT=herdr)' || bad "doctor herdr ok: $out"
out=$(DRIVE_DEFAULTS=/nonexistent PATH=/usr/bin:/bin bash "$DRIVER/drive.sh" doctor "$R/cfg" 2>&1)
echo "$out" | grep -q 'herdr not on PATH but IMPL_TRANSPORT=herdr' \
  && ok "doctor: herdr present=ok / absent=MISS with remediation" || bad "doctor herdr miss: $out"
rm -rf "$R"

# 15) wedged daemon: `agent explain` hangs (60s) — every sample is KILLED at the
#     remaining budget, so the guard gives up within ~HERDR_IDLE_TIMEOUT_MS instead
#     of hanging, and nothing is sent
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_HANG=1 HERDR_STUB_RUN_LOG="$R/runs.log"
t0=$SECONDS
out=$(run "$R")
dur=$((SECONDS - t0))
unset HERDR_STUB_HANG HERDR_STUB_RUN_LOG
echo "$out" | grep -q 'not ready within' && [ ! -s "$R/runs.log" ] && [ "$dur" -lt 30 ] \
  && ok "hung explain -> sample killed at budget, guard fails in ${dur}s, zero sends" \
  || bad "hung explain: dur=${dur}s $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 16) TERM-immune wedged daemon: explain traps TERM and loops — the watchdog's
#     TERM -> grace -> KILL escalation still ends every sample within ~the budget;
#     the guard gives up, zero sends
R=$(mktemp -d); seed_repo "$R" 1; stub_herdr "$R"
export HERDR_STUB_LIST_JSON="$R/list.json" HERDR_STUB_HANG_HARD=1 HERDR_STUB_RUN_LOG="$R/runs.log"
t0=$SECONDS
out=$(run "$R")
dur=$((SECONDS - t0))
unset HERDR_STUB_HANG_HARD HERDR_STUB_RUN_LOG
echo "$out" | grep -q 'not ready within' && [ ! -s "$R/runs.log" ] && [ "$dur" -lt 30 ] \
  && ok "TERM-immune explain -> KILL escalation, guard fails in ${dur}s, zero sends" \
  || bad "TERM-immune explain: dur=${dur}s $out $(cat "$R/runs.log" 2>/dev/null)"
rm -rf "$R"

# 17) hard-deadline precision (unit-level, ms resolution — case 16's whole-run
#     seconds bound cannot catch a deadline+grace overshoot): a TERM-immune child
#     under run_with_timeout_ms 500 must die AT the ~500ms deadline (TERM is sent
#     at budget-200ms; the grace is carved out of the budget, not appended). The
#     pre-fix implementation measured ~750ms here and must fail this bound.
eval "$(grep '^sleep_ms()' "$DRIVER/drive.sh")"
eval "$(sed -n '/^run_with_timeout_ms()/,/^}/p' "$DRIVER/drive.sh")"
t0=$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)')
run_with_timeout_ms 500 bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 || true
t1=$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)')
dur=$((t1 - t0))
[ "$dur" -ge 450 ] && [ "$dur" -le 680 ] \
  && ok "hard deadline: TERM-immune child killed at ~500ms budget (${dur}ms)" \
  || bad "hard deadline: TERM-immune child took ${dur}ms on a 500ms budget (expected 450-680)"

unset HERDR_STUB_LIST_JSON 2>/dev/null || true
echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
