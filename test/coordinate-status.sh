#!/usr/bin/env bash
# Hermetic tests for `coordinate.sh status` (design §12): read-only summary. Must
# print EXACTLY ONE human line + ONE jq-valid JSON object ({"feature":<slug|null>})
# to stdout, with the machine-bindings block on stderr, and never touch the network
# or mutate state. CONFIG_INVALID is the one fail-fast reachable here. Run: bash
# test/coordinate-status.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export DRIVE_DEFAULTS="$TMP/.absent-drive-defaults"   # hermetic: never read the operator's real file
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; }

# seed <root>: 4 clones of one bare remote + current.json (so status can discover
# the feature via `git show HEAD:.pipeline/current.json`). No herdr.
seed() {
  local root=$1 c
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
  ( cd "$root/obs"; git checkout -q -b main
    mkdir -p .pipeline
    printf '{"feature":"hello-cli","stage":"impl"}' > .pipeline/current.json
    git add -A && git commit -qm seed && git push -q origin main )
  cat > "$root/cfg" <<EOF
OBSERVER_WORKDIR=$root/obs
BRANCH=main
CC_WORKDIR=$root/cc
PI_WORKDIR=$root/pi
CODEX_WORKDIR=$root/codex
CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='\$pipeline-review'
EOF
}

# run_status: reads $T (set by fresh/seed); writes human+JSON to stdout. stderr is
# left flowing (coord_die for CONFIG_INVALID writes there).
run_status() {
  PATH=/usr/bin:/bin bash "$COORD" status --config "$T/cfg"
}

# ===== 1. seeded feature -> EXACT human line + EXACT JSON, exactly 2 stdout records =====
# stdout contract is pinned by RECORD COUNT (wc -l on the file — a $(...) capture
# eats trailing newlines, so "exactly two lines" was unverifiable) and EXACT line
# strings (sed on the file — a grep substring would accept extra human text).
# stderr is captured to a separate file.
fresh; seed "$T"
run_status >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" -eq 0 ] \
   && [ "$(wc -l < "$T/out")" -eq 2 ] \
   && [ "$(sed -n 1p "$T/out")" = 'coordinate: feature=hello-cli (from HEAD current.json)' ] \
   && [ "$(sed -n 2p "$T/out")" = '{"feature":"hello-cli"}' ]; then
  ok "seeded feature -> exact human line + exact JSON, two stdout records"
else
  bad "seeded feature" "rc=$rc; lines=$(wc -l < "$T/out"); L1=[$(sed -n 1p "$T/out")]; L2=[$(sed -n 2p "$T/out")]"
fi

# ===== 1b. idle: no current.json on HEAD -> EXACT idle line + EXACT null JSON =====
fresh; seed "$T"
( cd "$T/obs"; git rm -q .pipeline/current.json && git commit -qm idle && git push -q origin main )
run_status >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" -eq 0 ] \
   && [ "$(wc -l < "$T/out")" -eq 2 ] \
   && [ "$(sed -n 1p "$T/out")" = 'coordinate: idle (no active feature)' ] \
   && [ "$(sed -n 2p "$T/out")" = '{"feature":null}' ]; then
  ok "no current.json -> exact idle line + exact {\"feature\":null}, two stdout records"
else
  bad "idle (no current.json)" "rc=$rc; lines=$(wc -l < "$T/out"); L1=[$(sed -n 1p "$T/out")]; L2=[$(sed -n 2p "$T/out")]"
fi

# ===== 5. invalid config -> ZERO stdout lines; CONFIG_INVALID on stderr only =====
fresh; seed "$T"
sed -i.bak 's#^BRANCH=.*##' "$T/cfg"; rm -f "$T/cfg.bak"   # BRANCH unset
run_status >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" -ne 0 ] \
   && [ "$(wc -l < "$T/out")" -eq 0 ] \
   && grep -q 'CONFIG_INVALID' "$T/err"; then
  ok "invalid config -> zero stdout lines + CONFIG_INVALID on stderr"
else
  bad "invalid config" "rc=$rc; stdout_lines=$(wc -l < "$T/out"); err=$(grep -i config_invalid "$T/err" | head -1)"
fi

# ===== 7. (finding 10) status decodes the SAME tab tuple validate_config writes —
#      a config violation surfaces a CLEAN code/input/reason via coord_die on STDERR
#      (stdout stays empty), not the raw tab record, and never the dead guard field. =====
fresh; seed "$T"
sed -i.bak 's#^CC_ARCH_CMD=.*#CC_ARCH_CMD=#' "$T/cfg"; rm -f "$T/cfg.bak"
run_status >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" -ne 0 ] \
   && [ "$(wc -l < "$T/out")" -eq 0 ] \
   && grep -Eq '^code: +CONFIG_INVALID *$' "$T/err" \
   && grep -q '^input:.*CC_ARCH_CMD' "$T/err" \
   && grep -q '^reason:.*is unset' "$T/err" \
   && ! grep -q $'\t' "$T/err" \
   && ! grep -q 'resume[_]guard' "$T/err"; then
  ok "status decodes the tab tuple (clean code/input/reason on stderr, no raw-record or guard-field leakage)"
else
  bad "status tab decode" "rc=$rc; stdout_lines=$(wc -l < "$T/out"); err: $(grep -E '^code:|^input:|^reason:' "$T/err" | head -3)"
fi

# ===== 6. (finding 11) malicious feature slug from current.json must NOT traverse.
#      The slug is read from HEAD's current.json and echoed in output / used in a
#      git-show path; '../..' is rejected with ZERO stdout lines + CONFIG_INVALID on
#      stderr, and the forged slug is never printed. =====
fresh; seed "$T"
( cd "$T/obs"
  printf '{"feature":"../../etc","stage":"impl"}' > .pipeline/current.json
  git commit -aqm badfeat && git push -q origin main )
run_status >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" -ne 0 ] \
   && [ "$(wc -l < "$T/out")" -eq 0 ] \
   && grep -q 'CONFIG_INVALID' "$T/err" \
   && ! grep -q 'etc/passwd' "$T/err"; then
  ok "malicious feature slug -> zero stdout + CONFIG_INVALID on stderr (no traversal)"
else
  bad "malicious feature slug" "rc=$rc; stdout_lines=$(wc -l < "$T/out"); err=$(grep -iE 'config_invalid|etc/passwd' "$T/err" | head -3)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
