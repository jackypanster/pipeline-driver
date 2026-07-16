#!/usr/bin/env bash
# Regression tests for finding 6: the state safety / integrity preflight.
#   - STATE_DIR containment by PHYSICAL resolution (realpath, not lexical prefix):
#     ".." and a symlink resolving INTO a clone are rejected.
#   - When state exists: dir modes 0700, file modes 0600, no symlinked files or
#     symlinked parents — all BLOCKING.
#   - Ledger integrity requires the actual §13 schema (feature / seq / full commit
#     / role / pane / delivery ∈ pending|sent|waiting), not just valid JSON.
# Panes are intentionally not stubbed (a pane MISS is harmless — we assert on the
# state-section codes that fire regardless).
# Run: bash test/coordinate-state.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
# Resolve the temp dir to its PHYSICAL path (macOS $TMPDIR is under /var -> /private/var,
# a symlink). The new symlinked-parent check walks the state root's ancestor chain,
# so a temp base behind a system symlink would false-positive; a physical base keeps
# the "valid state" cases clean and lets the symlinked-parent case be constructed
# explicitly.
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; }

seed_clones() {
  local root=$1 c
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
}

# write_cfg <root> <STATE_DIR>: a valid §11 baseline (workdirs/remote/branch pass),
# so doctor reaches the local-state section. STATE_DIR is set explicitly per case.
write_cfg() {
  cat > "$1/cfg" <<EOF
OBSERVER_WORKDIR=$1/obs
BRANCH=main
CC_WORKDIR=$1/cc
PI_WORKDIR=$1/pi
CODEX_WORKDIR=$1/codex
CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='\$pipeline-review'
POLL_SECS=30
PANE_READY_TIMEOUT_MS=60000
STAGE_TIMEOUT_SECS=2700
STATE_DIR=$2
EOF
}

# run_doctor <root>: no herdr; pane misses are harmless (we assert state codes).
run_doctor() { env PATH=/usr/bin:/bin bash "$COORD" doctor --config "$1/cfg" 2>&1; }
assert_code() {  # <label> <code> <root>
  local label=$1 code=$2 root=$3 out rc
  out=$(run_doctor "$root"); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "\[$code\]"; then
    ok "$label"
  else
    bad "$label" "expected rc!=0 + [$code]; rc=$rc; $(printf '%s' "$out" | grep -E '\[CONFIG_INVALID\]|\[LEDGER_CORRUPT\]|state' | head -6)"
  fi
}
assert_no_code() {  # <label> <code> <root>: code MUST NOT appear (valid state)
  local out; out=$(run_doctor "$3")
  if ! printf '%s' "$out" | grep -q "\[$2\]"; then ok "$1"
  else bad "$1" "unexpected [$2] in output: $(printf '%s' "$out" | grep "$2" | head -3)"; fi
}

# state_dir_of <root>: the repo key coordinate.sh derives, read from doctor's OWN
# "normalized repo key:" output (no test hook, no formula drift).
state_dir_of() {
  env PATH=/usr/bin:/bin bash "$COORD" doctor --config "$1/cfg" 2>/dev/null \
    | awk '/^ok    normalized repo key:/ {sub(/^ok    normalized repo key: /,""); print; exit}'
}

# mkstate <root> <mode_dirs> <mode_files>: create a 0700/0600 state tree for the
# repo with one feature carrying a full-§13-schema ledger (incl. command name).
# Modes overridable per case.
mkstate() {
  local root=$1 dmode=$2 fmode=$3 repodir feat
  repodir="$root/state/$(state_dir_of "$root")"
  feat="$repodir/hello-cli"
  mkdir -p "$feat"; chmod "$dmode" "$root/state" "$repodir" "$feat"
  printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","command":"pipeline-impl","delivery":"sent"}' > "$feat/ledger.json"
  chmod "$fmode" "$feat/ledger.json"
}

# ===== 1. STATE_DIR containment via ".." (lexical prefix hides it) -> CONFIG_INVALID =====
fresh; seed_clones "$T"; mkdir -p "$T/outside"; write_cfg "$T" "$T/outside/../cc/.state"
assert_code "STATE_DIR '..' resolves into a clone -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 2. STATE_DIR containment via symlink into a clone -> CONFIG_INVALID =====
fresh; seed_clones "$T"; ln -s "$T/cc" "$T/into-cc"; write_cfg "$T" "$T/into-cc/.state"
assert_code "STATE_DIR symlink into a clone -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 3. valid 0700/0600 state tree with full-schema ledger -> no CONFIG_INVALID/LEDGER_CORRUPT =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
assert_no_code "valid 0700/0600 state + full ledger -> no state miss" CONFIG_INVALID "$T"
assert_no_code "valid full-schema ledger -> LEDGER_CORRUPT absent" LEDGER_CORRUPT "$T"

