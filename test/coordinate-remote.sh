#!/usr/bin/env bash
# Regression tests for findings 5 + 6: remote-identity handling, all via the
# shipped `doctor` CLI (no internal hooks).
#   - finding 5: credential userinfo is stripped even when the password contains
#     URI sub-delims (! $ & ' ( ) * + , ; =) — the old whitelist-class sanitizer
#     leaked it. Assert NO fragment of the secret reaches any doctor output/key.
#   - finding 6: ssh://host:PORT/path and https://host/PORT/path derive DIFFERENT
#     identities (the old scp-colon rule conflated the port with a path segment).
# Run: bash test/coordinate-remote.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
COORD="$HERE/../coordinate.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
TMP=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$(mktemp -d)"); trap 'rm -rf "$TMP"' EXIT
export DRIVE_DEFAULTS="$TMP/.absent-drive-defaults"   # hermetic: never read the operator's real file
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
  # Proxy state is FULLY isolated (finding: inherited HTTPS_PROXY/https_proxy take
  # precedence over ALL_PROXY, and NO_PROXY can bypass it): both cases of every
  # scheme proxy are forced to the refused local port and no-proxy lists cleared,
  # so no inherited environment can route a fetch to a real network.
  env PATH=/usr/bin:/bin \
      GIT_SSH_COMMAND=/usr/bin/false GIT_ASKPASS=/usr/bin/false GIT_TERMINAL_PROMPT=0 \
      ALL_PROXY=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1 \
      HTTP_PROXY=http://127.0.0.1:1 http_proxy=http://127.0.0.1:1 \
      HTTPS_PROXY=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 \
      NO_PROXY= no_proxy= \
      bash "$COORD" doctor --config "$1/cfg" 2>&1
}

# ===== finding 5: a password containing the '!' sub-delim must NOT leak. The old
#      whitelist sanitizer ([A-Za-z0-9._~%+-]) stopped at '!' and kept the secret. =====
fresh; seed "$T"
set_all_origins "$T" "https://alice!:ghp_SECRET@github.com/acme/x.git"
out=$(run_doctor "$T")
# doctor MUST have run remote-identity normalization over the credential URL
# (config valid) while keeping the secret and username out of EVERY line.
if printf '%s' "$out" | grep -q 'config valid' \
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
  bad "relative filesystem remote" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -4)"
fi

# ===== round-3 F4 (positive): the SAME absolute filesystem remote in all four
#      clones agrees, and the key is the resolved physical path (injective). =====
fresh; seed "$T"
set_all_origins "$T" "$T/origin.git"
out=$(run_doctor "$T")
if ! printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "same absolute filesystem remote x4 -> remote-identity agreement (no mismatch)"
else
  bad "absolute filesystem remote agreement" "$(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -4)"
fi

# ===== round-3 F5: query/fragment credentials never reach a key or diagnostic.
#      The old head kept ?token=… in the percent-encoded key (repo_key=…%3Ftoken%3D…). =====
fresh; seed "$T"
set_all_origins "$T" "https://github.com/acme/x.git?token=ghp_QUERYSECRET"
out=$(run_doctor "$T")
if printf '%s' "$out" | grep -q 'config valid' \
   && ! printf '%s' "$out" | grep -iq 'ghp_querysecret' \
   && ! printf '%s' "$out" | grep -iq 'token='; then
  ok "query-string token stripped (no ghp_QUERYSECRET, no token= in any output)"
else
  bad "query/fragment credential" "leaked: $(printf '%s' "$out" | grep -iE 'ghp_querysecret|token=' | head -3)"
fi

# ===== round-4 F1: 'x@../shared' is a LITERAL LOCAL PATH — no colon, and a host
#      can't start with '.' — so classification must precede userinfo stripping.
#      The old head stripped 'x@' first, turned four different per-clone targets
#      into ONE ../shared, and accepted a shared key. =====
fresh; seed "$T"
set_all_origins "$T" "x@../shared"
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "x@../shared classified as per-clone local path -> REMOTE_MISMATCH"
else
  bad "userinfo-lookalike local path" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -3)"
fi

# ===== round-4 F2: filesystem vs network identities are DISJOINT namespaces. On
#      the old head a local /…/shared and https://file/…/shared.git both produced
#      the string file/…/shared and were accepted as one remote. =====
fresh; seed "$T"; mkdir -p "$T/shared"
git -C "$T/obs" remote set-url origin "$T/shared"
for c in cc pi codex; do git -C "$T/$c" remote set-url origin "https://file$T/shared.git"; done
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "local path vs https://file…/… -> REMOTE_MISMATCH (typed namespaces disjoint)"
else
  bad "cross-kind namespace collision" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -3)"
fi

