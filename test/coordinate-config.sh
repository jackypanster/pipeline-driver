#!/usr/bin/env bash
# Hermetic tests for coordinate.sh config validation (design §11). Each §11 rule
# is broken one at a time and the matching §14 code must surface in `doctor`
# output (drive.sh d_miss shape) with a non-zero exit. The valid baseline prints
# "config valid" and NONE of the config codes. Panes/remote are intentionally not
# stubbed here — the config section is what is under test, and a pane MISS is fine.
# Run: bash test/coordinate-config.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Per-test subdirs so one test's clone mutation can't bleed into another (git
# clone refuses an existing non-empty dir). NB: incremented in the MAIN shell —
# a `fresh()` helper called via $(...) would run in a subshell and never advance.
N=0
fresh() { N=$((N+1)); T="$TMP/t$N"; }

# seed_clones <root>: 4 real clones of one bare remote (so workdir/remote rules pass).
seed_clones() {
  local root=$1 c
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
}

# write_cfg <root>: a valid §11 baseline config.
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
EOF
}

# run_doctor <root>: doctor output on stdout+stderr, restricted PATH (no herdr).
run_doctor() {
  STATE_DIR="$1/state" PATH=/usr/bin:/bin bash "$COORD" doctor --config "$1/cfg" 2>&1
}

# assert_cfg_ok <label> <root>: valid -> "config valid" and zero config codes.
assert_cfg_ok() {
  local label=$1 root=$2 out
  out=$(run_doctor "$root")
  if printf '%s' "$out" | grep -q 'config valid' \
     && ! printf '%s' "$out" | grep -Eq 'CONFIG_INVALID|WORKDIR_INVALID|REMOTE_MISMATCH'; then
    ok "$label"
  else
    bad "$label" "expected 'config valid' + no config codes; got: $(printf '%s' "$out" | sed -n '/--- config/,/---/p' | head -20)"
  fi
}

# assert_code <label> <code> <root>: doctor MUST carry [code] and exit non-zero.
assert_code() {
  local label=$1 code=$2 root=$3 out rc
  out=$(run_doctor "$root"); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "\[$code\]"; then
    ok "$label"
  else
    bad "$label" "expected rc!=0 and [$code]; rc=$rc; output: $(printf '%s' "$out" | grep -E '\[' | head -8)"
  fi
}

# ===== baseline (every §11 rule satisfied) =====
fresh; seed_clones "$T"; write_cfg "$T"
assert_cfg_ok "valid config (all §11 rules pass)" "$T"

# ===== 1. workdir not absolute =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^OBSERVER_WORKDIR=.*#OBSERVER_WORKDIR=relative/obs#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "OBSERVER_WORKDIR not absolute" WORKDIR_INVALID "$T"

# ===== 2. workdir does not exist =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^CC_WORKDIR=.*#CC_WORKDIR='"$T"'/no-such#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "CC_WORKDIR does not exist" WORKDIR_INVALID "$T"

# ===== 3. workdir not a git clone =====
fresh; seed_clones "$T"; write_cfg "$T"
mkdir -p "$T/notgit"; sed -i.bak 's#^PI_WORKDIR=.*#PI_WORKDIR='"$T"'/notgit#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "PI_WORKDIR not a git clone" WORKDIR_INVALID "$T"

# ===== 4. remote mismatch (one clone tracks a different origin) =====
fresh; seed_clones "$T"; write_cfg "$T"
git init -q --bare "$T/other.git"
git -C "$T/codex" remote set-url origin "$T/other.git"
assert_code "CODEX clone remote != observer" REMOTE_MISMATCH "$T"

# ===== 5. BRANCH unset (delete the line) =====
fresh; seed_clones "$T"; write_cfg "$T"
grep -v '^BRANCH=' "$T/cfg" > "$T/cfg.new" && mv "$T/cfg.new" "$T/cfg"
assert_code "BRANCH unset" CONFIG_INVALID "$T"

# ===== 6. command prefix empty =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^CC_ARCH_CMD=.*#CC_ARCH_CMD=#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "CC_ARCH_CMD empty" CONFIG_INVALID "$T"

# ===== 7. command prefix spans multiple lines (quoted string w/ embedded newline) =====
fresh; seed_clones "$T"; write_cfg "$T"
{ grep -v '^CC_TASK_CMD=' "$T/cfg"; printf 'CC_TASK_CMD="/pipeline-task\nextra"\n'; } > "$T/cfg.new" && mv "$T/cfg.new" "$T/cfg"
assert_code "CC_TASK_CMD multi-line value" CONFIG_INVALID "$T"

