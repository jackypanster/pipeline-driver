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
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
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

# state_root_of <root>: the repo-key state dir path, via the same key coordinate.sh
# derives (no drift).
state_dir_of() { bash "$COORD" __repo-key "$1/obs"; }

# mkstate <root> <mode_dirs> <mode_files>: create a 0700/0600 state tree for the
# repo with one feature carrying a full-schema ledger. Modes overridable per case.
mkstate() {
  local root=$1 dmode=$2 fmode=$3 repodir feat
  repodir="$root/state/$(state_dir_of "$root")"
  feat="$repodir/hello-cli"
  mkdir -p "$feat"; chmod "$dmode" "$root/state" "$repodir" "$feat"
  printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","delivery":"sent"}' > "$feat/ledger.json"
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
printf '{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","pane":"wB:p1","delivery":"bogus"}' > "$feat/ledger.json"
chmod 600 "$feat/ledger.json"
assert_code "ledger delivery=bogus -> LEDGER_CORRUPT" LEDGER_CORRUPT "$T"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