# ===== round-4 F3: '#' (and '?') are legal FILENAME bytes in local paths — the old
#      head stripped '#secret' pre-classification and accepted /…/one#secret and
#      /…/one as the same repository. =====
fresh; seed "$T"
git -C "$T/obs" remote set-url origin "$T/one#secret"
for c in cc pi codex; do git -C "$T/$c" remote set-url origin "$T/one"; done
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "local one#secret vs one -> REMOTE_MISMATCH (no ?#-strip on filesystem paths)"
else
  bad "filesystem #-byte path" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -3)"
fi

# ===== round-4 F4: two DISTINCT nonexistent top-level paths must not collapse into
#      one identity. The old head's resolve_path returned '/' when nothing below /
#      existed, keying both as file%2F. =====
fresh; seed "$T"
git -C "$T/obs" remote set-url origin "/codex-pr13-a-$$/repo.git"
for c in cc pi codex; do git -C "$T/$c" remote set-url origin "/codex-pr13-b-$$/repo.git"; done
out=$(run_doctor "$T"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '\[REMOTE_MISMATCH\]'; then
  ok "distinct nonexistent top-level paths -> REMOTE_MISMATCH (suffix preserved past /)"
else
  bad "nonexistent top-level resolution" "expected REMOTE_MISMATCH; rc=$rc; $(printf '%s' "$out" | grep -iE 'remote|mismatch' | head -3)"
fi

# ===== round-5 F1: the typed identity is LOCALE-INVARIANT. Bash \${#v} counted
#      characters under UTF-8 but bytes under C, so https://example.com/é.git keyed
#      net:13: vs net:14: across shells. The typed identity is internal to remote
#      agreement, so the property is observed through the REMOTE_MISMATCH
#      diagnostic: observer on the é remote, the other three on a different remote,
#      surfaces observer(net:N:…) — and N MUST be byte-identical across locales.
#      Skip-counted when no UTF-8 locale exists. =====
fresh; seed "$T"
git -C "$T/obs" remote set-url origin "https://example.com/é.git"
for c in cc pi codex; do git -C "$T/$c" remote set-url origin "https://example.com/other.git"; done
if locale -a 2>/dev/null | grep -qi '^en_US.UTF-8$'; then
  line_c=$(LC_ALL=C        run_doctor "$T" | grep '!= observer (net:' | head -1)
  line_u=$(LC_ALL=en_US.UTF-8 run_doctor "$T" | grep '!= observer (net:' | head -1)
  if [ -n "$line_c" ] && [ "$line_c" = "$line_u" ]; then
    ok "non-ASCII identity locale-invariant ($line_c)"
  else
    bad "locale-variant identity" "LC_ALL=C: ${line_c:-<none>} vs en_US.UTF-8: ${line_u:-<none>}"
  fi
else
  ok "non-ASCII identity locale-invariance (SKIP: no en_US.UTF-8 locale on this machine)"
fi

# ===== round-5 F3: F7 (proxy isolation) is a HARNESS-ONLY correction — swapping
#      only production code cannot demonstrate it, so instead of a fake old-head
#      regression it carries a LIVE PROPERTY TEST: a hostile inherited HTTPS_PROXY
#      pointing at a local sentinel must NEVER receive a connection through
#      run_doctor's isolated env (it would, if the env overrides were weakened). =====
fresh; seed "$T"
set_all_origins "$T" "https://example.com/sentinel-check/x.git"
rm -f "$T/port" "$T/marker"
perl -e '
  use IO::Socket::INET;
  my ($portf, $markf) = @ARGV;
  alarm 25;
  my $s = IO::Socket::INET->new(Listen=>5, LocalAddr=>"127.0.0.1", LocalPort=>0) or die "listen: $!";
  open my $F, ">", $portf or die; print $F $s->sockport; close $F;
  my $c = $s->accept();
  open my $M, ">", $markf or die; print $M "CONNECTED"; close $M;
' "$T/port" "$T/marker" &
SENTINEL_PID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.3; done
SPORT=$(cat "$T/port" 2>/dev/null || echo "")
if [ -z "$SPORT" ]; then
  bad "proxy sentinel" "sentinel listener failed to start"
else
  out=$(HTTPS_PROXY="http://127.0.0.1:$SPORT" https_proxy="http://127.0.0.1:$SPORT" \
        NO_PROXY="" no_proxy="" run_doctor "$T")
  sleep 0.5
  if [ ! -e "$T/marker" ]; then
    ok "hostile inherited HTTPS_PROXY neutralized (sentinel never received a connection)"
  else
    bad "proxy isolation property" "the sentinel received a connection — run_doctor leaked the inherited proxy"
  fi
fi
kill "$SENTINEL_PID" 2>/dev/null || true; wait "$SENTINEL_PID" 2>/dev/null || true

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
