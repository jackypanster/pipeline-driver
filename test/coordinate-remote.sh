#!/usr/bin/env bash
# Regression tests for findings 5 + 6: remote-identity handling, all via the
# shipped `doctor` CLI (no internal hooks).
#   - finding 5: credential userinfo is stripped even when the password contains
#     URI sub-delims (! $ & ' ( ) * + , ; =) — the old whitelist-class sanitizer
#     leaked it. Assert NO fragment of the secret reaches any doctor output/key.
#   - finding 6: ssh://host:PORT/path and https://host/PORT/path derive DIFFERENT
#     keys (the old scp-colon rule conflated the port with a path segment); and a
#     remote that normalizes to a '.'/'..' segment is refused.
# Run: bash test/coordinate-remote.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; }

# seed <root>: bare remote + 4 clones + a valid baseline cfg (panes not stubbed —
# a herdr MISS is harmless; we assert on remote/key lines).
seed() {
  local root=$1 c
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
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
# set_all_origins <root> <url>: point all four clones at <url>.
set_all_origins() { local c; for c in obs cc pi codex; do git -C "$1/$c" remote set-url origin "$2"; done; }
# run_doctor is HERMETIC (finding: the suite must never touch the network even
# though doctor reaches `git fetch`): ssh is forced to fail instantly
# (GIT_SSH_COMMAND=/usr/bin/false) and http(s) is routed into a closed local port
# (ALL_PROXY -> 127.0.0.1:1, connection refused), with prompts disabled — the
# identity strings under test are preserved verbatim while every fetch fails fast
# as GIT_FETCH_FAILED, which the assertions below do not depend on.
run_doctor() {
  env PATH=/usr/bin:/bin \
      GIT_SSH_COMMAND=/usr/bin/false GIT_ASKPASS=/usr/bin/false GIT_TERMINAL_PROMPT=0 \
      ALL_PROXY=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1 \
      bash "$COORD" doctor --config "$1/cfg" 2>&1
}

# ===== finding 5: a password containing the '!' sub-delim must NOT leak. The old
#      whitelist sanitizer ([A-Za-z0-9._~%+-]) stopped at '!' and kept the secret. =====
fresh; seed "$T"
set_all_origins "$T" "https://alice!:ghp_SECRET@github.com/acme/x.git"
out=$(run_doctor "$T")
# the host MUST be preserved in the key line; the secret and username MUST NOT
# appear ANYWHERE (case-insensitive — the key lowercases the path).
if printf '%s' "$out" | grep -q 'github.com' \
   && ! printf '%s' "$out" | grep -iq 'ghp_secret' \
   && ! printf '%s' "$out" | grep -q 'alice!'; then
  ok "credential with '!' sub-delim stripped (no ghp_SECRET, no alice! in output)"
else
  bad "credential sanitize (!)" "secret leaked: $(printf '%s' "$out" | grep -iE 'ghp_secret|alice!' | head -3)"
fi

# ===== finding 6: ssh://host:2222/path vs https://host/2222/path are DISTINCT —
#      the old scp-colon rule turned the ssh port into a path and they collided,
#      so distinct remotes passed remote agreement. Set observer+cc+pi to the ssh
#      form and codex to the https form; the new head sees REMOTE_MISMATCH. =====
fresh; seed "$T"
SSH="ssh://git@example.com:2222/team/repo.git"
HTTPS="https://example.com/2222/team/repo.git"
git -C "$T/obs" remote set-url origin "$SSH"
git -C "$T/cc"  remote set-url origin "$SSH"
git -C "$T/pi"  remote set-url origin "$SSH"
git -C "$T/codex" remote set-url origin "$HTTPS"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "ssh :port vs https /port -> REMOTE_MISMATCH (port/path no longer collide)"
else
  bad "port/path collision" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -4)"
fi

# ===== finding 6 (surface moved by the round-3 filesystem canonicalization): a
#      NETWORK remote whose path carries a '..' segment is still REFUSED (the key
#      would escape the state root). Relative FILESYSTEM forms like '..' are now
#      legitimately canonicalized per-clone (see the relative-remote case below) —
#      resolution eliminates dot-segments, so no escape key can exist on that path. =====
fresh; seed "$T"
set_all_origins "$T" "https://example.com/../escape.git"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[CONFIG_INVALID\]'; then
  ok "network remote with '..' segment -> CONFIG_INVALID (no escape key)"
else
  bad "remote dot-segment" "expected CONFIG_INVALID; rc=$rc; $(printf '%s' "$out" | grep -iE 'repo key|config_invalid|normalized' | head -4)"
fi

# ===== round-3 F4: RELATIVE filesystem remotes resolve PER CLONE. Four clones each
#      declaring remote.origin.url=origin.git name four DIFFERENT local repos —
#      identities must mismatch. The old head normalized all four to the bare
#      string 'origin' and accepted them sharing one key. =====
fresh; seed "$T"
set_all_origins "$T" "origin.git"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "relative origin.git per clone -> REMOTE_MISMATCH (resolved per-clone, no shared key)"
else
  bad "relative filesystem remote" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch|repo key' | head -4)"
fi

# ===== round-3 F4 (positive): the SAME absolute filesystem remote in all four
#      clones agrees, and the key is the resolved physical path (injective). =====
fresh; seed "$T"
set_all_origins "$T" "$T/origin.git"
out=$(run_doctor "$T")
if ! printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]' \
   && printf '%s' "$out" | grep -q 'normalized repo key: file%2F'; then
  ok "same absolute filesystem remote x4 -> agreement + resolved-path key"
else
  bad "absolute filesystem remote agreement" "$(printf '%s' "$out" | grep -iE 'remote|mismatch|repo key' | head -4)"
fi

# ===== round-3 F5: query/fragment credentials never reach a key or diagnostic.
#      The old head kept ?token=… in the percent-encoded key (repo_key=…%3Ftoken%3D…). =====
fresh; seed "$T"
set_all_origins "$T" "https://github.com/acme/x.git?token=ghp_QUERYSECRET"
out=$(run_doctor "$T")
if printf '%s' "$out" | grep -q 'github.com' \
   && ! printf '%s' "$out" | grep -iq 'ghp_querysecret' \
   && ! printf '%s' "$out" | grep -iq 'token='; then
  ok "query-string token stripped (no ghp_QUERYSECRET, no token= in any output)"
else
  bad "query/fragment credential" "leaked: $(printf '%s' "$out" | grep -iE 'ghp_querysecret|token=' | head -3)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
