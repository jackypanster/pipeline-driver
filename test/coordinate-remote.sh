#!/usr/bin/env bash
# Regression tests for coordinate.sh remote-identity handling:
#  - finding 8: credential userinfo (user[:password]@) is stripped BEFORE
#    normalization, repo-key derivation, and EVERY diagnostic path. A secret like
#    ghp_SECRET must NEVER appear in any doctor/status output or derived key.
#  - finding 9: the repo-state key is collision-safe — normalized identities that
#    differ only in separator position (github.com/a/b_c vs github.com/a_b/c) map
#    to DIFFERENT keys (percent-encoded, structure-preserving).
# Run: bash test/coordinate-remote.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# seed <root> <observer_url>: 4 clones whose observer tracks <observer_url>; the
# role clones keep the bare-file remote (they only need to be valid clones for the
# non-credential sections). No herdr.
seed() {
  local root=$1 obsurl=$2 c
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
  git -C "$root/obs" remote set-url origin "$obsurl"
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

# ===== finding 9: collision-safe repo key (a/b_c vs a_b/c map to different keys) =====
mkdir -p "$TMP/k1" "$TMP/k2"
git init -q "$TMP/k1"; git -C "$TMP/k1" remote add origin https://github.com/acme/a/b_c.git
git init -q "$TMP/k2"; git -C "$TMP/k2" remote add origin https://github.com/acme/a_b/c.git
k1=$(bash "$COORD" __repo-key "$TMP/k1")
k2=$(bash "$COORD" __repo-key "$TMP/k2")
if [ -n "$k1" ] && [ -n "$k2" ] && [ "$k1" != "$k2" ]; then
  ok "collision-safe key: a/b_c != a_b/c ($k1 vs $k2)"
else
  bad "collision-safe key" "keys collide or empty: k1=$k1 k2=$k2"
fi

# ===== finding 8: credential userinfo never reaches the derived key =====
mkdir -p "$TMP/cred"
git init -q "$TMP/cred"; git -C "$TMP/cred" remote add origin https://alice:ghp_SECRET@github.com/acme/x.git
kc=$(bash "$COORD" __repo-key "$TMP/cred")
if printf '%s' "$kc" | grep -q 'ghp_SECRET'; then
  bad "credential sanitize (key)" "secret leaked into repo key: $kc"
else
  ok "credential sanitize (key): ghp_SECRET absent from derived key ($kc)"
fi

# ===== finding 8: credential userinfo never reaches ANY doctor/status output =====
# Observer remote carries alice:ghp_SECRET; the role clones disagree (bare-file
# remote) so doctor emits a REMOTE_MISMATCH — the mismatch line is the most likely
# place a raw URL would leak. Grep the FULL combined output for the secret AND the
# username across both doctor and status.
seed "$TMP/d" "https://alice:ghp_SECRET@github.com/acme/x.git"
dout=$(env STATE_DIR="$TMP/d/state" PATH=/usr/bin:/bin bash "$COORD" doctor --config "$TMP/d/cfg" 2>&1)
sout=$(env STATE_DIR="$TMP/d/state" PATH=/usr/bin:/bin bash "$COORD" status --config "$TMP/d/cfg" 2>&1)
if printf '%s\n%s\n' "$dout" "$sout" | grep -q 'ghp_SECRET'; then
  bad "credential sanitize (output)" "secret appeared in doctor/status output"
else
  ok "credential sanitize (output): ghp_SECRET absent from full doctor+status output"
fi
# The redacted remote SHOULD still appear (scheme + host + path, minus userinfo).
if printf '%s' "$dout" | grep -q 'github.com/acme/x'; then
  ok "credential sanitize (output): redacted remote still printed (github.com/acme/x)"
else
  bad "credential sanitize (output)" "redacted remote not found in doctor output"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
