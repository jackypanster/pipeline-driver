#!/usr/bin/env bash
# Hermetic tests for BOARD_OUT auto-refresh + the one-key review relay.
# Reuses the e2e scaffold: local bare origin, stub claude/node/orca on PATH.
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
  cat > "$ROOT/bin/orca" <<ORC
#!/bin/sh
echo "\$@" >> $ROOT/orca.log
case "\$2" in
  list) printf '{"result":{"terminals":[{"handle":"term_nul","title":null,"worktreePath":"/y","connected":true,"writable":true},{"handle":"term_rev1","title":"codex review","worktreePath":"/x","connected":true,"writable":true}]}}\n' ;;
esac
exit 0
ORC
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

# --- 3. relay via pinned handle: y sends the review stage command ---
R=$(mktemp -d); seed "$R"
printf 'REVIEW_TERMINAL_HANDLE=term_rev1\n' >> "$R/cfg"
out=$(run "$R" 'AAA
y
')
if grep -q "review relay: sent" <<<"$out" \
   && grep -q -- "send --terminal term_rev1 --text /pipeline-review repo=$R/work branch=master --enter" "$R/orca.log"; then
  ok "relay: y -> review command typed into the pinned terminal"
else bad "relay y (pinned handle)" "$out
--- orca.log ---
$(cat "$R/orca.log" 2>/dev/null)"; fi
rm -rf "$R"

# --- 4. relay: n (or anything else) skips, nothing sent ---
R=$(mktemp -d); seed "$R"
printf 'REVIEW_TERMINAL_HANDLE=term_rev1\n' >> "$R/cfg"
out=$(run "$R" 'AAA
n
')
if grep -q "review relay: skipped" <<<"$out" && ! grep -q " send " "$R/orca.log" 2>/dev/null; then
  ok "relay: n -> skipped, no send"
else bad "relay n" "$out"; fi
rm -rf "$R"

# --- 5. relay via title discovery (jq path), unique match ---
if command -v jq >/dev/null 2>&1; then
  R=$(mktemp -d); seed "$R"
  printf 'REVIEW_TERMINAL_TITLE=codex\n' >> "$R/cfg"
  out=$(run "$R" 'AAA
y
')
  if grep -q "review relay: sent" <<<"$out" && grep -q -- "--terminal term_rev1" "$R/orca.log"; then
    ok "relay: title discovery survives a null-title terminal in the list"
  else bad "relay title discovery (null-title regression)" "$out"; fi
  rm -rf "$R"
else
  echo "skip title-discovery case (no jq)"
fi

# --- 6. unconfigured relay: silent, halt unchanged ---
R=$(mktemp -d); seed "$R"
out=$(run "$R" 'AAA
')
if grep -q "all cards in review" <<<"$out" && ! grep -q "review relay" <<<"$out"; then
  ok "relay unconfigured: silent no-op, review halt unchanged"
else bad "relay unconfigured" "$out"; fi
rm -rf "$R"

# --- 7. ordering: the DRIVER HALT banner prints BEFORE the y/N prompt ---
R=$(mktemp -d); seed "$R"
printf 'REVIEW_TERMINAL_HANDLE=term_rev1\n' >> "$R/cfg"
out=$(run "$R" 'AAA
n
')
bl=$(grep -n "=== DRIVER HALT ===" <<<"$out" | head -1 | cut -d: -f1)
pl=$(grep -n "review relay — send" <<<"$out" | head -1 | cut -d: -f1)
if [ -n "$bl" ] && [ -n "$pl" ] && [ "$bl" -lt "$pl" ]; then
  ok "ordering: halt banner (line $bl) precedes the relay prompt (line $pl)"
else bad "ordering banner-before-prompt (banner=$bl prompt=$pl)" "$out"; fi
rm -rf "$R"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