# ===== 4. repo state dir not 0700 -> CONFIG_INVALID =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 755 600
assert_code "repo state dir 0755 -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 5. ledger file not 0600 -> CONFIG_INVALID =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 644
assert_code "ledger file 0644 -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 6. ledger.json is a symlink -> CONFIG_INVALID =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
rm -f "$feat/ledger.json"; printf '{"feature":"x"}' > "$T/real-ledger"; chmod 600 "$T/real-ledger"
ln -s "$T/real-ledger" "$feat/ledger.json"
assert_code "symlinked ledger.json -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 7. feature dir is a symlink -> CONFIG_INVALID (symlinked parent) =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"
rm -rf "$repodir/hello-cli"; mkdir -p "$T/real-feat"; chmod 700 "$T/real-feat"
ln -s "$T/real-feat" "$repodir/hello-cli"
assert_code "symlinked feature dir -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 8. ledger is valid JSON but schema-incomplete (empty object) -> LEDGER_CORRUPT =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
printf '{}' > "$feat/ledger.json"; chmod 600 "$feat/ledger.json"
assert_code "ledger {} (schema-incomplete) -> LEDGER_CORRUPT" LEDGER_CORRUPT "$T"

# ===== 9. ledger schema-incomplete: bad delivery value -> LEDGER_CORRUPT =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","command":"pipeline-impl","delivery":"bogus"}' > "$feat/ledger.json"
chmod 600 "$feat/ledger.json"
assert_code "ledger delivery=bogus -> LEDGER_CORRUPT" LEDGER_CORRUPT "$T"

# ===== 10. (finding 8) ledger missing the command NAME -> LEDGER_CORRUPT. The old
#      head accepted this (no command field in the schema). =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","delivery":"sent"}' > "$feat/ledger.json"
chmod 600 "$feat/ledger.json"
assert_code "ledger missing .command -> LEDGER_CORRUPT" LEDGER_CORRUPT "$T"

# ===== 11. (finding 8) ledger feature != directory name -> LEDGER_CORRUPT =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
printf '{"feature":"not-hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","command":"pipeline-impl","delivery":"sent"}' > "$feat/ledger.json"
chmod 600 "$feat/ledger.json"
assert_code "ledger feature != dir name -> LEDGER_CORRUPT" LEDGER_CORRUPT "$T"

# ===== 12. (finding 7) DANGLING symlink at STATE_DIR -> CONFIG_INVALID (not "absent").
#      The old head reported "state root not created yet" and exited 0. =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/dangle"; ln -s "$T/no-such-target" "$T/dangle"
assert_code "dangling STATE_DIR symlink -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 13. (finding 7) symlinked PARENT above the state root -> CONFIG_INVALID.
#      link-parent -> elsewhere; STATE_DIR=$T/link-parent/state. The state root itself
#      is a real 0700 dir (so the old head's root mode/type checks pass); only the NEW
#      parent-chain check catches the symlinked parent. Old head reported it valid. =====
fresh; seed_clones "$T"; mkdir -p "$T/elsewhere"; chmod 700 "$T/elsewhere"; ln -s "$T/elsewhere" "$T/link-parent"
write_cfg "$T" "$T/link-parent/state"; mkdir -p "$T/link-parent/state"; chmod 700 "$T/link-parent/state"
assert_code "symlinked parent of state root -> CONFIG_INVALID" CONFIG_INVALID "$T"

