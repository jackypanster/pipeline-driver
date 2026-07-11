#!/usr/bin/env bash
# Hermetic end-to-end tests for drive.sh — a STUB `claude` simulates pipeline-impl
# (advance the journal, flip a card, push to a local bare origin). No network, no
# real claude, no external repo. Proves the loop drives and that every safety HALT
# fires. Run: bash test/e2e.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/.."
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0 fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; }

# seed_repo <root> <ncards> [tail-entry-file]
seed_repo() {
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
  cat > "$ROOT/cfg" <<EOF
WORKDIR=$ROOT/work
BRANCH=master
FEATURE=f
EOF
}
# Argv regression guard injected into EVERY claude stub (field failure 2026-07-11):
# the driver must never pass --bare (current Claude Code skips skill loading under
# it), must pass --settings, and -p must START with /pipeline-impl (slash expansion
# requires the skill as the first token). A violation fails the child loudly, which
# fails the e2e case that drove it.
GUARD=$(mktemp)
cat > "$GUARD" <<'G'
_settings=""; _prompt=""; _prev=""
for _a in "$@"; do
  case "$_prev" in --settings) _settings="$_a";; -p) _prompt="$_a";; esac
  case "$_a" in --bare) echo "stub: FORBIDDEN --bare reached the claude child" >&2; exit 1;; esac
  _prev="$_a"
done
[ -n "$_settings" ] || { echo "stub: --settings missing from the claude child argv" >&2; exit 1; }
case "$_prompt" in "/pipeline-impl"*) ;; *) echo "stub: -p must start with /pipeline-impl, got: $_prompt" >&2; exit 1;; esac
G
stub() {
  mkdir -p "$1/bin"
  { head -1 "$2"; cat "$GUARD"; tail -n +2 "$2"; } > "$1/bin/claude"
  chmod +x "$1/bin/claude"
}
# DRIVE_DEFAULTS pinned to a nonexistent path: the operator's REAL global defaults
# (~/.config/pipeline-driver/drive.defaults) must never leak into hermetic tests.
run() { printf '%s\n' "${2:-AAA}" | DRIVE_DEFAULTS=/nonexistent PATH="$1/bin:$PATH" bash "$DRIVER/drive.sh" "$1/cfg" 2>&1; }

# --- stub: implement one card, advance journal, push (NEXT=review on the last) ---
STUB_IMPL=$(mktemp)
cat > "$STUB_IMPL" <<'S'
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
STUB_NOOP=$(mktemp); printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_NOOP"
trap 'rm -f "$STUB_IMPL" "$STUB_NOOP" "$GUARD"' EXIT

# 1) happy path: 3 cards -> HALT at review
R=$(mktemp -d); seed_repo "$R" 3; stub "$R" "$STUB_IMPL"
out=$(run "$R"); echo "$out" | grep -q 'all cards in review' && ok "happy: 3 cards -> review halt" || bad "happy path"; rm -rf "$R"

# 2) wrong spec-rev -> HALT at gate 1, no impl
R=$(mktemp -d); seed_repo "$R" 2; stub "$R" "$STUB_IMPL"
out=$(run "$R" WRONG); echo "$out" | grep -q 'spec-rev not confirmed' && ok "gate-1 rejects wrong spec-rev" || bad "gate-1 reject"; rm -rf "$R"

# 3) re-freeze mid-loop -> HALT
R=$(mktemp -d); seed_repo "$R" 2
RF=$(mktemp); cat > "$RF" <<'S'
#!/usr/bin/env bash
repo=""; for a in "$@"; do case "$a" in *repo=*) repo="${a#*repo=}"; repo="${repo%% *}";; esac; done
cd "$repo"; git pull -q --rebase origin master
card=$(grep -l '^status: todo' .pipeline/f/tasks/*.md | sort | head -1)
sed -i.bak 's/^status: todo/status: review/' "$card"
sed -i.bak 's/^spec-rev: AAA/spec-rev: BBB/' .pipeline/f/tasks/*.md; rm -f .pipeline/f/tasks/*.bak
last=$(grep -Eo '^## seq=[0-9]+' .pipeline/f/journal.md | tail -1 | grep -Eo '[0-9]+'); s=$((last+1))
printf '\n## seq=%s · t · impl→impl · completed · by=stub\ndone: x\noutput: y\n--- handoff ---\n>>> NEXT\nRun pipeline-impl FRESH session.\n<<< END\n' "$s" >> .pipeline/f/journal.md
git add -A && git commit -qm rf && git push -q origin master
S
stub "$R" "$RF"; out=$(run "$R"); echo "$out" | grep -q 'spec-rev changed' && ok "re-freeze -> halt + re-gate" || bad "re-freeze halt"; rm -rf "$R" "$RF"

# 4) no-progress -> HALT
R=$(mktemp -d); seed_repo "$R" 2; stub "$R" "$STUB_NOOP"
out=$(run "$R"); echo "$out" | grep -q 'no progress' && ok "no-progress guard halts" || bad "no-progress"; rm -rf "$R"

# 5) blocked tail -> HALT to hunt
R=$(mktemp -d); BT=$(mktemp); cat > "$BT" <<'EOF'
## seq=6 · t · impl→hunt · blocked · by=stub
done: attempts>=3
output: tasks/01.md
--- handoff ---
>>> NEXT
Run pipeline-hunt on a FRESH session.
<<< END
EOF
seed_repo "$R" 2 "$BT"; stub "$R" "$STUB_NOOP"
out=$(run "$R"); echo "$out" | grep -q 'blocked' && ok "blocked tail -> hunt halt" || bad "blocked halt"; rm -rf "$R" "$BT"

# 6) review->impl rejection -> HALT
R=$(mktemp -d); RJ=$(mktemp); cat > "$RJ" <<'EOF'
## seq=8 · t · review→impl · failed · by=claude/opus
done: review rejected card 02
output: tasks/02.md, reviews/review-01.md
--- handoff ---
>>> NEXT
Run pipeline-impl FRESH session (re-pick card 02).
<<< END
EOF
seed_repo "$R" 2 "$RJ"; stub "$R" "$STUB_NOOP"
out=$(run "$R"); echo "$out" | grep -q 'review rejected' && ok "review->impl rejection halts" || bad "review-reject halt"; rm -rf "$R" "$RJ"

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
