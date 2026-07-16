#!/usr/bin/env bash
# Hermetic tests for `coordinate.sh status` (design §12): read-only local state
# summary. Must print ONE concise human line + ONE jq-valid JSON object, never
# touch the network or mutate state, and work sanely when the state dir does not
# exist yet (idle / uninitialized). LEDGER_CORRUPT is the one fail-fast reachable
# here. Run: bash test/coordinate-status.sh
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

# seed <root>: 4 clones of one bare remote + current.json (so status can derive
# the repo key + discover the feature locally via `git show HEAD:`). No herdr.
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
POLL_SECS=30
PANE_READY_TIMEOUT_MS=60000
STAGE_TIMEOUT_SECS=2700
EOF
}

# run_status: reads $T (set by fresh/seed); writes human+JSON to stdout. stderr is
# left flowing (coord_die for CONFIG_INVALID writes there).
run_status() {
  env STATE_DIR="$T/state" PATH=/usr/bin:/bin bash "$COORD" status --config "$T/cfg"
}

# ===== 1. no state dir at all -> idle + valid JSON (jq . round-trip) =====
fresh; seed "$T"
out=$(run_status); rc=$?
human=$(printf '%s' "$out" | sed -n '1p')
jsonv=$(printf '%s' "$out" | sed -n '2p')
if [ "$rc" -eq 0 ] \
   && printf '%s' "$human" | grep -q 'idle' \
   && printf '%s' "$jsonv" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$out" | sed -n '3p')" = "" ]; then   # exactly ONE human line + ONE JSON line
  ok "no state dir -> idle + one jq-valid JSON object"
else
  bad "no state dir" "rc=$rc; human=$human; json=$jsonv; line3=[$(printf '%s' "$out" | sed -n '3p')]"; fi

# ===== 2. ledger present -> 'observed' carries last-observed seq/commit/delivery =====
fresh; seed "$T"
rkey=$(bash "$COORD" __repo-key "$T/obs")
featdir="$T/state/$rkey/hello-cli"
mkdir -p "$featdir"; chmod 700 "$featdir"
cat > "$featdir/ledger.json" <<EOF
{"feature":"hello-cli","journal_seq":7,"journal_commit":"abcdef1234567890abcdef1234567890abcdef12","target_role":"PI","delivery":"sent"}
EOF
out=$(run_status); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | sed -n '1p' | grep -q 'feature=hello-cli' \
   && printf '%s' "$out" | sed -n '1p' | grep -q 'seq=7' \
   && printf '%s' "$out" | sed -n '2p' | jq -e '.state == "observed" and .last_observed.journal_seq == "7" and .last_observed.delivery == "sent"' >/dev/null 2>&1; then
  ok "ledger present -> observed + last-observed seq/commit"
else
  bad "ledger present" "rc=$rc; out=$(printf '%s' "$out" | head -2)"; fi

# ===== 3. unresolved halt.json -> state=halted, code surfaced in the JSON =====
fresh; seed "$T"
rkey=$(bash "$COORD" __repo-key "$T/obs")
featdir="$T/state/$rkey/hello-cli"; mkdir -p "$featdir"; chmod 700 "$featdir"
printf '{"code":"REMOTE_MISMATCH","where":"watch"}' > "$featdir/halt.json"
out=$(run_status); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | sed -n '2p' | jq -e '.state == "halted" and .halt == "REMOTE_MISMATCH"' >/dev/null 2>&1; then
  ok "halt.json present -> state=halted + code surfaced"
else
  bad "halt.json present" "rc=$rc; out=$(printf '%s' "$out" | head -2)"; fi

# ===== 4. corrupt ledger.json -> LEDGER_CORRUPT, non-zero, valid JSON error object =====
fresh; seed "$T"
rkey=$(bash "$COORD" __repo-key "$T/obs")
featdir="$T/state/$rkey/hello-cli"; mkdir -p "$featdir"; chmod 700 "$featdir"
printf 'this is not { json' > "$featdir/ledger.json"
out=$(run_status); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q 'LEDGER_CORRUPT' \
   && printf '%s' "$out" | sed -n '2p' | jq -e '.error_code == "LEDGER_CORRUPT"' >/dev/null 2>&1; then
  ok "corrupt ledger -> LEDGER_CORRUPT (rc!=0) + valid JSON error object"
else
  bad "corrupt ledger" "rc=$rc; out=$(printf '%s' "$out" | head -2)"; fi

# ===== 5. invalid config -> CONFIG_INVALID (coord_die), non-zero =====
fresh; seed "$T"
sed -i.bak 's#^BRANCH=.*##' "$T/cfg"; rm -f "$T/cfg.bak"   # BRANCH unset
out=$(run_status 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'CONFIG_INVALID'; then
  ok "invalid config -> CONFIG_INVALID (status validates before reading state)"
else
  bad "invalid config" "rc=$rc; out=$(printf '%s' "$out" | head -8)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
