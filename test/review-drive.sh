#!/usr/bin/env bash
# Hermetic end-to-end tests for review-drive.sh — a STUB `gh` serves PR snapshots
# from a state dir (GH_STATE) and a STUB `orca` routes each `terminal send` to a
# hook that plays the reviewer (verdict comments scripted per round) and the fixer
# (advance head + evidence comment). No network, no real gh/orca. Run:
#   bash test/review-drive.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

# --- stub gh: `pr view` renders GH_STATE; `api …compare…` renders compare_status --
STUB_GH=$(mktemp)
cat > "$STUB_GH" <<'S'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    printf '{"state":"%s","mergeable":"%s","headRefOid":"%s","headRefName":"fix/x","baseRefName":"main","title":"stub PR","url":"https://github.com/o/r/pull/7","comments":%s}\n' \
      "$(cat "$GH_STATE/state")" "$(cat "$GH_STATE/mergeable")" \
      "$(cat "$GH_STATE/head")" "$(cat "$GH_STATE/comments.json")" ;;
  "api "*) printf '{"status":"%s"}\n' "$(cat "$GH_STATE/compare_status")" ;;
  *) exit 0 ;;
esac
S

# --- stub orca: list/wait/read canned; send logs handle+text and calls the hook ---
STUB_ORCA=$(mktemp)
cat > "$STUB_ORCA" <<'S'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "terminal list") cat "$ORCA_STUB_LIST_JSON" ;;
  "terminal wait") exit "${ORCA_STUB_WAIT_RC:-0}" ;;
  "terminal read") echo "stub tui tail line" ;;
  "terminal send")
    shift 2; term="" text="" prev=""
    for a in "$@"; do
      [ "$prev" = "--terminal" ] && term="$a"
      [ "$prev" = "--text" ] && text="$a"
      prev="$a"
    done
    [ -n "${ORCA_STUB_SEND_LOG:-}" ] && printf '%s\t%s\n' "$term" "$text" >> "$ORCA_STUB_SEND_LOG"
    [ -n "${ORCA_STUB_ON_SEND:-}" ] && "$ORCA_STUB_ON_SEND" "$term" "$text"
    exit 0 ;;
  *) exit 0 ;;
esac
S

# --- hook: term_rev pops one verdict spec per dispatch from GH_STATE/script;
#     term_fix advances the head and posts the `fixed:` evidence comment -----------
HOOK=$(mktemp)
cat > "$HOOK" <<'S'
#!/usr/bin/env bash
term="$1" text="$2"
add_comment() {
  local n; n=$(jq 'length' "$GH_STATE/comments.json")
  jq --arg b "$1" --arg u "https://stub/comment-$n" '. + [{"url":$u,"body":$b}]' \
    "$GH_STATE/comments.json" > "$GH_STATE/.c" && mv "$GH_STATE/.c" "$GH_STATE/comments.json"
}
case "$term" in
  term_rev)
    spec=$(head -1 "$GH_STATE/script" 2>/dev/null); [ -n "$spec" ] || exit 0
    sed -i.bak '1d' "$GH_STATE/script"; rm -f "$GH_STATE/script.bak"
    h=$(cat "$GH_STATE/head")
    case "$spec" in
      silent) : ;;
      merged) printf 'MERGED' > "$GH_STATE/state" ;;
      approved) add_comment "verdict: approved
reviewed-head: $h
findings: 0
lgtm" ;;
      wronghead:*) add_comment "verdict: changes-requested
reviewed-head: 00000000000000000000000000000000000000ff
findings: ${spec#*:}
stale echo" ;;
      changes-requested:*) add_comment "verdict: changes-requested
reviewed-head: $h
findings: ${spec#*:}
- finding: x.sh:1 breaks on y" ;;
    esac ;;
  term_fix)
    case "$text" in *changes-requested*) ;; *) exit 0 ;; esac
    [ -f "$GH_STATE/fix_silent" ] && exit 0
    n=$(jq 'length' "$GH_STATE/comments.json")
    new=$(printf '%040d' "$((n + 100))")
    printf '%s' "$new" > "$GH_STATE/head"
    [ -f "$GH_STATE/fix_no_comment" ] && exit 0
    add_comment "fixed: $new
