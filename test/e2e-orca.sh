#!/usr/bin/env bash
# Hermetic end-to-end tests for the ORCA transport (IMPL_TRANSPORT=orca) — a STUB
# `orca` simulates the Orca CLI; its `terminal send` plays the TUI coder (advance
# the journal, flip a card, push to a local bare origin). No network, no real orca,
# no real claude. Run: bash test/e2e-orca.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0 fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; }

# seed_repo <root> <ncards>  — same journal/card fixtures as test/e2e.sh, orca cfg
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
IMPL_TRANSPORT=orca
CARD_TIMEOUT=5
POLL_SECS=0
ORCA_IDLE_TIMEOUT_MS=500
EOF
  # default: ONE matching terminal for the worktree
  cat > "$ROOT/list.json" <<EOF
{"ok":true,"result":{"terminals":[
  {"handle":"term_stub1","worktreePath":"$ROOT/work","title":"impl — omp","connected":true,"writable":true}
]}}
EOF
}
stub_orca() { mkdir -p "$1/bin"; cp "$STUB_ORCA" "$1/bin/orca"; chmod +x "$1/bin/orca"; }
run() { printf '%s\n' "${2:-AAA}" | PATH="$1/bin:$PATH" bash "$DRIVER/drive.sh" "$1/cfg" 2>&1; }

# --- stub orca CLI: list/wait/read canned; send optionally runs the coder hook ----
STUB_ORCA=$(mktemp)
cat > "$STUB_ORCA" <<'S'
#!/usr/bin/env bash
sub="${1:-} ${2:-}"; shift 2 2>/dev/null || true
case "$sub" in
  "terminal list") cat "$ORCA_STUB_LIST_JSON" ;;
  "terminal wait") exit "${ORCA_STUB_WAIT_RC:-0}" ;;
  "terminal read") echo "stub tui tail line" ;;
  "terminal send")
    text=""; prev=""
    for a in "$@"; do [ "$prev" = "--text" ] && text="$a"; prev="$a"; done
    [ -n "${ORCA_STUB_SEND_LOG:-}" ] && printf '%s\n' "$text" >> "$ORCA_STUB_SEND_LOG"
    [ -n "${ORCA_STUB_ON_SEND:-}" ] && "$ORCA_STUB_ON_SEND" "$text"
    exit 0 ;;
  *) exit 0 ;;
esac
S

# --- coder hook: on a /pipeline-impl send, act like the TUI finishing one card ----
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
trap 'rm -f "$STUB_ORCA" "$CODER"' EXIT

# 1) happy path: 2 cards advance through the TUI -> HALT at review
R=$(mktemp -d); seed_repo "$R" 2; stub_orca "$R"
export ORCA_STUB_LIST_JSON="$R/list.json" ORCA_STUB_ON_SEND="$CODER"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && ok "orca happy: 2 cards -> review halt" || bad "orca happy path: $out"
unset ORCA_STUB_ON_SEND; rm -rf "$R"

# 2) TUI stalls (send does nothing) -> CARD_TIMEOUT -> halt with terminal tail
R=$(mktemp -d); seed_repo "$R" 2; stub_orca "$R"
printf 'CARD_TIMEOUT=1\n' >> "$R/cfg"
export ORCA_STUB_LIST_JSON="$R/list.json"
out=$(run "$R")
echo "$out" | grep -q 'no journal progress' && echo "$out" | grep -q 'stub tui tail' \
  && ok "orca timeout: stalled TUI -> halt + terminal tail" || bad "orca timeout: $out"
rm -rf "$R"

# 3) ambiguous terminals (2 match, no title) -> preflight halt before GATE 1
R=$(mktemp -d); seed_repo "$R" 2; stub_orca "$R"
cat > "$R/list.json" <<EOF
{"ok":true,"result":{"terminals":[
  {"handle":"term_a","worktreePath":"$R/work","title":"cc","connected":true,"writable":true},
  {"handle":"term_b","worktreePath":"$R/work","title":"impl — omp","connected":true,"writable":true}
]}}
EOF
export ORCA_STUB_LIST_JSON="$R/list.json"
out=$(run "$R")
echo "$out" | grep -q 'cannot resolve the impl terminal' && ok "orca ambiguity -> preflight halt" || bad "orca ambiguity: $out"
rm -rf "$R"

# 4) ORCA_TERMINAL_TITLE disambiguates the same 2-terminal listing -> happy path
R=$(mktemp -d); seed_repo "$R" 2; stub_orca "$R"
cat > "$R/list.json" <<EOF
{"ok":true,"result":{"terminals":[
  {"handle":"term_a","worktreePath":"$R/work","title":"cc","connected":true,"writable":true},
  {"handle":"term_b","worktreePath":"$R/work","title":"impl — omp","connected":true,"writable":true}
]}}
EOF
printf 'ORCA_TERMINAL_TITLE=impl\n' >> "$R/cfg"
export ORCA_STUB_LIST_JSON="$R/list.json" ORCA_STUB_ON_SEND="$CODER"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && ok "orca title disambiguation -> review halt" || bad "orca title: $out"
unset ORCA_STUB_ON_SEND; rm -rf "$R"

# 5) ORCA_RESET_CMD is sent per card and ignored by the coder
R=$(mktemp -d); seed_repo "$R" 1; stub_orca "$R"
printf 'ORCA_RESET_CMD=/clear\n' >> "$R/cfg"
export ORCA_STUB_LIST_JSON="$R/list.json" ORCA_STUB_ON_SEND="$CODER" ORCA_STUB_SEND_LOG="$R/sends.log"
out=$(run "$R")
echo "$out" | grep -q 'all cards in review' && grep -q '^/clear$' "$R/sends.log" \
  && ok "orca reset cmd sent before the card" || bad "orca reset cmd: $out"
unset ORCA_STUB_ON_SEND ORCA_STUB_SEND_LOG; rm -rf "$R"

# 6) orca CLI missing from PATH -> preflight halt
R=$(mktemp -d); seed_repo "$R" 1   # no stub installed
out=$(printf 'AAA\n' | PATH="$R/bin:/usr/bin:/bin" bash "$DRIVER/drive.sh" "$R/cfg" 2>&1)
echo "$out" | grep -q 'orca CLI not on PATH' && ok "orca missing -> preflight halt" || bad "orca missing: $out"
rm -rf "$R"

unset ORCA_STUB_LIST_JSON 2>/dev/null || true
echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