# run_doctor_bounded <root> <budget_s>: doctor under a HARD external deadline —
# used only by the cases whose OLD-head behavior was an unbounded hang (a test
# that hangs proves nothing). Kills the whole process group at the deadline and
# exits 124.
run_doctor_bounded() {
  perl -e '
    my $s = shift; my @c = @ARGV;
    my $p = fork(); die "fork: $!" unless defined $p;
    if (!$p) { setpgrp(0,0); exec @c or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $s; waitpid $p, 0; my $rc = $? >> 8; alarm 0;
    kill "KILL", -$p; exit $rc;
  ' "$2" env PATH=/usr/bin:/bin bash "$COORD" doctor --config "$1/cfg" 2>&1
}

# ===== 14. (round-3 F3) a mode-0600 FIFO named ledger.json must be REFUSED as
#      non-regular BEFORE anything opens it. The old head reported "file 0600" and
#      then hung forever in jq (no writer); bounded here so the old head FAILS with
#      rc=124 instead of hanging the suite. =====
fresh; seed_clones "$T"; write_cfg "$T" "$T/state"; mkstate "$T" 700 600
repodir="$T/state/$(state_dir_of "$T")"; feat="$repodir/hello-cli"
rm -f "$feat/ledger.json"; mkfifo "$feat/ledger.json"; chmod 600 "$feat/ledger.json"
out=$(run_doctor_bounded "$T" 12); rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && printf '%s' "$out" | grep -q 'not a regular file'; then
  ok "FIFO ledger.json -> refused as non-regular, never read (no hang)"
else
  bad "FIFO ledger.json" "rc=$rc (124 = doctor hung until the external deadline); $(printf '%s' "$out" | grep -iE 'ledger|regular|0600' | head -3)"
fi

# ===== 15. (round-3 F2) symlinked PARENT with the state root NOT created yet must
#      still BLOCK — the first write would land through the forbidden parent. The
#      old head early-returned "state root not created yet" before the parent walk. =====
fresh; seed_clones "$T"; mkdir -p "$T/elsewhere"; chmod 700 "$T/elsewhere"; ln -s "$T/elsewhere" "$T/link-parent"
write_cfg "$T" "$T/link-parent/state"   # state NOT created
assert_code "symlinked parent + absent state root -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 16. (round-4 F5) NOTHING behind a rejected state root is ever read: with
#      STATE_DIR a symlink to an external 0700 tree holding a valid-looking ledger,
#      the old head emitted the root-symlink CONFIG_INVALID and then kept walking,
#      printing 'ledger.json … file 0600' and 'ledger.json valid' from behind the
#      rejected root. =====
fresh; seed_clones "$T"
write_cfg "$T" "$T/extlink"
rk=$(state_dir_of "$T")            # key BEFORE the symlink exists (root absent = fine)
mkdir -p "$T/ext/$rk/hello-cli"; chmod 700 "$T/ext" "$T/ext/$rk" "$T/ext/$rk/hello-cli"
printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","command":"pipeline-impl","delivery":"sent"}' > "$T/ext/$rk/hello-cli/ledger.json"
chmod 600 "$T/ext/$rk/hello-cli/ledger.json"
ln -s "$T/ext" "$T/extlink"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && ! printf '%s' "$out" | grep -q 'ledger.json valid' \
   && ! printf '%s' "$out" | grep -Eq 'ledger\.json.*file 0600'; then
  ok "rejected state root -> traversal STOPS (nothing behind it read or reported ok)"
else
  bad "traversal after rejected root" "rc=$rc; $(printf '%s' "$out" | grep -iE 'ledger|state root' | head -5)"
fi

# ===== 17. (round-4 F6) STATE_DIR beneath a REGULAR FILE can never be created —
#      'not created yet' would be a lie. The old head's parent walk checked only -L. =====
fresh; seed_clones "$T"; printf 'x' > "$T/regfile"
write_cfg "$T" "$T/regfile/state"
assert_code "state root under a regular file -> CONFIG_INVALID" CONFIG_INVALID "$T"

# ===== 18. (round-5 F2) a REJECTED PARENT stops the state section even when the
#      root ITSELF is a real 0700 directory (reached through the symlinked parent)
#      holding a valid-looking ledger. The old head emitted the parent MISS, then
#      'state root exists' + 'ledger.json … file 0600' + 'ledger.json valid' from
#      behind the forbidden parent. =====
fresh; seed_clones "$T"
write_cfg "$T" "$T/linkp/state"
rk=$(state_dir_of "$T")            # key BEFORE the tree exists (root absent = fine)
mkdir -p "$T/real"; chmod 700 "$T/real"
ln -s "$T/real" "$T/linkp"
mkdir -p "$T/linkp/state/$rk/hello-cli"   # real dirs, created THROUGH the symlink
chmod 700 "$T/real/state" "$T/real/state/$rk" "$T/real/state/$rk/hello-cli"
printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","command":"pipeline-impl","delivery":"sent"}' > "$T/real/state/$rk/hello-cli/ledger.json"
chmod 600 "$T/real/state/$rk/hello-cli/ledger.json"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]' \
   && ! printf '%s' "$out" | grep -q 'state root exists' \
   && ! printf '%s' "$out" | grep -q 'ledger.json valid' \
   && ! printf '%s' "$out" | grep -Eq 'ledger\.json.*file 0600'; then
  ok "rejected parent + real root beneath it -> state section STOPS (nothing read)"
else
  bad "traversal after rejected parent" "rc=$rc; $(printf '%s' "$out" | grep -iE 'parent|state root|ledger' | head -5)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