evidence: reproduced, patched, re-verified" ;;
esac
exit 0
S
chmod +x "$STUB_GH" "$STUB_ORCA" "$HOOK"
trap 'rm -f "$STUB_GH" "$STUB_ORCA" "$HOOK"' EXIT

seed() { # <root>  — fresh state dir + config + stubs on PATH
  local R=$1
  mkdir -p "$R/bin" "$R/state"
  cp "$STUB_GH" "$R/bin/gh"; cp "$STUB_ORCA" "$R/bin/orca"
  chmod +x "$R/bin/gh" "$R/bin/orca"
  printf 'OPEN'      > "$R/state/state"
  printf 'MERGEABLE' > "$R/state/mergeable"
  printf '%040d' 1   > "$R/state/head"
  printf '[]'        > "$R/state/comments.json"
  printf 'ahead'     > "$R/state/compare_status"
  cat > "$R/list.json" <<EOF
{"ok":true,"result":{"terminals":[
  {"handle":"term_rev","worktreePath":"/x","title":"codex","connected":true,"writable":true},
  {"handle":"term_fix","worktreePath":"/y","title":"pi","connected":true,"writable":true}
]}}
EOF
  cat > "$R/cfg" <<EOF
REVIEW_REPO=o/r
REVIEW_TERMINAL_HANDLE=term_rev
FIX_TERMINAL_HANDLE=term_fix
MAX_ROUNDS=5
HUNT_AFTER=3
POLL_SECS=0
REVIEW_TIMEOUT=3
FIX_TIMEOUT=3
ORCA_IDLE_TIMEOUT_MS=500
EOF
}
# run <root> [gate-answer] [pr-arg]  — DRIVE_DEFAULTS pinned so real defaults never leak in
run() {
  printf '%s\n' "${2:-7}" \
    | DRIVE_DEFAULTS=/nonexistent GH_STATE="$1/state" ORCA_STUB_LIST_JSON="$1/list.json" \
      ORCA_STUB_ON_SEND="$HOOK" ORCA_STUB_SEND_LOG="$1/sends.log" PATH="$1/bin:$PATH" \
      bash "$DRIVER/review-drive.sh" "${3:-7}" "$1/cfg" 2>&1
}

# 1) approved on round 1 (PR given as URL) -> success halt, no fixer dispatch
R=$(mktemp -d); seed "$R"; echo "approved" > "$R/state/script"
out=$(run "$R" 7 "https://github.com/o/r/pull/7")
echo "$out" | grep -q 'verdict: approved at round 1' \
  && ! grep -q "^term_fix" "$R/sends.log" \
  && ok "round-1 approve (URL arg) -> merge-gate halt" || bad "round-1 approve: $out"
rm -rf "$R"

# 2) converge in 3 rounds (3 -> 1 -> approved): 3 review + 2 fix dispatches, digest rows
R=$(mktemp -d); seed "$R"
printf 'changes-requested:3\nchanges-requested:1\napproved\n' > "$R/state/script"
out=$(run "$R")
nr=$(grep -c "^term_rev" "$R/sends.log"); nf=$(grep -c "^term_fix" "$R/sends.log")
echo "$out" | grep -q 'verdict: approved at round 3' && [ "$nr" = 3 ] && [ "$nf" = 2 ] \
  && echo "$out" | grep -q 'round  verdict' \
  && ok "3-round convergence -> approved (digest printed)" || bad "3-round convergence: $out"
rm -rf "$R"

# 3) round cap: MAX_ROUNDS=2, still changes-requested at review 2 -> cap halt, 1 fix only
R=$(mktemp -d); seed "$R"; printf 'MAX_ROUNDS=2\n' >> "$R/cfg"
printf 'changes-requested:3\nchanges-requested:2\n' > "$R/state/script"
out=$(run "$R")
nf=$(grep -c "^term_fix" "$R/sends.log")
echo "$out" | grep -q 'round cap' && [ "$nf" = 1 ] \
  && ok "round cap halts before another fix" || bad "round cap: $out"
rm -rf "$R"

