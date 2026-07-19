#!/usr/bin/env bash
# Hermetic tests for the NOTIFY_EXEC walk-away hook: events (gate1/card/halt) with
# their DRIVE_* env, preflight validation (fail-loud BEFORE GATE 1), and best-effort
# degradation. Reuses the e2e scaffold: local bare origin, stub claude, stub notifier.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

# seed <root> <ncards> [tail-file] — same shape as e2e's seed_repo
seed() {
  local ROOT=$1 ncards=$2 tail=${3:-}
  git init -q --bare "$ROOT/origin.git"
  git clone -q "$ROOT/origin.git" "$ROOT/work" 2>/dev/null
  ( cd "$ROOT/work"; git checkout -q -b master; mkdir -p .pipeline/f/tasks
    local n; for n in $(seq -w 1 "$ncards"); do
      printf 'status: todo\nattempts: 0\nspec-rev: AAA\nverify: ["true"]\n' > ".pipeline/f/tasks/$n.md"; done
    if [ -n "$tail" ]; then cp "$tail" .pipeline/f/journal.md
    else cat > .pipeline/f/journal.md <<'EOF'
## seq=5 · t · arch→task · completed · by=test
done:   froze cards, spec-rev=AAA
output: tasks
--- handoff ---
>>> NEXT
Run pipeline-impl on the Hermes coder profile (goal-driven-implementation), FRESH session.
<<< END
EOF
    fi
    git add -A && git commit -qm seed && git push -q origin master ) >/dev/null 2>&1
  # stub claude: implement one card, advance journal, push (e2e's STUB_IMPL shape)
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/claude" <<'S'
#!/usr/bin/env bash
repo=""; for a in "$@"; do case "$a" in *repo=*) repo="${a#*repo=}"; repo="${repo%% *}";; esac; done
cd "$repo"; git pull -q --rebase origin master
card=$(grep -l '^status: todo' .pipeline/f/tasks/*.md 2>/dev/null | sort | head -1) || { echo "no todo"; exit 1; }
[ -n "$card" ] || { echo "no todo"; exit 1; }
sed -i.bak 's/^status: todo/status: review/' "$card"; rm -f "$card.bak"
rem=$(grep -l '^status: todo' .pipeline/f/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')
last=$(grep -Eo '^## seq=[0-9]+' .pipeline/f/journal.md | tail -1 | grep -Eo '[0-9]+'); s=$((last+1))
if [ "$rem" -gt 0 ]; then nc="Run pipeline-impl on the Hermes coder profile, FRESH session."
else nc="Run pipeline-review on a FRESH CC session."; fi
printf '\n## seq=%s · t · impl→impl · completed · by=stub\ndone: x\noutput: y\n--- handoff ---\n>>> NEXT\n%s\n<<< END\n' "$s" "$nc" >> .pipeline/f/journal.md
git add -A && git commit -qm "s=$s" && git push -q origin master
S
  chmod +x "$ROOT/bin/claude"
  cat > "$ROOT/cfg" <<EOF
WORKDIR=$ROOT/work
BRANCH=master
FEATURE=f
EOF
}
# mk_notifier <root> [exit-code] — logs "<event>|seq=|status=|next=|reason=|hnext=" per call
mk_notifier() {
  cat > "$1/notify.sh" <<EOF
#!/usr/bin/env bash
printf '%s|feature=%s|seq=%s|status=%s|next=%s|reason=%s|hnext=%s\n' \
  "\$1" "\${DRIVE_FEATURE:-}" "\${DRIVE_SEQ:-}" "\${DRIVE_STATUS:-}" "\${DRIVE_NEXT:-}" \
  "\${DRIVE_HALT_REASON:-}" "\${DRIVE_HALT_NEXT:-}" >> "$1/notify.log"
exit ${2:-0}
EOF
  chmod +x "$1/notify.sh"
}
# DRIVE_DEFAULTS pinned to a nonexistent path: hermetic from the operator's real defaults.
run() { printf '%s\n' "${2:-AAA}" | DRIVE_DEFAULTS=/nonexistent PATH="$1/bin:$PATH" bash "$DRIVER/drive.sh" "$1/cfg" 2>&1; }

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

# --- 1. happy path (2 cards): gate1 -> card,card -> halt, with env on each event ---
R=$(mktemp -d); seed "$R" 2; mk_notifier "$R"
printf 'NOTIFY_EXEC=%s/notify.sh\n' "$R" >> "$R/cfg"
out=$(run "$R")
log=$(cat "$R/notify.log" 2>/dev/null)
if grep -q 'all cards in review' <<<"$out" \
   && [ "$(head -1 <<<"$log")" = "gate1|feature=f|seq=|status=|next=|reason=|hnext=" ] \
   && grep -q '^card|feature=f|seq=6|status=completed|next=impl' <<<"$log" \
   && grep -q '^card|feature=f|seq=7|status=completed|next=review' <<<"$log" \
   && tail -1 <<<"$log" | grep -q '^halt|feature=f|seq=7|.*|reason=all cards in review (seq=7).*|hnext=pipeline-review' \
   && [ "$(wc -l <<<"$log" | tr -d ' ')" = "4" ]; then
  ok "happy path: gate1 + 2x card + review halt, env populated"
else bad "happy path events" "$out
--- notify.log ---
$log"; fi
rm -rf "$R"

# --- 2. NOTIFY_EXEC unset: zero invocations, halt unchanged ---
R=$(mktemp -d); seed "$R" 1 "$REVIEW_TAIL"; mk_notifier "$R"
out=$(run "$R")
if grep -q 'all cards in review' <<<"$out" && [ ! -f "$R/notify.log" ]; then
  ok "unset: zero invocations, review halt unchanged"
else bad "unset no-op" "$out"; fi
rm -rf "$R"

# --- 3. failing notifier: warns ONCE, loop + halt unaffected (exit 0) ---
R=$(mktemp -d); seed "$R" 2; mk_notifier "$R" 1
printf 'NOTIFY_EXEC=%s/notify.sh\n' "$R" >> "$R/cfg"
out=$(run "$R"); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'all cards in review' <<<"$out" \
   && [ "$(grep -c 'notify: .* failed (non-fatal)' <<<"$out")" = "1" ] \
   && [ "$(wc -l < "$R/notify.log" | tr -d ' ')" = "4" ]; then
  ok "failing notifier: warn once, loop drives to the review halt anyway"
else bad "failing notifier degradation (rc=$rc)" "$out"; fi
rm -rf "$R"

# --- 4/5/6. preflight validation: fail-loud BEFORE GATE 1, exit 2, impl never runs ---
try_invalid() { # <label> <cfg-line> <expect-substring> <root>
  local R=$4
  printf '%s\n' "$2" >> "$R/cfg"
  out=$(run "$R"); rc=$?
  if [ "$rc" -eq 2 ] && grep -q "$3" <<<"$out" \
     && ! grep -q 'GATE 1 — type the spec-rev' <<<"$out" && [ ! -f "$R/notify.log" ]; then
    ok "preflight: $1 rejected before GATE 1"
  else bad "preflight $1 (rc=$rc)" "$out"; fi
}
R=$(mktemp -d); seed "$R" 1; mk_notifier "$R"
try_invalid "relative path" "NOTIFY_EXEC=notify.sh" "NOTIFY_EXEC not absolute" "$R"; rm -rf "$R"
R=$(mktemp -d); seed "$R" 1
try_invalid "missing file" "NOTIFY_EXEC=$R/nope.sh" "NOTIFY_EXEC not a regular file" "$R"; rm -rf "$R"
R=$(mktemp -d); seed "$R" 1; mk_notifier "$R"; chmod -x "$R/notify.sh"
try_invalid "non-executable" "NOTIFY_EXEC=$R/notify.sh" "NOTIFY_EXEC not executable" "$R"; rm -rf "$R"
R=$(mktemp -d); seed "$R" 1; mk_notifier "$R"; ln -s "$R/notify.sh" "$R/link.sh"
try_invalid "symlink" "NOTIFY_EXEC=$R/link.sh" "NOTIFY_EXEC is a symlink" "$R"; rm -rf "$R"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
