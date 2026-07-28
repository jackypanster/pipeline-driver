#!/usr/bin/env bash
# Hermetic tests for BOARD_OUT auto-refresh.
# Reuses the e2e scaffold: local bare origin, stub claude/node on PATH.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

REVIEW_TAIL=$(mktemp)
cat > "$REVIEW_TAIL" <<'EOF'
## seq=9 · t · impl→review · completed · by=stub
done: all cards green
output: tasks
--- handoff ---
>>> NEXT
Run pipeline-review on a FRESH CC session.
<<< END
EOF
trap 'rm -f "$REVIEW_TAIL"' EXIT

# seed <root> — repo whose journal tail already routes to review (halts after GATE 1)
seed() {
  local ROOT=$1
  git init -q --bare "$ROOT/origin.git"
  git clone -q "$ROOT/origin.git" "$ROOT/work" 2>/dev/null
  ( cd "$ROOT/work"; git checkout -q -b master; mkdir -p .pipeline/f/tasks
    printf 'status: review\nattempts: 0\nspec-rev: AAA\nverify: ["true"]\n' > .pipeline/f/tasks/01.md
    cp "$REVIEW_TAIL" .pipeline/f/journal.md
    git add -A && git commit -qm seed && git push -q origin master ) >/dev/null 2>&1
  mkdir -p "$ROOT/bin" "$ROOT/dash/dist"
  : > "$ROOT/dash/dist/cli.js"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/claude"
  printf '#!/bin/sh\necho "$@" >> %s/node.log\nexit 0\n' "$ROOT" > "$ROOT/bin/node"
  chmod +x "$ROOT/bin/"*
  cat > "$ROOT/cfg" <<EOF
WORKDIR=$ROOT/work
BRANCH=master
FEATURE=f
DASHBOARD_REPO=$ROOT/dash
EOF
}
run() { # <root> <stdin-text>
  printf '%s' "$2" | PATH="$1/bin:$PATH" DRIVE_DEFAULTS=/nonexistent bash "$DRIVER/drive.sh" "$1/cfg" 2>&1
}

# --- 1. BOARD_OUT set: board rendered at GATE 1 and on the review halt ---
R=$(mktemp -d); seed "$R"
printf 'BOARD_OUT=%s/board.html\n' "$R" >> "$R/cfg"
out=$(run "$R" 'AAA
')
if grep -q "all cards in review" <<<"$out" \
   && [ -f "$R/node.log" ] && [ "$(grep -c -- "--out $R/board.html" "$R/node.log")" -ge 2 ]; then
  ok "BOARD_OUT: rendered after GATE 1 + on halt"
else bad "BOARD_OUT renders" "$out"; fi
rm -rf "$R"

# --- 2. BOARD_OUT empty: no render at all ---
R=$(mktemp -d); seed "$R"
out=$(run "$R" 'AAA
')
if grep -q "all cards in review" <<<"$out" && [ ! -f "$R/node.log" ]; then
  ok "BOARD_OUT off by default: zero renders"
else bad "BOARD_OUT off" "$out"; fi
rm -rf "$R"

# --- 3. the review halt is a plain halt(): banner, exit 0, nothing prompted ---
# The one-key relay that used to sit between the banner and the exit was retired
# with the orca transport (the CC coordinator dispatches review now), so this halt
# takes the same code path as every other one — no interactive tail.
R=$(mktemp -d); seed "$R"
out=$(run "$R" 'AAA
'); rc=$?
if [ "$rc" -eq 0 ] && grep -q "=== DRIVER HALT ===" <<<"$out" \
   && grep -q "all cards in review" <<<"$out" && ! grep -qi "relay" <<<"$out"; then
  ok "review halt: banner + exit 0, no relay prompt"
else bad "review halt shape (rc=$rc)" "$out"; fi
rm -rf "$R"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
