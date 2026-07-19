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
  ( cd "$ROOT/work" || exit; git checkout -q -b master; mkdir -p .pipeline/f/tasks
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
cd "$repo" || exit 1; git pull -q --rebase origin master
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

# --- 8. hanging/TERM-immune notifier: hard deadline kills it, warn once, loop done ---
# Finding 2: `/usr/bin/yes` (or any TERM-immune send) used to block gate1/card/halt
# forever. run_notify now kills the notifier's whole process group at
# NOTIFY_TIMEOUT_MS (TERM then KILL) and degrades to a single warn.
R=$(mktemp -d); seed "$R" 2
cat > "$R/notify.sh" <<'N'
#!/usr/bin/env bash
trap '' TERM          # ignore TERM -> forces the watchdog's KILL escalation
sleep 60              # wedge: well past NOTIFY_TIMEOUT_MS
N
chmod +x "$R/notify.sh"
printf 'NOTIFY_EXEC=%s/notify.sh\nNOTIFY_TIMEOUT_MS=300\n' "$R" >> "$R/cfg"
start=$SECONDS; out=$(run "$R"); rc=$?; elapsed=$((SECONDS-start))
if [ "$rc" -eq 0 ] && grep -q 'all cards in review' <<<"$out" \
   && [ "$(grep -c 'exceeded the .*ms deadline and was killed' <<<"$out")" = "1" ] \
   && [ "$elapsed" -lt 25 ]; then
  ok "deadline: TERM-immune notifier killed (warn once), loop reaches the review halt in ${elapsed}s"
else bad "deadline (rc=$rc elapsed=${elapsed}s)" "$out"; fi
rm -rf "$R"

# --- 9. stdin from /dev/null: notifier sees EOF, cannot steal later operator input ---
# Finding 3: the notifier used to inherit the driver's stdin, so it could consume
# the sentinel meant for the review-relay prompt (or block on read). run_notify now
# redirects the notifier's stdin from /dev/null -> immediate EOF.
R=$(mktemp -d); seed "$R" 2
cat > "$R/notify.sh" <<EOF
#!/usr/bin/env bash
if IFS= read -r ln; then printf 'got=%s\\n' "\$ln" >> "$R/stdinprobe"; else printf 'eof\\n' >> "$R/stdinprobe"; fi
exit 0
EOF
chmod +x "$R/notify.sh"
printf 'NOTIFY_EXEC=%s/notify.sh\n' "$R" >> "$R/cfg"
# Feed drive's stdin = the GATE 1 spec-rev (AAA) FOLLOWED by a sentinel. GATE 1 reads
# AAA; a stdin-inheriting notifier could then steal the sentinel. With stdin from
# /dev/null the notifier must see immediate EOF instead.
out=$(printf 'AAA\noperator-input-sentinel\n' | DRIVE_DEFAULTS=/nonexistent PATH="$R/bin:$PATH" bash "$DRIVER/drive.sh" "$R/cfg" 2>&1); rc=$?
probe=$(cat "$R/stdinprobe" 2>/dev/null)
if [ "$rc" -eq 0 ] && grep -q 'all cards in review' <<<"$out" \
   && grep -q '^eof$' <<<"$probe" && ! grep -q 'operator-input-sentinel' <<<"$probe"; then
  ok "stdin: notifier sees /dev/null EOF, does not steal the post-GATE-1 sentinel"
else bad "stdin isolation (rc=$rc)" "out=$out
probe=$probe"; fi
rm -rf "$R"

# --- 10. cleared env: ambient secrets absent, DRIVE_* context + opt-in name present ---
# Finding 4: the notifier used to inherit the whole exported ambient environment, so
# GH_TOKEN/ANTHROPIC_* (and the secret named by IMPL_AUTH_TOKEN_ENV) leaked into it.
# run_notify now launches via `env -i` with an explicit allowlist (PATH/HOME + DRIVE_*
# + the NAMES in NOTIFY_ENV_ALLOW).
R=$(mktemp -d); seed "$R" 2
cat > "$R/notify.sh" <<EOF
#!/usr/bin/env bash
{ printf 'GH_TOKEN=%s\\n' "\${GH_TOKEN:-}"; printf 'ANTHROPIC_AUTH_TOKEN=%s\\n' "\${ANTHROPIC_AUTH_TOKEN:-}"; \
  printf 'BOGUS_SECRET=%s\\n' "\${BOGUS_SECRET:-}"; printf 'DRIVE_FEATURE=%s\\n' "\${DRIVE_FEATURE:-}"; \
  printf 'ALLOWED_TOKEN=%s\\n' "\${ALLOWED_TOKEN:-}"; } >> "$R/envprobe"
exit 0
EOF
chmod +x "$R/notify.sh"
printf 'NOTIFY_EXEC=%s/notify.sh\nNOTIFY_ENV_ALLOW=ALLOWED_TOKEN\n' "$R" >> "$R/cfg"
out=$(printf 'AAA\n' | DRIVE_DEFAULTS=/nonexistent BOGUS_SECRET=leaked GH_TOKEN=ambient-token \
      ANTHROPIC_AUTH_TOKEN=should-not-leak ALLOWED_TOKEN=opted-in PATH="$R/bin:$PATH" \
      bash "$DRIVER/drive.sh" "$R/cfg" 2>&1); rc=$?
probe=$(cat "$R/envprobe" 2>/dev/null)
if [ "$rc" -eq 0 ] && grep -q 'all cards in review' <<<"$out" \
   && grep -q '^GH_TOKEN=$'  <<<"$probe" && grep -q '^ANTHROPIC_AUTH_TOKEN=$' <<<"$probe" \
   && grep -q '^BOGUS_SECRET=$' <<<"$probe" \
   && grep -q '^DRIVE_FEATURE=f$' <<<"$probe" && grep -q '^ALLOWED_TOKEN=opted-in$' <<<"$probe"; then
  ok "env: ambient secrets absent, DRIVE_* context + NOTIFY_ENV_ALLOW name forwarded"
else bad "env isolation (rc=$rc)" "out=$out
probe=$probe"; fi
rm -rf "$R"

# --- 11. seed/stub cd guards: a failed cd exits the subshell before any write ---
# Finding 5: previously a failed `git clone` left `cd "$ROOT/work"` failing but the
# subshell continuing, creating/staging .pipeline/f/... in the CALLER's cwd. The
# `cd ... || exit` guard (seed() here + the generated stub's `cd "$repo" || exit 1`)
# stops it. Sabotage the clone so the seed subshell's cd fails, then assert the
# caller's cwd stays clean.
orig=$(pwd); SCRATCH=$(mktemp -d); cd "$SCRATCH"
R=$(mktemp -d); : > "$R/work"        # clone target exists as a file -> clone fails, $R/work stays a file
seed "$R" 1 >/dev/null 2>&1
if [ ! -d ".pipeline/f" ] && [ ! -f ".pipeline/f/tasks/01.md" ]; then
  ok "cd guard: failed clone -> subshell exits before writing in the caller cwd"
else bad "cd guard (caller cwd polluted)" "$(pwd); ls -R .pipeline 2>/dev/null)"; fi
cd "$orig"; rm -rf "$R" "$SCRATCH"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