# ===== 8. pane ID spans multiple lines =====
fresh; seed_clones "$T"; write_cfg "$T"
printf 'CC_PANE_ID="wA:p1\nsecond"\n' >> "$T/cfg"
assert_code "CC_PANE_ID multi-line value" CONFIG_INVALID "$T"

# ===== 9a. timeout not a positive integer =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^POLL_SECS=.*#POLL_SECS=not-a-num#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "POLL_SECS not numeric" CONFIG_INVALID "$T"

# ===== 9b. timeout zero (not positive) =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^PANE_READY_TIMEOUT_MS=.*#PANE_READY_TIMEOUT_MS=0#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "PANE_READY_TIMEOUT_MS=0 (not positive)" CONFIG_INVALID "$T"

# ===== 9c. timeout over documented upper bound =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^STAGE_TIMEOUT_SECS=.*#STAGE_TIMEOUT_SECS=999999#' "$T/cfg"; rm -f "$T/cfg.bak"
assert_code "STAGE_TIMEOUT_SECS over upper bound" CONFIG_INVALID "$T"

# ===== 10a. ON_HALT_EXEC is a symlink (rejected even if the target is executable) =====
fresh; seed_clones "$T"; write_cfg "$T"
printf '#!/bin/sh\nexit 0\n' > "$T/realhook"; chmod +x "$T/realhook"
ln -s "$T/realhook" "$T/hooklink"
printf 'ON_HALT_EXEC=%s\n' "$T/hooklink" >> "$T/cfg"
assert_code "ON_HALT_EXEC is a symlink" CONFIG_INVALID "$T"

# ===== 10b. ON_HALT_EXEC not executable =====
fresh; seed_clones "$T"; write_cfg "$T"
printf '#!/bin/sh\nexit 0\n' > "$T/noex"; chmod 644 "$T/noex"
printf 'ON_HALT_EXEC=%s\n' "$T/noex" >> "$T/cfg"
assert_code "ON_HALT_EXEC not executable" CONFIG_INVALID "$T"

# ===== 10c. ON_HALT_EXEC not absolute =====
fresh; seed_clones "$T"; write_cfg "$T"
printf 'ON_HALT_EXEC=./relative-hook\n' >> "$T/cfg"
assert_code "ON_HALT_EXEC not absolute" CONFIG_INVALID "$T"

# ===== 10d. ON_HALT_EXEC valid regular executable file -> passes =====
fresh; seed_clones "$T"; write_cfg "$T"
printf '#!/bin/sh\nexit 0\n' > "$T/goodhook"; chmod +x "$T/goodhook"
printf 'ON_HALT_EXEC=%s\n' "$T/goodhook" >> "$T/cfg"
assert_cfg_ok "ON_HALT_EXEC valid regular executable" "$T"

# ===== 11a. STATE_DIR inside a clone (must be outside every clone) =====
fresh; seed_clones "$T"; write_cfg "$T"
printf 'STATE_DIR=%s/cc/state\n' "$T" >> "$T/cfg"
assert_code "STATE_DIR inside CC clone" CONFIG_INVALID "$T"

# ===== 11b. STATE_DIR outside clones -> passes =====
fresh; seed_clones "$T"; write_cfg "$T"
printf 'STATE_DIR=%s/state\n' "$T" >> "$T/cfg"
assert_cfg_ok "STATE_DIR outside clones" "$T"

# ===== (finding 10) every doctor miss carries the FULL §14 tuple: where / input /
#      next_action (resume_guard where meaningful), not just [CODE] + prose. =====
fresh; seed_clones "$T"; write_cfg "$T"
sed -i.bak 's#^POLL_SECS=.*#POLL_SECS=not-a-num#' "$T/cfg"; rm -f "$T/cfg.bak"
tuple_out=$(run_doctor "$T")
if printf '%s' "$tuple_out" | grep -q '\[CONFIG_INVALID\] POLL_SECS not a positive integer' \
   && printf '%s' "$tuple_out" | grep -q 'where: doctor:config' \
   && printf '%s' "$tuple_out" | grep -q 'input: POLL_SECS' \
   && printf '%s' "$tuple_out" | grep -q 'next_action: edit'; then
  ok "§14 tuple present (where/input/next_action) on a config miss"
else
  bad "§14 tuple" "missing tuple fields; got: $(printf '%s' "$tuple_out" | grep -A1 CONFIG_INVALID | head -4)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
