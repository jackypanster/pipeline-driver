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

# ===== 1. seeded feature -> human feature=... + JSON .feature, exactly 2 lines =====
fresh; seed "$T"
out=$(run_status); rc=$?
human=$(printf '%s' "$out" | sed -n '1p')
jsonv=$(printf '%s' "$out" | sed -n '2p')
if [ "$rc" -eq 0 ] \
   && printf '%s' "$human" | grep -q 'feature=hello-cli' \
   && printf '%s' "$jsonv" | jq -e '.feature == "hello-cli"' >/dev/null 2>&1 \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ]; then   # exactly ONE human line + ONE JSON line
  ok "seeded feature -> feature=hello-cli + one jq-valid JSON object (.feature set)"
else
  bad "seeded feature" "rc=$rc; human=$human; json=$jsonv; line3=[$(printf '%s' "$out" | sed -n '3p')]"; fi

# ===== 1b. idle: no current.json on HEAD -> human 'idle' + JSON .feature null =====
fresh; seed "$T"
( cd "$T/obs"; git rm -q .pipeline/current.json && git commit -qm idle && git push -q origin main )
out=$(run_status); rc=$?
human=$(printf '%s' "$out" | sed -n '1p')
jsonv=$(printf '%s' "$out" | sed -n '2p')
if [ "$rc" -eq 0 ] \
   && printf '%s' "$human" | grep -q 'idle' \
   && printf '%s' "$jsonv" | jq -e '.feature == null' >/dev/null 2>&1 \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ]; then
  ok "no current.json -> idle + JSON .feature null (exactly two stdout lines)"
else
  bad "idle (no current.json)" "rc=$rc; human=$human; json=$jsonv; line3=[$(printf '%s' "$out" | sed -n '3p')]"; fi

# ===== 5. invalid config -> CONFIG_INVALID (coord_die), non-zero =====
fresh; seed "$T"
sed -i.bak 's#^BRANCH=.*##' "$T/cfg"; rm -f "$T/cfg.bak"   # BRANCH unset
out=$(run_status 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'CONFIG_INVALID'; then
  ok "invalid config -> CONFIG_INVALID (status validates before reading state)"
else
  bad "invalid config" "rc=$rc; out=$(printf '%s' "$out" | head -8)"; fi

# ===== 7. (finding 10) status decodes the SAME tab tuple validate_config writes —
#      a config violation surfaces a CLEAN code/input/reason via coord_die, not the
#      raw tab record, and never the dead dispatch guard field. =====
fresh; seed "$T"
sed -i.bak 's#^CC_ARCH_CMD=.*#CC_ARCH_CMD=#' "$T/cfg"; rm -f "$T/cfg.bak"
out=$(run_status 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -Eq '^code: +CONFIG_INVALID *$' \
   && printf '%s' "$out" | grep -q '^input:.*CC_ARCH_CMD' \
   && printf '%s' "$out" | grep -q '^reason:.*is unset' \
   && ! printf '%s' "$out" | grep -q $'\t' \
   && ! printf '%s' "$out" | grep -q 'resume[_]guard'; then
  ok "status decodes the tab tuple (clean code/input/reason, no raw-record or guard-field leakage)"
else
  bad "status tab decode" "rc=$rc; out=$(printf '%s' "$out" | head -6)"; fi

# ===== 6. (finding 11) malicious feature slug from current.json must NOT traverse.
#      The feature is read from HEAD's current.json and echoed in output / used in
#      a git-show path; a slug like '../..' must be rejected with CONFIG_INVALID
#      instead of traversal or injection. =====
fresh; seed "$T"
( cd "$T/obs"
  printf '{"feature":"../../etc","stage":"impl"}' > .pipeline/current.json
  git commit -aqm badfeat && git push -q origin main )
out=$(run_status 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q 'CONFIG_INVALID' \
   && ! printf '%s' "$out" | grep -q 'etc/passwd'; then
  ok "malicious feature slug -> CONFIG_INVALID (no traversal)"
else
  bad "malicious feature slug" "rc=$rc; expected CONFIG_INVALID + no traversal; out=$(printf '%s' "$out" | head -8)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