# 4) no-progress: findings 4,4,4 -> halt after review 3 (2 consecutive non-decreases)
R=$(mktemp -d); seed "$R"
printf 'changes-requested:4\nchanges-requested:4\nchanges-requested:4\n' > "$R/state/script"
out=$(run "$R")
nr=$(grep -c "^term_rev" "$R/sends.log")
echo "$out" | grep -q 'no convergence' && [ "$nr" = 3 ] \
  && ok "no-progress detector halts at review 3" || bad "no-progress: $out"
rm -rf "$R"

# 5) HUNT_AFTER=2: fix 1 is normal, fix 2 carries the root-cause template
R=$(mktemp -d); seed "$R"; printf 'HUNT_AFTER=2\n' >> "$R/cfg"
printf 'changes-requested:5\nchanges-requested:4\napproved\n' > "$R/state/script"
out=$(run "$R")
f1=$(grep "^term_fix" "$R/sends.log" | sed -n 1p); f2=$(grep "^term_fix" "$R/sends.log" | sed -n 2p)
case "$f1" in *root-cause*) bad "hunt switch: fix 1 already hunt-mode" ;; *)
  case "$f2" in *root-cause*) ok "HUNT_AFTER switches fix 2 to root-cause mode" ;;
                *) bad "hunt switch: fix 2 lacks root-cause template: $f2" ;; esac ;; esac
rm -rf "$R"

# 6) reviewer never posts -> REVIEW_TIMEOUT halt + reviewer terminal tail
R=$(mktemp -d); seed "$R"; echo "silent" > "$R/state/script"
out=$(run "$R")
echo "$out" | grep -q 'no verdict comment within' && echo "$out" | grep -q 'stub tui tail' \
  && ok "review timeout -> halt + terminal tail" || bad "review timeout: $out"
rm -rf "$R"

# 7) reviewer echoes the WRONG head -> stale-review halt
R=$(mktemp -d); seed "$R"; echo "wronghead:2" > "$R/state/script"
out=$(run "$R")
echo "$out" | grep -q 'stale or misdirected review' \
  && ok "reviewed-head mismatch -> halt" || bad "stale review: $out"
rm -rf "$R"

# 8) fixer force-pushes (compare says diverged) -> halt
R=$(mktemp -d); seed "$R"; printf 'diverged' > "$R/state/compare_status"
printf 'changes-requested:3\n' > "$R/state/script"
out=$(run "$R")
echo "$out" | grep -q 'history was rewritten' \
  && ok "diverged compare -> force-push halt" || bad "force-push: $out"
rm -rf "$R"

# 9) fixer pushes but posts no evidence comment -> FIX_TIMEOUT halt + fixer tail
R=$(mktemp -d); seed "$R"; touch "$R/state/fix_no_comment"
printf 'changes-requested:3\n' > "$R/state/script"
out=$(run "$R")
echo "$out" | grep -q "no pushed fix + 'fixed:' evidence" \
  && ok "push without evidence comment -> fix timeout halt" || bad "fix no-evidence: $out"
rm -rf "$R"

# 10) PR merged mid-loop (human intervened) -> halt, not an error
R=$(mktemp -d); seed "$R"; echo "merged" > "$R/state/script"
out=$(run "$R")
echo "$out" | grep -q 'merged out from under' \
  && ok "mid-loop merge -> halt" || bad "mid-loop merge: $out"
rm -rf "$R"

# 11) reviewer and fixer pinned to the SAME terminal -> preflight config halt
R=$(mktemp -d); seed "$R"
sed -i.bak 's/^FIX_TERMINAL_HANDLE=.*/FIX_TERMINAL_HANDLE=term_rev/' "$R/cfg"; rm -f "$R/cfg.bak"
out=$(run "$R")
echo "$out" | grep -q 'SAME terminal' \
  && ok "shared reviewer/fixer terminal -> preflight halt" || bad "same terminal: $out"
rm -rf "$R"

# 12) start gate: typing the wrong PR number refuses to loop
R=$(mktemp -d); seed "$R"; echo "approved" > "$R/state/script"
out=$(run "$R" 999)
echo "$out" | grep -q 'PR number not confirmed' && [ ! -f "$R/sends.log" ] \
  && ok "start gate rejects a wrong PR number" || bad "start gate: $out"
rm -rf "$R"

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
