#!/usr/bin/env bash
# coordinate.sh — the deterministic cross-stage coordinator for the `pipeline`
# toolchain (coordinator-design.md v1.1).
#
# WHAT IT IS: an OPTIONAL, opt-in watcher that advances one coordinated feature
# across Claude Code (CC), Pi, and Codex by typing the next stage command into
# the correct long-lived Herdr pane. It holds ZERO authoritative state — the
# target repo's .pipeline/<feature>/journal.md on the remote is the single
# source of truth. It is the cross-stage sibling of drive.sh (which owns the
# impl card loop): coordinate.sh routes between stages and delegates an impl
# span to drive.sh rather than duplicating its card loop.
#
# THIS PHASE ships ONLY the read-only surface: `doctor` (full preflight) and
# `status` (local state summary). `watch` and `resume` exist as stubs that fail
# non-zero so a caller can never confuse them for working dispatch.
#
# INVARIANTS (design §11 / §19): every config value is validated before use; a
# configured command prefix is DATA appended to a safely-constructed argv, never
# `eval`'d; target Git is read-only (fetch + `git show`, never a checked-out
# worktree); local state writes reject symlinks and use restrictive modes; the
# coordinator excludes its OWN pane and proves lifecycle authority per pane.
#
# Usage:
#   coordinate.sh doctor --config <path>
#   coordinate.sh status --config <path>
#   coordinate.sh watch  --config <path>     # not implemented this phase
#   coordinate.sh resume --config <path> --reason <text>   # not implemented this phase
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/parse-tail.awk"

# The coordinator may itself run inside a Herdr pane (HERDR_PANE_ID injected into
# every managed pane). Capture it as "the pane running coordinate.sh" so pane
# resolution can EXCLUDE it and reject a pinned self — then drop it before
# sourcing config, exactly as drive.sh does. A driver launched inside a role
# worktree would otherwise match its own cwd and type into itself.
COORD_SELF_PANE="${HERDR_PANE_ID:-}"
unset HERDR_PANE_ID 2>/dev/null || true

# ---- knobs ----------------------------------------------------------------------
# Bounded timeout for a single `herdr agent explain` read in doctor (a wedged
# daemon must not hang preflight). Coarse but adequate: doctor is not latency-
# sensitive, and an empty sample fails closed as non-authoritative.
AUTH_TIMEOUT_MS="${COORD_AUTH_TIMEOUT_MS:-5000}"
# Bounded timeout for `herdr pane list` — wholly unbounded by default, a wedged
# Herdr daemon would hang the whole pane section. Same watchdog as agent explain.
PANE_LIST_TIMEOUT_MS="${COORD_PANE_LIST_TIMEOUT_MS:-5000}"
# Documented upper bounds for the configured timeouts (design §11).
: ${POLL_SECS_MAX:=3600}
: ${PANE_READY_TIMEOUT_MS_MAX:=600000}
: ${STAGE_TIMEOUT_SECS_MAX:=86400}

# ---- error model (design §14; drive.sh's where/input/reason/next_action) --------
# coord_die <code> <where> <input> <reason> <next_action>  — hard abort, exit 1.
coord_die() {
  printf '\n=== COORDINATOR FATAL ===\n'        >&2
  printf 'code:        %s\n' "$1"                >&2
  printf 'where:       %s\n' "$2"                >&2
  printf 'input:       %s\n' "$3"                >&2
  printf 'reason:      %s\n' "$4"                >&2
  printf 'next_action: %s\n' "$5"                >&2
  printf 'resume_guard: fix the above, then `coordinate.sh doctor --config <cfg>`; resume never bypasses it.\n' >&2
  exit 1
}
note() { printf '%s\n' "$*" >&2; }

# ---- remote-identity normalization (design §11/§13/§19) ------------------------
# strip_userinfo <url>: remove the URL userinfo component (everything up to and
# including the LAST '@') from the AUTHORITY section — greedy and character-class-
# FREE, so a password containing URI sub-delims (! $ & ' ( ) * + , ; =) or . _ ~ % -
# can never survive into a normalized identity, key, or diagnostic. Works for any
# scheme AND the scheme-less scp-like user@host:path form. (findings: credential
# sanitize + port/path collision.)
strip_userinfo() {
  printf '%s' "$1" | perl -ne '
    chomp;
    s/[?#].*$//;                 # query/fragment can carry ?token=… — NEVER kept in a
                                 # key or diagnostic (§14/§19; finding: query/fragment
                                 # credentials). Stripped on the WHOLE value so a
                                 # no-path authority (https://host?token=x) is covered.
    my ($s, $rest) = m{^([a-zA-Z][a-zA-Z0-9+.\-]*://)(.*)$} ? ($1,$2) : ("",$_);
    my ($auth, $tail) = $rest =~ m{^([^/]*)(.*)$} ? ($1,$2) : ($rest,"");
    $auth =~ s/^.*\@//;          # drop userinfo through the terminal @
    print "$s$auth$tail\n";
  '
}

# _remote_kind <url> — classify the RAW value BEFORE any stripping (finding:
# classification must precede sanitization — stripping user@ first turned the
# literal local path 'x@../shared' into '../shared'). Echoes net-scheme / net-scp
# / fs. A scheme-less value is scp-like ONLY on the FULL grammar
#   [user@]host:path   (user: no '/' or '@'; host: [A-Za-z0-9][A-Za-z0-9._-]*)
# — anything else (including values containing '@' or '?' or '#', all legal
# filename bytes) is a filesystem path. file:// names a local path.
_remote_kind() {
  case "$1" in
    file://*) printf 'fs'; return 0 ;;
    *://*)    printf 'net-scheme'; return 0 ;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -Eq '^([^/@]+@)?[A-Za-z0-9][A-Za-z0-9._-]*:'; then
    printf 'net-scp'
  else
    printf 'fs'
  fi
}

# redact_remote <url>: safe-to-print form. NETWORK forms are stripped of userinfo
# and query/fragment so https://alice:ghp_SECRET@host/... can never reach
# stderr/stdout or a derived key (§14 sanitized-input / §19). FILESYSTEM paths are
# printed as-is: they are local paths, not credential carriers, and '@'/'?'/'#'
# are legal filename bytes there (finding: no ?#/userinfo stripping on paths).
redact_remote() {
  case "$(_remote_kind "$1")" in
    fs) printf '%s' "$1" ;;
    *)  strip_userinfo "$1" ;;
  esac
}

# normalize_remote_for <workdir> <url>: ONE canonical identity per REAL remote, in
# DISJOINT TYPED NAMESPACES (finding: a bare 'file' prefix collided with a literal
# hostname 'file' — https://file/…/shared.git aliased a local /…/shared):
#   network:    net:<len>:<host[:port]/path>   userinfo + query/fragment + .git
#               stripped, host lowercased. https/ssh/scp forms of one remote agree;
#               an ssh:// port host:2222 stays distinct from a /2222 path segment.
#   filesystem: fs:<len>:<physical path>       the value is preserved EXACTLY (no
#               userinfo/query/fragment/.git stripping — '@', '?', '#' are legal
#               filename bytes; /srv/x and /srv/x.git are different repos) and
#               resolved against the DECLARING clone: `origin.git` in four clones
#               names four different repositories.
# <len> is the value's BYTE length, computed locale-invariantly (finding: Bash
# ${#v} counts characters under a UTF-8 locale but bytes under LC_ALL=C, so the
# SAME remote keyed net:13: vs net:14: across shells and moved to a different
# state namespace). The kind tag is chosen by classification, never taken from
# input. Classification runs on the RAW value BEFORE any stripping (finding:
# 'x@../shared' is a literal local path, not userinfo).
_byte_len() { printf '%s' "$1" | wc -c | awk '{print $1}'; }   # wc -c = bytes, always
normalize_remote_for() {
  local wd=$1 raw=$2 kind u v
  kind=$(_remote_kind "$raw")
  case "$kind" in
    fs)
      v=$raw
      case "$v" in file://*) v=${v#file://} ;; esac
      case "$v" in /*) ;; *) v="$wd/$v" ;; esac
      v=$(resolve_path "$v")
      printf 'fs:%d:%s' "$(_byte_len "$v")" "$v"
      ;;
    net-scheme)
      u=$(strip_userinfo "$raw"); u=${u#*://}; u=${u%.git}
      v=$(printf '%s' "$u" | awk -F/ 'BEGIN{OFS="/"} { $1=tolower($1); print }')
      printf 'net:%d:%s' "$(_byte_len "$v")" "$v"
      ;;
    net-scp)
      u=$(strip_userinfo "$raw")
      u=$(printf '%s' "$u" | sed -E 's#([^/]*):#\1/#')   # scp host:path -> host/path
      u=${u%.git}
      v=$(printf '%s' "$u" | awk -F/ 'BEGIN{OFS="/"} { $1=tolower($1); print }')
      printf 'net:%d:%s' "$(_byte_len "$v")" "$v"
      ;;
  esac
}

# identity_has_dotseg <identity>: 0 (true) if it is empty or contains a '.'/'..'
# segment — such identities are REJECTED because the repo key would escape the
# state root (e.g. remote ".." -> repodir $root/..).
identity_has_dotseg() {
  printf '%s' "$1" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="."||$i==".."){f=1}} END{exit f?0:1}'
}

# repo_key_from <workdir> — single-segment, COLLISION-SAFE key from origin.url.
# The normalized identity is percent-encoded (jq @uri) so structural separators
# survive injectively (host:port vs host/path, a/b_c vs a_b/c). Identities with '.'
# or '..' segments are rejected (empty output, return 1).
repo_key_from() {
  local url norm
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || url=""
  [ -n "$url" ] || return 1
  norm=$(normalize_remote_for "$1" "$url")
  identity_has_dotseg "$norm" && return 1
  printf '%s' "$norm" | jq -rR '@uri'
}

state_root() {
  if [ -n "${STATE_DIR:-}" ]; then printf '%s' "$STATE_DIR"
  else printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/pipeline-driver"; fi
}

# resolve_path <path> — absolute, symlink-resolved (PHYSICAL). Resolves the longest
# EXISTING ancestor via perl Cwd::abs_path and re-appends the not-yet-created tail,
# so a STATE_DIR that does not exist yet still resolves to its intended physical
# location. Used for containment (§13/§19) and distinct-workdir checks so lexical
# tricks ("..", symlinks INTO a clone) cannot bypass physical isolation.
resolve_path() {
  local p=$1 base dir
  case "$p" in "") printf '%s' ""; return 0 ;; /*) ;; *) p="$PWD/$p" ;; esac
  base=$p
  while [ "$base" != "/" ] && [ ! -e "$base" ]; do base=$(dirname "$base"); done
  if [ "$base" = "/" ]; then
    # Nothing below / exists and / itself is never a symlink: the path IS its own
    # physical form — return it WHOLE. Truncating to '/' collapsed every distinct
    # nonexistent top-level path into one identity/key (finding: preserve the
    # unresolved suffix when / is the longest existing ancestor).
    printf '%s' "$p"; return 0
  fi
  dir=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$base" 2>/dev/null) || dir=""
  [ -n "$dir" ] || dir=$base
  if [ "$base" = "$p" ]; then printf '%s' "$dir"
  else printf '%s/%s' "$dir" "${p#"$base"/}"; fi
}

# cwd_in_workdir <cwd> <workdir> — 0 if cwd == workdir OR a descendant of it.
cwd_in_workdir() {
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

is_pos_int() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}

# valid_feature_slug <slug> — 0 iff <slug> is safe to use as a SINGLE path
# component under the repo state dir. Rejects empty, '.', '..', any '/', leading
# '-', newline/tab/CR (grep is line-based, so an embedded newline would otherwise
# let a forged second line pass the allowlist), and anything outside
# [A-Za-z0-9._-] — so a malicious feature read from HEAD's current.json (or a
# tampered state subdir) can never traverse or inject forged output. (finding: slug.)
valid_feature_slug() {
  local s=$1
  [ -n "$s" ] || return 1
  case "$s" in -*|*/*|*".."*|*$'\n'*|*$'\t'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$s" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# ---- bounded exec (perl; base-system on macOS/Linux; no `timeout` on macOS) -----
# bounded_run_ms <ms> <cmd...> — stdout passes through; exit 124 on timeout, else
# the leader's rc. The child runs in its OWN process group (perl setpgrp+exec); the
# deadline is enforced at sub-second resolution via Time::HiRes::ualarm (a bare
# `alarm` rounds 100ms up to 1s). Two failure modes are handled, both by killing
# the WHOLE process group:
#  (a) TIMEOUT — at the deadline the group is KILL'd and the leader reaped (exit 124).
#  (b) EARLY LEADER EXIT — if the leader forks a descendant that still holds the
#      stdout pipe and then exits, waitpid returns the leader but the caller's $(...)
#      would block on the descendant (an immortal child hangs forever; the reviewer
#      measured 2.04s for a 100ms budget). So on normal exit we KILL the group too,
#      then drain it: the command substitution can NEVER outlive the deadline.
# (drive.sh run_with_timeout_ms documents the same process-group kill discipline;
# reimplemented here, never sourced.)
bounded_run_ms() {
  local ms=$1; shift
  # NEVER launch with a non-positive/invalid budget: ualarm(0) DISABLES the
  # deadline, so a blocking leader would hang forever (finding: invalid budget
  # still used after being reported). rc 125 = refused-to-run; every caller
  # already treats a nonzero rc / empty output as failure.
  is_pos_int "$ms" || return 125
  perl -e '
    use POSIX ":sys_wait_h";
    use Time::HiRes qw(ualarm);
    my $ms = shift; my @cmd = @ARGV;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) { setpgrp(0,0); exec @cmd or exit 127; }
    my $armed = 1;
    # drain_group: KILL every member of the child group, then wait briefly until
    # the group is empty so any descendant holding stdout has released the pipe.
    my $drain = sub {
      kill("KILL", -$pid);
      for (1..80) { last unless kill(0, -$pid); select(undef,undef,undef,0.025); }
    };
    $SIG{ALRM} = sub {
      return unless $armed;
      $drain->();                 # KILL the whole group on the deadline
      waitpid($pid, 0);           # reap the leader (already KILLed above)
      exit 124;
    };
    ualarm(int($ms * 1000));
    waitpid($pid, 0);
    my $rc = $? >> 8;
    my $sig = $? & 127;
    $armed = 0; ualarm(0);        # disarm: the leader exited of its own accord
    $drain->();                   # but a descendant may still hold stdout
    # Propagate a signal death as 128+signal (nonzero) — a child that printed
    # plausible output and then crashed (e.g. self-SIGTERM) MUST NOT report rc=0,
    # or a caller could authorize off truncated output ($? >> 8 alone yields 0).
    exit($sig ? 128 + $sig : $rc);
  ' -- "$ms" "$@"
}

# authority_of <pane> <timeout_ms> — echoes "1" (authoritative) / "0" (not, incl.
# unreadable). The SAME single `herdr agent explain` read yields both the state
# and the authority flag (drive.sh herdr_agent_sample pattern, reimplemented here
# for multi-role use; never sourced from drive.sh). Authoritative = a lifecycle
# hook OR a MATCHED manifest rule, with NO always-idle fallback in effect.
authority_of() {
  local pane=$1 ms=$2 json
  json=$(bounded_run_ms "$ms" herdr agent explain "$pane" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf '0'; return 0; }
  printf '%s' "$json" | jq -r \
    'if (((.screen_detection_skip_reason == "full_lifecycle_hook_authority") or (.matched_rule != null))
         and (.fallback_reason == null)) then "1" else "0" end' 2>/dev/null || printf '0'
}

# ---- config validation (design §11) --------------------------------------------
# Appends "CODE<TAB>input<TAB>reason" lines to CFG_V[] and sets CFG_BAD=1 on any
# violation. Runs EVERY check (does not short-circuit) so doctor can report the
# full list. (finding: §14 tuple — input carries the offending var/value.)
CFG_V=(); CFG_BAD=0
cfg_violation() { CFG_V+=("$1"$'\t'"$2"$'\t'"$3"); CFG_BAD=1; }   # <code> <input> <reason>

validate_config() {
  CFG_V=(); CFG_BAD=0
  local wdvar wd url norm ok_abs
  # 1. workdirs: absolute, existing git clones.
  for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    wd="${!wdvar:-}"
    if [ -z "$wd" ]; then cfg_violation CONFIG_INVALID "$wdvar" "$wdvar is unset"; continue; fi
    case "$wd" in /*) ;; *) cfg_violation WORKDIR_INVALID "$wdvar" "$wdvar not absolute: $wd"; continue ;; esac
    if [ ! -d "$wd" ]; then cfg_violation WORKDIR_INVALID "$wdvar" "$wdvar does not exist: $wd"; continue; fi
    if ! git -C "$wd" rev-parse --git-dir >/dev/null 2>&1; then
      cfg_violation WORKDIR_INVALID "$wdvar" "$wdvar is not a git clone: $wd"; continue; fi
  done
  # 1b. workdirs must be PHYSICALLY distinct (realpath pairwise unique) — two roles
  # sharing one clone, or aliased via ".."/symlink, erodes reviewer/implementer
  # isolation before dispatch exists (design §§2/5/11; finding: distinct workdirs).
  local rp_obs rp_cc rp_pi rp_cx
  rp_obs=$(resolve_path "${OBSERVER_WORKDIR:-}"); rp_cc=$(resolve_path "${CC_WORKDIR:-}")
  rp_pi=$(resolve_path "${PI_WORKDIR:-}");     rp_cx=$(resolve_path "${CODEX_WORKDIR:-}")
  _cfg_distinct() { if [ -n "$3" ] && [ -n "$4" ] && [ "$3" = "$4" ]; then cfg_violation WORKDIR_INVALID "$1/$2" "$1 and $2 resolve to the same physical clone ($3)"; fi; }
  _cfg_distinct OBSERVER CC    "$rp_obs" "$rp_cc"
  _cfg_distinct OBSERVER PI    "$rp_obs" "$rp_pi"
  _cfg_distinct OBSERVER CODEX "$rp_obs" "$rp_cx"
  _cfg_distinct CC      PI     "$rp_cc"  "$rp_pi"
  _cfg_distinct CC      CODEX  "$rp_cc"  "$rp_cx"
  _cfg_distinct PI      CODEX  "$rp_pi"  "$rp_cx"
  unset -f _cfg_distinct
  # 1c. workdirs must be INDEPENDENT clones, not just distinct paths — each must be
  # its own repo TOP-LEVEL (catches subdirs of one clone) and the four must share NO
  # git common-dir (catches subdirs AND worktrees of one clone). (finding: independent
  # clones.) The realpath check above is fooled by four subdirs of one clone.
  # Initialize EVERY slot before the loop: an unusable workdir `continue`s past its
  # assignment, and the later direct expansions would abort under Bash 4/5 `set -u`
  # ("unbound variable") instead of reporting the accumulated §14 violations.
  # (finding: uninitialized git-common-dir slots.)
  local _tl="" _rpwd="" _cd_obs="" _cd_cc="" _cd_pi="" _cd_cx=""
  _common_dir_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
  for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    wd="${!wdvar:-}"
    [ -d "$wd" ] && git -C "$wd" rev-parse --git-dir >/dev/null 2>&1 || continue
    _tl=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null || echo "")
    _rpwd=$(resolve_path "$wd")
    if [ -n "$_tl" ] && [ -n "$_rpwd" ] && [ "$(resolve_path "$_tl")" != "$_rpwd" ]; then
      cfg_violation WORKDIR_INVALID "$wdvar" "$wdvar ($wd) is not its own repo top-level (git toplevel: $_tl) — subdir of another clone/worktree is not an independent clone"
    fi
    case "$wdvar" in
      OBSERVER_WORKDIR) _cd_obs=$(_common_dir_of "$wd") ;;
      CC_WORKDIR)       _cd_cc=$(_common_dir_of "$wd") ;;
      PI_WORKDIR)       _cd_pi=$(_common_dir_of "$wd") ;;
      CODEX_WORKDIR)    _cd_cx=$(_common_dir_of "$wd") ;;
    esac
  done
  _cd_distinct() { if [ -n "$3" ] && [ -n "$4" ] && [ "$3" = "$4" ]; then cfg_violation WORKDIR_INVALID "$1/$2" "$1 and $2 share the same git common-dir ($3) — not independent clones (subdirs or worktrees of one clone)"; fi; }
  _cd_distinct OBSERVER CC    "$_cd_obs" "$_cd_cc"
  _cd_distinct OBSERVER PI    "$_cd_obs" "$_cd_pi"
  _cd_distinct OBSERVER CODEX "$_cd_obs" "$_cd_cx"
  _cd_distinct CC      PI     "$_cd_cc"  "$_cd_pi"
  _cd_distinct CC      CODEX  "$_cd_cc"  "$_cd_cx"
  _cd_distinct PI      CODEX  "$_cd_pi"  "$_cd_cx"
  unset -f _cd_distinct _common_dir_of
  # 2. remote-identity agreement across all four clones that resolved above.
  norm=""; ok_abs=1
  for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    wd="${!wdvar:-}"
    case "$wd" in /*) ;; *) ok_abs=0 ;; esac
    [ -d "$wd" ] || ok_abs=0
    git -C "$wd" rev-parse --git-dir >/dev/null 2>&1 || ok_abs=0
    if [ "$ok_abs" = "1" ]; then
      url=$(git -C "$wd" config --get remote.origin.url 2>/dev/null) || url=""
      if [ -z "$url" ]; then cfg_violation WORKDIR_INVALID "$wdvar" "$wdvar has no remote.origin.url"
      elif [ -z "$norm" ]; then
        norm=$(normalize_remote_for "$wd" "$url")
        # reject identities with '.'/'..' segments — the repo key would escape the
        # state root (e.g. remote ".." -> repodir $root/..). (finding: dot-segment key)
        if identity_has_dotseg "$norm"; then
          cfg_violation CONFIG_INVALID "$wdvar" "$wdvar normalizes to an identity with a '.'/'..' segment ($norm) — refused as a repo-state key"
          norm=""
        fi
      elif [ "$(normalize_remote_for "$wd" "$url")" != "$norm" ]; then
        cfg_violation REMOTE_MISMATCH "$wdvar" "$wdvar remote ($(redact_remote "$url")) != observer ($norm)"
      fi
    fi
  done
  # 3. BRANCH non-empty.
  [ -n "${BRANCH:-}" ] || cfg_violation CONFIG_INVALID "BRANCH" "BRANCH is unset"
  # 4. command prefixes: non-empty, single-line (no embedded newline).
  local cmdvar
  for cmdvar in CC_ARCH_CMD CC_TASK_CMD CC_HUNT_CMD PI_IMPL_CMD CODEX_REVIEW_CMD; do
    wd="${!cmdvar:-}"   # reuse varname slot for the VALUE
    if [ -z "$wd" ]; then cfg_violation CONFIG_INVALID "$cmdvar" "$cmdvar is unset"; continue; fi
    case "$wd" in *$'\n'*) cfg_violation CONFIG_INVALID "$cmdvar" "$cmdvar spans multiple lines" ;; esac
  done
  # 5. optional pane IDs: single-line opaque, non-empty (when set).
  for cmdvar in CC_PANE_ID PI_PANE_ID CODEX_PANE_ID; do
    wd="${!cmdvar:-}"
    [ -z "$wd" ] && continue
    case "$wd" in *$'\n'*) cfg_violation CONFIG_INVALID "$cmdvar" "$cmdvar spans multiple lines" ;; esac
  done
  # 6. timeouts: positive base-10 ints within documented upper bounds.
  if ! is_pos_int "${POLL_SECS:-0}"; then cfg_violation CONFIG_INVALID "POLL_SECS" "POLL_SECS not a positive integer"
  elif [ "${POLL_SECS:-0}" -gt "$POLL_SECS_MAX" ]; then cfg_violation CONFIG_INVALID "POLL_SECS" "POLL_SECS exceeds $POLL_SECS_MAX"; fi
  if ! is_pos_int "${PANE_READY_TIMEOUT_MS:-0}"; then cfg_violation CONFIG_INVALID "PANE_READY_TIMEOUT_MS" "PANE_READY_TIMEOUT_MS not a positive integer"
  elif [ "${PANE_READY_TIMEOUT_MS:-0}" -gt "$PANE_READY_TIMEOUT_MS_MAX" ]; then cfg_violation CONFIG_INVALID "PANE_READY_TIMEOUT_MS" "PANE_READY_TIMEOUT_MS exceeds $PANE_READY_TIMEOUT_MS_MAX"; fi
  if ! is_pos_int "${STAGE_TIMEOUT_SECS:-0}"; then cfg_violation CONFIG_INVALID "STAGE_TIMEOUT_SECS" "STAGE_TIMEOUT_SECS not a positive integer"
  elif [ "${STAGE_TIMEOUT_SECS:-0}" -gt "$STAGE_TIMEOUT_SECS_MAX" ]; then cfg_violation CONFIG_INVALID "STAGE_TIMEOUT_SECS" "STAGE_TIMEOUT_SECS exceeds $STAGE_TIMEOUT_SECS_MAX"; fi
  # 7. ON_HALT_EXEC (if set): absolute, executable, regular file, NOT a symlink.
  if [ -n "${ON_HALT_EXEC:-}" ]; then
    case "$ON_HALT_EXEC" in /*) ;; *) cfg_violation CONFIG_INVALID "ON_HALT_EXEC" "ON_HALT_EXEC not absolute: $ON_HALT_EXEC" ;;
    esac
    if [ -L "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC" "ON_HALT_EXEC is a symlink: $ON_HALT_EXEC"
    elif [ ! -f "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC" "ON_HALT_EXEC not a regular file: $ON_HALT_EXEC"
    elif [ ! -x "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC" "ON_HALT_EXEC not executable: $ON_HALT_EXEC"
    fi
  fi
  # 8. STATE_DIR (if set): OUTSIDE every configured clone — by PHYSICAL resolution
  # (realpath), not lexical prefix, so ".." and a symlink resolving INTO a clone
  # cannot bypass containment (§13/§19; finding: state containment).
  if [ -n "${STATE_DIR:-}" ]; then
    local rp_state rp_wd_s
    case "$STATE_DIR" in /*) ;; *) cfg_violation CONFIG_INVALID "STATE_DIR" "STATE_DIR not absolute: $STATE_DIR" ;; esac
    rp_state=$(resolve_path "$STATE_DIR")
    for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
      wd="${!wdvar:-}"
      [ -d "$wd" ] || continue
      rp_wd_s=$(resolve_path "$wd")
      case "$rp_state" in
        "$rp_wd_s"|"$rp_wd_s"/*) cfg_violation CONFIG_INVALID "STATE_DIR" "STATE_DIR ($STATE_DIR -> $rp_state) resolves inside $wdvar ($wd -> $rp_wd_s)" ;;
      esac
    done
  fi
  return $CFG_BAD
}

# ---- pane resolution (design §5/§10) -------------------------------------------
# resolve_role_pane <role> <workdir> <pin> <panes_json> <self>
# Sets RES_PANE on success (returns 0). On failure returns 1 and sets
# RES_CODE/RES_MSG. Pinned ID overrides discovery but MUST resolve to the role
# clone; self excluded; zero/multiple/ambiguous is fatal. NB: communicates via
# GLOBALS (not stdout) so the caller avoids a $(...) subshell — a subshell would
# discard these globals and trip `set -u` on the failure branch.
resolve_role_pane() {
  local role=$1 workdir=$2 pin=$3 json=$4 self=$5
  RES_CODE=""; RES_MSG=""; RES_PANE=""
  local matched n pane cwd
  if [ -n "$pin" ]; then
    if [ -n "$self" ] && [ "$pin" = "$self" ]; then
      RES_CODE="PANE_SELF"; RES_MSG="$role pinned pane ($pin) == the pane running coordinate.sh"; return 1; fi
    matched=$(printf '%s' "$json" | jq --arg p "$pin" '[.result.panes[]? | select(.pane_id == $p)]' 2>/dev/null) || matched="[]"
    n=$(printf '%s' "$matched" | jq 'length' 2>/dev/null); n="${n:-0}"
    if [ "$n" != "1" ]; then
      RES_CODE="PANE_NOT_FOUND"; RES_MSG="$role pinned pane ($pin) not in herdr pane list"; return 1; fi
    pane=$(printf '%s' "$matched" | jq -r '.[0].pane_id')
    cwd=$(printf '%s' "$matched" | jq -r '.[0].cwd // ""')
    if ! cwd_in_workdir "$cwd" "$workdir"; then
      RES_CODE="PANE_UNAUTHORIZED"; RES_MSG="$role pinned pane ($pane) cwd ($cwd) is not under $workdir"; return 1; fi
    RES_PANE="$pane"; return 0
  fi
  # discovery: agent-bearing + cwd == workdir (or descendant) + exclude self; exactly one.
  matched=$(printf '%s' "$json" | jq --arg wd "$workdir" --arg self "$self" \
    '[.result.panes[]? | select((.agent // "") != "") | select(.pane_id != $self)
      | select((.cwd // "") == $wd or ((.cwd // "") | startswith($wd + "/")))]' 2>/dev/null) || matched="[]"
  n=$(printf '%s' "$matched" | jq 'length' 2>/dev/null); n="${n:-0}"
  case "$n" in
    1) RES_PANE=$(printf '%s' "$matched" | jq -r '.[0].pane_id'); return 0 ;;
    0) RES_CODE="PANE_NOT_FOUND"; RES_MSG="no agent-bearing pane for $role under $workdir (self pane excluded)"; return 1 ;;
    *) RES_CODE="PANE_AMBIGUOUS";   RES_MSG="$n panes match $role under $workdir — pin a ${role}_PANE_ID"; return 1 ;;
  esac
}

show_remote() {  # <path> — read from the observer's fetched origin/BRANCH (never a checkout)
  git -C "$OBSERVER_WORKDIR" show "origin/$BRANCH:$1" 2>/dev/null
}

stat_perms() {  # <path> — portable mode digits (macOS -f %Lp / Linux -c %a)
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# ---- doctor (read-only full preflight; design §12/§24.2) -----------------------
cmd_doctor() {
  local bad=0 warn=0
  d_ok()   { printf 'ok    %s\n' "$1"; }
  d_info() { printf 'info  %s\n' "$1"; }
  d_warn() { printf 'warn  %s\n      %s\n' "$1" "$2"; warn=$((warn+1)); }
  d_miss() { printf 'MISS  %s\n      fix: %s\n' "$1" "$2"; bad=$((bad+1)); }
  # d_code <CODE> <where> <input> <reason> <next_action> [resume_guard] — drive.sh
  # d_miss shape with the FULL §14 tuple, ALWAYS including resume_guard (the 6th
  # arg defaults to the standard "fix, then re-doctor; resume never bypasses it" so
  # every MISS carries all five named fields the fail-fast contract requires).
  # (finding: §14 tuple — complete + unconditional resume_guard.)
  d_code() {
    printf 'MISS  [%s] reason: %s
' "$1" "$4"
    printf '      where: %s | input: %s | next_action: %s | resume_guard: %s
' \
      "$2" "$3" "$5" "${6:-fix the above, then re-run \`coordinate.sh doctor --config <cfg>\`; resume never bypasses it}"
    bad=$((bad+1))
  }

  printf -- '--- deps ----------------------------------------------------------\n'
  if   command -v git   >/dev/null 2>&1; then d_ok "git on PATH"
  else d_code DEPENDENCY_MISSING "doctor:deps" "git" "git not on PATH" "install git (xcode-select --install / package manager)"; fi
  if   command -v jq    >/dev/null 2>&1; then d_ok "jq on PATH"
  else d_code DEPENDENCY_MISSING "doctor:deps" "jq" "jq not on PATH" "brew install jq"; fi
  if   command -v herdr >/dev/null 2>&1; then d_ok "herdr on PATH"
  else d_code DEPENDENCY_MISSING "doctor:deps" "herdr" "herdr not on PATH" "install Herdr (https://herdr.dev)"; fi
  if   command -v perl  >/dev/null 2>&1; then d_ok "perl on PATH (bounded exec + authority timeout)"
  else d_code DEPENDENCY_MISSING "doctor:deps" "perl" "perl not on PATH" "install perl (base system package on macOS/Linux)"; fi

  printf -- '--- config --------------------------------------------------------\n'
  validate_config || true
  if [ "${CFG_BAD:-0}" = "1" ]; then
    local v c ci cr
    for v in "${CFG_V[@]}"; do
      IFS=$'\t' read -r c ci cr <<< "$v"
      d_code "$c" "doctor:config" "$ci" "$cr" "edit $CONF (coordinate.config.example documents each rule)"
    done
  else
    d_ok "config valid ($CONF): workdirs/remote/branch/commands/timeouts all pass §11"
  fi
  # Runtime watchdog knobs (env): MUST be positive integers. ualarm(0) on a zero/
  # non-positive budget DISABLES the watchdog (finding: bounded knobs), so a wedged
  # Herdr daemon would hang preflight. Reject them up front AND skip every Herdr
  # read for the rest of this run — reporting the violation and then calling Herdr
  # with the same invalid budget would hang on a blocking leader (finding: invalid
  # budget still used; bounded_run_ms also self-guards as the backstop).
  local _k _v herdr_reads_ok=1
  for _k in AUTH_TIMEOUT_MS PANE_LIST_TIMEOUT_MS; do
    _v="${!_k:-}"
    if ! is_pos_int "$_v"; then
      d_code CONFIG_INVALID "doctor:config" "$_k=$_v" "$_k is not a positive integer (a zero/non-positive budget would disable the bounded-exec watchdog)" "unset $_k for the default, or set COORD_${_k} to a positive millisecond budget"
      herdr_reads_ok=0
    fi
  done

  # Downstream sections read the clones; skip them if any workdir is unusable.
  # (NB: do NOT use `_` as the loop var — bash overwrites it with each command's
  # last arg, so the indirect `${!_}` would resolve to garbage after one iter.)
  local have_workdirs=1 wdvar2
  for wdvar2 in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    [ -n "${!wdvar2:-}" ] && [ -d "${!wdvar2:-}" ] && git -C "${!wdvar2}" rev-parse --git-dir >/dev/null 2>&1 || have_workdirs=0
  done

  if [ "$have_workdirs" = "1" ]; then
    printf -- '--- remote / branch agreement -------------------------------------\n'
    local rkey
    rkey=$(repo_key_from "$OBSERVER_WORKDIR") || rkey=""
    [ -n "$rkey" ] && d_ok "normalized repo key: $rkey" || d_code REMOTE_MISMATCH "doctor:remote" "$OBSERVER_WORKDIR" "observer has no remote.origin.url" "git -C $OBSERVER_WORKDIR remote add origin <url>"
    # Each clone MUST be checked out on BRANCH — a role clone on another branch
    # would type the next stage into the wrong branch (design §5/§11; finding:
    # branch agreement).
    local _bvar _bwd _bactual
    for _bvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
      _bwd="${!_bvar:-}"
      [ -d "$_bwd" ] || continue
      _bactual=$(git -C "$_bwd" symbolic-ref --short HEAD 2>/dev/null || echo "")
      if [ "$_bactual" = "$BRANCH" ]; then
        d_ok "$_bvar on $BRANCH"
      else
        d_code REMOTE_MISMATCH "doctor:remote:branch" "$_bvar" "$_bvar not on BRANCH=$BRANCH (on ${_bactual:-detached})" "git -C $_bwd checkout $BRANCH"
      fi
    done

    printf -- '--- observed remote trunk (fetch + git show) ----------------------\n'
    local fetch_ok=0 observed_commit=""
    if git -C "$OBSERVER_WORKDIR" fetch origin --quiet 2>/dev/null; then
      d_ok "git fetch origin ($OBSERVER_WORKDIR)"; fetch_ok=1
    else
      d_code GIT_FETCH_FAILED "doctor:remote:fetch" "$OBSERVER_WORKDIR" "git fetch origin failed" "check network / remote access / auth from $OBSERVER_WORKDIR"
    fi
    if [ "$fetch_ok" = "1" ]; then
      if git -C "$OBSERVER_WORKDIR" rev-parse --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
        observed_commit=$(git -C "$OBSERVER_WORKDIR" rev-parse "origin/$BRANCH")
        d_ok "origin/$BRANCH resolves -> ${observed_commit:0:12}"
      else
        d_code REMOTE_REF_MISSING "doctor:remote:ref" "origin/$BRANCH" "origin/$BRANCH missing after fetch" "confirm BRANCH=$BRANCH matches the remote trunk"
        fetch_ok=0
      fi
    fi
    local FEATURE="" CUR="" CTL="" J=""
    if [ "$fetch_ok" = "1" ]; then
      CUR=$(show_remote ".pipeline/current.json") || CUR=""
      if [ -z "$CUR" ]; then
        d_info "no .pipeline/current.json on origin/$BRANCH (no active feature / human mode)"
      elif ! printf '%s' "$CUR" | jq -e . >/dev/null 2>&1; then
        d_warn ".pipeline/current.json unreadable (cache; treated as no active feature)" "non-fatal — current.json is a cache (design §2)"
      else
        FEATURE=$(printf '%s' "$CUR" | jq -r '.feature // empty' 2>/dev/null) || FEATURE=""
        # The feature slug is UNTRUSTED (read from the remote current.json) and is
        # used in `git show` paths and output — validate it BEFORE any use so a
        # crafted slug ('..', '/', newline + forged MISS text) can neither traverse
        # nor inject forged diagnostic lines. (finding: doctor feature slug.)
        if [ -n "$FEATURE" ] && ! valid_feature_slug "$FEATURE"; then
          d_code CONFIG_INVALID "doctor:feature" "<redacted-slug>" \
            "feature slug from .pipeline/current.json on origin/$BRANCH is malformed or unsafe (must be a simple name [A-Za-z0-9][A-Za-z0-9._-]*)" \
            "inspect .pipeline/current.json on origin/$BRANCH; do not pass the raw value to any path"
          FEATURE=""
        fi
        [ -n "$FEATURE" ] && d_ok "active feature: $FEATURE" || d_info "current.json carries no .feature (human mode / idle)"
      fi

      if [ -n "$FEATURE" ]; then
        CTL=$(show_remote ".pipeline/$FEATURE/control.json") || CTL=""
        if [ -z "$CTL" ]; then
          d_info "no control.json (human mode — feature observed but never dispatched)"
        elif printf '%s' "$CTL" | jq -e '.schema_version == 1 and (.mode == "human" or .mode == "coordinated") and .merge_gate == "human-direct"' >/dev/null 2>&1; then
          d_ok "control.json valid (mode=$(printf '%s' "$CTL" | jq -r .mode))"
        else
          d_code CONTROL_MALFORMED "doctor:control" ".pipeline/$FEATURE/control.json" "control.json malformed or violates schema (schema_version/mode/merge_gate)" "inspect .pipeline/$FEATURE/control.json on origin/$BRANCH"
        fi

        # mode drives whether the journal authority is REQUIRED: a coordinated
        # feature cannot pass §12 preflight without a usable authoritative tail;
        # human / no-control mode stays informational (finding: journal authority).
        local ctl_mode="" j_required=0
        [ -n "$CTL" ] && ctl_mode=$(printf '%s' "$CTL" | jq -r '.mode // empty' 2>/dev/null)
        [ "$ctl_mode" = "coordinated" ] && j_required=1

        J=$(show_remote ".pipeline/$FEATURE/journal.md") || J=""
        if [ -z "$J" ]; then
          if [ "$j_required" = "1" ]; then
            d_code JOURNAL_MALFORMED "doctor:journal" ".pipeline/$FEATURE/journal.md" "coordinated feature $FEATURE has no journal.md on origin/$BRANCH (authoritative tail required in coordinated mode)" "commit a .pipeline/$FEATURE/journal.md"
          else
            d_warn "no journal.md for $FEATURE on origin/$BRANCH" "human mode — feature may be pre-first-commit"
          fi
        else
          local SEQ="" STATUS="" FROM="" TO="" NEXT="" NEXT_KIND="" PARSE_ERR=""
          # shellcheck disable=SC1090
          eval "$(printf '%s' "$J" | awk -f "$AWK" 2>/dev/null)"
          case "${PARSE_ERR:-}" in
            malformed-header) d_code JOURNAL_MALFORMED "doctor:journal" ".pipeline/$FEATURE/journal.md" "journal tail header malformed (non-numeric seq, or seq/status/to incomplete)" "inspect the tail entry of .pipeline/$FEATURE/journal.md on origin/$BRANCH" ;;
            no-entries)
              if [ "$j_required" = "1" ]; then
                d_code JOURNAL_MALFORMED "doctor:journal" ".pipeline/$FEATURE/journal.md" "coordinated feature $FEATURE journal has no entries on origin/$BRANCH" "the authoritative tail is required in coordinated mode — commit the first journal entry"
              else
                d_warn "journal has no entries yet" "feature is pre-first-commit"
              fi ;;
            "")               d_ok "journal tail: SEQ=$SEQ STATUS=$STATUS FROM=$FROM TO=$TO NEXT=${NEXT:-<empty>} NEXT_KIND=${NEXT_KIND:-<none>}" ;;
          esac
        fi
      fi
    fi

    printf -- '--- role panes (herdr) --------------------------------------------\n'
    local panes_json=""
    if [ "$herdr_reads_ok" != "1" ]; then
      d_info "skipping ALL Herdr reads: invalid watchdog budget (see the CONFIG_INVALID above) — no unbounded call is ever made"
    else
    panes_json=$(bounded_run_ms "$PANE_LIST_TIMEOUT_MS" herdr pane list 2>/dev/null) || panes_json=""
    if [ -z "$panes_json" ] || ! printf '%s' "$panes_json" | jq -e . >/dev/null 2>&1; then
      d_code DEPENDENCY_MISSING "doctor:panes" "herdr pane list" "'herdr pane list' returned no JSON" "is Herdr running? (herdr status; socket: ~/.config/herdr/herdr.sock)"
    else
      d_ok "herdr pane list reachable ($(printf '%s' "$panes_json" | jq '.result.panes | length') panes)"
      coord_check_role "CC"    "$CC_WORKDIR"    "${CC_PANE_ID:-}";   local cc_pane="${RES_PANE:-}"
      coord_check_role "PI"    "$PI_WORKDIR"    "${PI_PANE_ID:-}";   local pi_pane="${RES_PANE:-}"
      coord_check_role "CODEX" "$CODEX_WORKDIR" "${CODEX_PANE_ID:-}"; local cx_pane="${RES_PANE:-}"
      # Globally unique role panes (design §5/§11; finding: unique panes): two
      # roles resolving to the SAME pane would erase role isolation before dispatch.
      _pane_distinct() {
        if [ -n "$3" ] && [ -n "$4" ] && [ "$3" = "$4" ]; then
          d_code PANE_UNAUTHORIZED "doctor:panes" "$3" "$1 and $2 panes resolve to the same pane ($3) — each role needs a distinct pane" "configure distinct ${1}_PANE_ID/${2}_PANE_ID or separate role-clone cwds"
        fi
      }
      _pane_distinct CC    PI    "$cc_pane" "$pi_pane"
      _pane_distinct CC    CODEX "$cc_pane" "$cx_pane"
      _pane_distinct PI    CODEX "$pi_pane" "$cx_pane"
      unset -f _pane_distinct
    fi
    fi   # herdr_reads_ok gate
  else
    d_info "skipping remote/pane/state sections: one or more workdirs unusable (fix the config section above)"
  fi

  printf -- '--- local state ---------------------------------------------------\n'
  coord_doctor_state

  printf -- '---------------------------------------------------------------------\n'
  printf 'doctor: %d blocking, %d warning(s)\n' "$bad" "$warn"
  [ "$bad" -eq 0 ]
}

# coord_check_role <role> <workdir> <pin> — resolve pane + prove authority (§24.2).
coord_check_role() {
  local role=$1 workdir=$2 pin=$3 pane auth
  if resolve_role_pane "$role" "$workdir" "$pin" "$panes_json" "$COORD_SELF_PANE"; then
    pane="$RES_PANE"
    d_ok "$role pane resolved: $pane"
  else
    d_code "$RES_CODE" "doctor:panes:$role" "$workdir" "$role pane: $RES_MSG" "see coordinate.config.example (${role}_PANE_ID / role clone cwd)"
    return
  fi
  auth=$(authority_of "$pane" "$AUTH_TIMEOUT_MS")
  if [ "$auth" = "1" ]; then
    d_ok "$role pane lifecycle authority: confirmed (hook/matched-rule, no idle fallback)"
  else
    d_code AGENT_STATUS_INVALID "doctor:panes:$role" "$pane" "$role pane $pane: agent status source NOT authoritative (no lifecycle hook / no MATCHED manifest rule — always-idle fallback)" "attach that agent's Herdr integration, or pin to a pane with hook authority (design §24.2)"
  fi
}

# coord_doctor_state — state root existence/permissions, ledger integrity, lock, halt.
# ---- state safety checks (design §19; finding: state preflight) ----------------
# _state_symlink_bad <path> <root> — echoes the offending symlink path (and
# returns 0) if <path> or any ancestor STRICTLY below <root> is a symlink; returns 1
# (empty output) otherwise. §19 forbids symlink destinations and symlinked parents.
_state_symlink_bad() {
  local p=$1 root=$2 cur
  [ -L "$p" ] && { printf '%s' "$p"; return 0; }
  [ "$p" = "$root" ] && return 1          # nothing above the root is ours to check
  cur=$(dirname "$p")
  while [ "$cur" != "$root" ] && [ -n "$cur" ] && [ "$cur" != "/" ]; do
    [ -L "$cur" ] && { printf '%s' "$cur"; return 0; }
    cur=$(dirname "$cur")
  done
  return 1
}
# _state_assert_dir/_file <path> <root> <label> — BLOCK unless <path> is a real
# (non-symlink, non-symlinked-parent) entry of the right TYPE with mode 0700 (dir)
# / 0600 (regular file). RETURNS nonzero on any violation so the caller can (and
# MUST) skip every downstream read — a mode-0600 FIFO named ledger.json would hang
# the jq/cat that follows. (finding: require regular files + stop reading after a
# failed assertion.)
_state_assert_dir() {
  local p=$1 root=$2 label=$3 sym perm
  if sym=$(_state_symlink_bad "$p" "$root"); then
    d_code CONFIG_INVALID "doctor:state" "$p" "$label ($p) is reached via a symlink ($sym) — §19 forbids symlinked state paths" "remove the symlink; restore $label as a real directory"
    return 1
  fi
  if [ ! -d "$p" ]; then
    d_code CONFIG_INVALID "doctor:state" "$p" "$label ($p) is not a directory" "restore $label as a real 0700 directory"
    return 1
  fi
  perm=$(stat_perms "$p" 2>/dev/null)
  if [ "$perm" = "700" ]; then d_ok "$label dir 0700 ($p)"; return 0
  else d_code CONFIG_INVALID "doctor:state" "$p" "$label dir mode is ${perm:-?} (expected 0700) — §19" "chmod 700 $p"; return 1; fi
}
_state_assert_file() {
  local p=$1 root=$2 label=$3 sym perm
  if sym=$(_state_symlink_bad "$p" "$root"); then
    d_code CONFIG_INVALID "doctor:state" "$p" "$label ($p) is reached via a symlink ($sym) — §19 forbids symlinked state paths" "remove the symlink; restore $label as a real file"
    return 1
  fi
  if [ ! -f "$p" ]; then
    # -f = REGULAR file only: a FIFO/socket/device here would HANG any reader with
    # no writer, so it is refused BEFORE anything opens it.
    d_code CONFIG_INVALID "doctor:state" "$p" "$label ($p) is not a regular file — refusing to read it (a FIFO/socket/device would hang doctor)" "replace $p with a regular 0600 file"
    return 1
  fi
  perm=$(stat_perms "$p" 2>/dev/null)
  if [ "$perm" = "600" ]; then d_ok "$label file 0600 ($p)"; return 0
  else d_code CONFIG_INVALID "doctor:state" "$p" "$label file mode is ${perm:-?} (expected 0600) — §19" "chmod 600 $p"; return 1; fi
}
# ledger_schema_problem <file> — echoes the first missing/invalid §13 record
# field, or "" if the ledger is complete: feature / journal_seq (INTEGER) /
# journal_commit (40-hex) / target_role ∈ CC|PI|CODEX / pane / command NAME /
# delivery ∈ pending|sent|waiting. Fractional seqs, unknown roles, and a missing
# command name are all corrupt. (finding: full §13 ledger schema.)
ledger_schema_problem() {
  jq -r '
    if (.feature | type) != "string" or .feature == "" then "missing .feature"
    elif (.journal_seq | type) != "number" or (.journal_seq | floor) != .journal_seq then "missing/invalid .journal_seq (need integer)"
    elif (.journal_commit | type) != "string" or (.journal_commit | test("^[0-9a-f]{40}$") | not) then "missing/invalid .journal_commit (need 40-hex)"
    elif (.target_role | type) != "string" or (.target_role | IN("CC","PI","CODEX") | not) then "missing/invalid .target_role (need CC|PI|CODEX)"
    elif (.pane | type) != "string" or .pane == "" then "missing .pane"
    elif (.command | type) != "string" or .command == "" then "missing .command (command name)"
    elif (.delivery | type) != "string" or (.delivery | IN("pending","sent","waiting") | not) then "missing/invalid .delivery (need pending|sent|waiting)"
    else "" end
  ' "$1" 2>/dev/null
}

coord_doctor_state() {
  local root rkey repodir
  root=$(state_root)
  rkey=$(repo_key_from "$OBSERVER_WORKDIR" 2>/dev/null) || rkey=""
  repodir="$root/${rkey:-<unknown>}"
  # Parent chain FIRST — before the absent-root early return. A symlinked parent
  # redirects the whole state tree whether or not the root exists yet: the normal
  # first write would land through the forbidden parent. Walking the chain is safe
  # pre-creation (a non-existent component is never a symlink; -L is simply false).
  # (finding: parent check must precede the absent early-return.)
  local _p _parent_bad=0; _p=$(dirname "$root")
  while [ "$_p" != "/" ] && [ -n "$_p" ]; do
    if [ -L "$_p" ]; then
      d_code CONFIG_INVALID "doctor:state" "$root" "parent of state root ($_p) is a symlink — §19 forbids symlinked state parents (blocking even before first write)" "remove the symlink $_p or point STATE_DIR outside a symlinked tree"
      _parent_bad=1; break
    fi
    # An EXISTING non-directory ancestor means the root can NEVER be created here —
    # "not created yet" would be a lie. (finding: non-directory ancestors.)
    if [ -e "$_p" ] && [ ! -d "$_p" ]; then
      d_code CONFIG_INVALID "doctor:state" "$root" "ancestor of state root ($_p) exists but is not a directory — the state root can never be created beneath it" "point STATE_DIR at a creatable directory path"
      _parent_bad=1; break
    fi
    _p=$(dirname "$_p")
  done
  # A REJECTED PARENT poisons the entire subtree — the root itself may be a real
  # 0700 directory reached THROUGH the forbidden parent, and _state_assert_dir
  # cannot rediscover the violation (the root is its trust boundary). Never read
  # past it. (finding: stop after a rejected state-root parent.)
  [ "$_parent_bad" = "1" ] && return 0
  if [ ! -d "$root" ]; then
    # Distinguish "absent" (fine — created on first write) from a dangling
    # symlink or a non-directory entry at the state root (BLOCKING). (finding:
    # dangling/state-root type.)
    if [ -L "$root" ] || [ -e "$root" ]; then
      d_code CONFIG_INVALID "doctor:state" "$root" "state root is a symlink (dangling or not) or a non-directory entry — cannot treat as uninitialized" "remove $root (or point STATE_DIR at a real directory)"
    else
      d_info "state root not created yet: $root (created 0700 on first write; design §13)"
    fi
    return
  fi
  d_ok "state root exists: $root"
  # A REJECTED root poisons everything beneath it: stop — never read past a failed
  # directory assertion (finding: stop traversal after a directory trust failure).
  _state_assert_dir "$root" "$root" "state root" || return 0
  if [ -d "$repodir" ]; then
    _state_assert_dir "$repodir" "$root" "repo state" || return 0
    # Per-feature (§13 layout: halt.json / lock / ledger.json live in the feature
    # dir). A rejected feature dir's CONTENTS are never inspected.
    local featd
    for featd in "$repodir"/*/; do
      [ -d "$featd" ] || continue
      featd=${featd%/}
      _state_assert_dir "$featd" "$root" "feature state ($(basename "$featd"))" || continue
      _doctor_feature_state "$featd" "$root"
    done
  else
    d_info "no state for repo key ${rkey:-<unknown>} (idle)"
  fi
}

# _doctor_feature_state <featdir> <root> — halt/lock/ledger checks for ONE feature
# whose directory assertion already PASSED. Every file read is gated on its own
# assertion; a rejected entry is reported and never opened.
_doctor_feature_state() {
  local featd=$1 root=$2 ffeat; ffeat=$(basename "$featd")
  # halt.json (unresolved halt blocks watch; resume is the only bypass).
  local haltf="$featd/halt.json"
  if [ -e "$haltf" ] || [ -L "$haltf" ]; then
    if _state_assert_file "$haltf" "$root" "halt.json ($ffeat)"; then
      local code; code=$(jq -r '.code // "HALTED"' "$haltf" 2>/dev/null || echo HALTED)
      d_warn "unresolved halt.json present ($code): $haltf" "inspect it, then \`coordinate.sh resume --config $CONF --reason <text>\` (not implemented this phase)"
    else
      d_warn "unresolved halt.json present (REJECTED above — not read): $haltf" "fix the file-level MISS above, then re-run doctor"
    fi
  fi
  # lock dir (held = a watch is running; stale = dead PID, resume clears it).
  local lockd="$featd/lock"
  if [ -e "$lockd" ] || [ -L "$lockd" ]; then
    if _state_assert_dir "$lockd" "$root" "watch lock ($ffeat)"; then
      local pidf="" pid="" st="held"
      pidf=$(find "$lockd" -type f 2>/dev/null | head -1)
      if [ -n "$pidf" ]; then
        # cat runs ONLY when the assertion passed (a FIFO pidfile would hang it).
        if _state_assert_file "$pidf" "$root" "lock pidfile"; then
          pid=$(cat "$pidf" 2>/dev/null || echo "")
        fi
      fi
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then st="stale"; fi
      d_warn "watch lock present ($st): $lockd" "$([ "$st" = stale ] && echo "resume clears a stale lock after preflight" || echo "a watch is running — that is expected")"
    fi
  fi
  # ledger.json integrity (§13 schema, not just valid JSON): feature / journal_seq
  # / full 40-hex commit / target_role ∈ CC|PI|CODEX / pane / command name /
  # delivery ∈ pending|sent|waiting, AND the ledger .feature must match its
  # directory name. (finding: full §13 ledger schema.) A rejected ledger (symlink /
  # non-regular / bad mode) is NEVER read — jq on a FIFO would hang forever.
  local led="$featd/ledger.json" jerr prob lfeat
  if [ -e "$led" ] || [ -L "$led" ]; then
    _state_assert_file "$led" "$root" "ledger.json ($ffeat)" || return 0
    if ! jerr=$(jq -e . "$led" 2>&1 >/dev/null); then
      d_code LEDGER_CORRUPT "doctor:state:ledger" "$led" "ledger.json ($ffeat) not JSON: ${jerr:-unreadable}" "inspect $led; remove only after confirming no dispatch is in flight"
      return 0
    fi
    prob=$(ledger_schema_problem "$led")
    if [ -n "$prob" ]; then
      d_code LEDGER_CORRUPT "doctor:state:ledger" "$led" "ledger.json ($ffeat) schema incomplete: $prob" "inspect $led; restore the full §13 schema (feature/seq/commit/role/pane/command/delivery)"
      return 0
    fi
    lfeat=$(jq -r '.feature // ""' "$led" 2>/dev/null)
    if [ "$lfeat" != "$ffeat" ]; then
      d_code LEDGER_CORRUPT "doctor:state:ledger" "$led" "ledger.json feature ($lfeat) != its directory name ($ffeat)" "move the ledger under <repo-key>/$lfeat/ or fix .feature"
    else
      d_ok "ledger.json valid ($ffeat: full §13 schema)"
    fi
  fi
}

# ---- status (read-only; design §12) -------------------------------------------
cmd_status() {
  validate_config || {
    # Decode the SAME tab tuple validate_config now writes (CODE<TAB>input<TAB>reason)
    # so status surfaces a stable CONFIG_INVALID instead of the raw record. (finding:
    # §14 tuple — one encoding, decoded consistently everywhere.)
    local first="${CFG_V[0]:-}"
    local fcode finput freason
    if [ -n "$first" ]; then
      IFS=$'\t' read -r fcode finput freason <<< "$first"
    fi
    coord_die "${fcode:-CONFIG_INVALID}" "status:validate_config" "${finput:-$CONF}" \
      "${freason:-config validation failed}" "edit $CONF (coordinate.config.example documents each rule)"
  }
  local root rkey repodir feat="" cur
  root=$(state_root)
  rkey=$(repo_key_from "$OBSERVER_WORKDIR" 2>/dev/null) || rkey=""
  repodir="$root/${rkey:-unknown}"
  # Discover the active feature from the observer's LOCAL HEAD (no fetch — status
  # never touches the network or mutates state). Best-effort.
  cur=$(git -C "$OBSERVER_WORKDIR" show "HEAD:.pipeline/current.json" 2>/dev/null) || cur=""
  if [ -n "$cur" ]; then feat=$(printf '%s' "$cur" | jq -r '.feature // empty' 2>/dev/null) || feat=""; fi
  if [ -z "$feat" ] && [ -d "$repodir" ]; then
    # fall back to the most recently modified feature subdir
    feat=$(cd "$repodir" 2>/dev/null && ls -1dt */ 2>/dev/null | head -1); feat="${feat%/}"
  fi
  # The feature slug is UNTRUSTED (read from HEAD's current.json, or a state subdir
  # name) and is concatenated into a state path — validate it BEFORE path use so a
  # malicious slug ('..', with '/', whitespace, control chars) cannot traverse into
  # another repo/feature state namespace (finding: feature slug).
  if [ -n "$feat" ] && ! valid_feature_slug "$feat"; then
    coord_die CONFIG_INVALID "status:feature" "<redacted-slug>" \
      "feature slug from current.json is malformed or unsafe: must be a simple name ([A-Za-z0-9][A-Za-z0-9._-]*), got something containing '/', '..', or whitespace/control chars" \
      "inspect .pipeline/current.json on HEAD in $OBSERVER_WORKDIR; do NOT pass the raw value to any path"
  fi

  local state="idle" seq="" commit="" delivery="" halt_code="" lock_state="free"
  if [ -z "$rkey" ] || [ ! -d "$repodir" ] || [ -z "$feat" ]; then
    printf 'coordinate: idle (no state for %s%s)\n' "${rkey:+$rkey/}" "${feat:-}"
    emit_status_json "$state" "$rkey" "$feat" "$seq" "$commit" "$delivery" "$halt_code" "$lock_state"
    exit 0
  fi

  local featdir="$repodir/$feat"
  if [ ! -d "$featdir" ]; then
    printf 'coordinate: idle (no state yet for feature %s)\n' "$feat"
    emit_status_json "$state" "$rkey" "$feat" "$seq" "$commit" "$delivery" "$halt_code" "$lock_state"
    exit 0
  fi

  # ledger (last observed Git identifiers live here).
  if [ -f "$featdir/ledger.json" ]; then
    if ! jq -e . "$featdir/ledger.json" >/dev/null 2>&1; then
      printf 'coordinate: LEDGER_CORRUPT (ledger for %s is not JSON)\n' "$feat"
      jq -nc --arg repo_key "$rkey" --arg feature "$feat" \
           '{state:"error", error_code:"LEDGER_CORRUPT", repo_key:$repo_key, feature:$feature}'
      exit 1
    fi
    state="observed"
    seq=$(jq -r '.journal_seq // empty'       "$featdir/ledger.json")
    commit=$(jq -r '.journal_commit // empty' "$featdir/ledger.json")
    delivery=$(jq -r '.delivery // empty'     "$featdir/ledger.json")
  fi

  if [ -f "$featdir/halt.json" ]; then
    halt_code=$(jq -r '.code // "HALTED"' "$featdir/halt.json" 2>/dev/null || echo HALTED)
    state="halted"
  fi
  if [ -d "$featdir/lock" ]; then lock_state="held"; fi

  local short="${commit:0:12}"
  printf 'coordinate: feature=%s state=%s seq=%s commit=%s delivery=%s%s%s\n' \
    "$feat" "$state" "${seq:-<none>}" "${short:-<none>}" "${delivery:-<none>}" \
    "${halt_code:+ halted=}$halt_code" "${lock_state:+ lock=}$lock_state"
  emit_status_json "$state" "$rkey" "$feat" "$seq" "$commit" "$delivery" "$halt_code" "$lock_state"
}

emit_status_json() {  # <state> <rkey> <feat> <seq> <commit> <delivery> <halt> <lock>
  # Compact (one-line) object. Empty strings coerce to null via n() — a bare
  # `(x|select(length>0))` yields jq `empty`, and an object literal with ANY empty
  # field is itself suppressed (emits nothing), which would drop the whole line.
  jq -nc \
    --arg state "$1" --arg repo_key "$2" --arg feature "$3" \
    --arg seq "$4" --arg commit "$5" --arg delivery "$6" \
    --arg halt "$7" --arg lock "$8" '
    def n(e): if (e|length) > 0 then e else null end;
    {state:$state, repo_key:$repo_key, feature:n($feature),
     last_observed:{journal_seq:n($seq), journal_commit:n($commit), delivery:n($delivery)},
     halt:n($halt), lock:$lock}'
}

# ---- watch/resume helpers (design §8/§13/§14/§16/§19) ---------------------------
# Globals set up by cmd_watch/cmd_resume after config load. W_FEATDIR is the
# <state-root>/<repo-key>/<feature> directory; W_LOCK_HELD is 1 while THIS process
# holds the feature lock. coord_fatal uses these to write audit/halt; when they are
# unset (a fatal before state set-up) it falls back to sanitized stderr only.
W_FEATURE=""; W_FEATDIR=""; W_RKEY=""; W_REPOROOT=""; W_LOCK_HELD=0

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }   # ISO8601 UTC, second resolution

# atomic_write <path> <mode-octal>  — read content from stdin, write it via an
# exclusive SAME-DIRECTORY temp file + atomic rename (§13/§19). Rejects a symlink
# destination (the rename would otherwise follow it). Returns nonzero on any failure;
# the temp is removed on all error paths so nothing partial is left behind.
atomic_write() {
  local path=$1 mode=$2 dir tmp
  [ -L "$path" ] && return 1                 # symlink destination forbidden (§19)
  dir=$(dirname "$path")
  [ -d "$dir" ] || return 1
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  chmod "$mode" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  return 0
}

# state_setup_dirs <featdir> — create the state-root/<repo-key>/<feature> chain
# at 0700 (idempotent). Validates the state-root PARENT chain and the root itself
# reject symlinked/non-directory ancestors BEFORE creating anything (§19; a
# rejected parent poisons the subtree). Returns nonzero + sets STATE_SETUP_ERR on a
# blocking violation.
state_setup_dirs() {
  local featd=$1 root rp rp2 p
  root=$(state_root)
  rp=$(resolve_path "$root")
  STATE_SETUP_ERR=""
  # parent chain (above the root): reject symlinks and existing non-directories.
  p=$(dirname "$rp")
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    if [ -L "$p" ]; then STATE_SETUP_ERR="parent of state root ($p) is a symlink — §19 forbids symlinked state parents"; return 1; fi
    if [ -e "$p" ] && [ ! -d "$p" ]; then STATE_SETUP_ERR="ancestor of state root ($p) exists but is not a directory"; return 1; fi
    p=$(dirname "$p")
  done
  # the root itself, if it exists, must be a real directory (not a symlink / file).
  if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
    STATE_SETUP_ERR="state root ($root) is a symlink or non-directory entry"; return 1; fi
  rp2=$(resolve_path "$featd"); p=$(dirname "$rp2")
  while [ "$p" != "$rp" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
    if [ -L "$p" ]; then STATE_SETUP_ERR="state component ($p) is a symlink"; return 1; fi
    p=$(dirname "$p")
  done
  [ -d "$root" ] || { mkdir -p "$root" 2>/dev/null && chmod 700 "$root" 2>/dev/null || { STATE_SETUP_ERR="cannot create state root $root"; return 1; }; }
  # repo-key dir + feature dir, 0700.
  local rd; rd=$(dirname "$featd")
  [ -d "$rd" ] || { mkdir -p "$rd" 2>/dev/null && chmod 700 "$rd" 2>/dev/null || { STATE_SETUP_ERR="cannot create repo state dir $rd"; return 1; }; }
  [ -d "$featd" ] || { mkdir -p "$featd" 2>/dev/null && chmod 700 "$featd" 2>/dev/null || { STATE_SETUP_ERR="cannot create feature state dir $featd"; return 1; }; }
  return 0
}

# ---- audit (§16) ---------------------------------------------------------------
# audit_commit <featdir> — append ONE events.jsonl line built from the A_* globals
# (caller sets A_EVENT plus any applicable A_* fields; missing ⇒ null). Returns
# nonzero on append failure (caller fatalizes AUDIT_WRITE_FAILED). The events file
# is opened append-only; if it is a symlink the append is refused (§19).
audit_commit() {
  local featd=$1 evf="$1/events.jsonl"
  [ -L "$evf" ] && return 1
  jq -nc --arg timestamp "$(now_iso)" \
        --arg event "${A_EVENT:-}" \
        --arg remote_identity "${W_RKEY:-}" \
        --arg branch "${BRANCH:-}" \
        --arg feature "${W_FEATURE:-}" \
        --arg journal_commit "${A_COMMIT:-}" \
        --arg journal_seq "${A_SEQ:-}" \
        --arg transition "${A_TRANSITION:-}" \
        --arg stage_status "${A_STATUS:-}" \
        --arg action "${A_ACTION:-}" \
        --arg target_role "${A_TARGET_ROLE:-}" \
        --arg pane_id "${A_PANE:-}" \
        --arg result "${A_RESULT:-}" \
        --arg duration_ms "${A_DURATION_MS:-}" \
        --arg error_code "${A_ERROR_CODE:-}" \
        --arg error_context "${A_ERROR_CONTEXT:-}" \
        --arg next_action "${A_NEXT_ACTION:-}" '
    def n(e): if (e|type)=="string" and (e|length)>0 then e else null end;
    def num(e): if (e|type)=="string" and (e|length)>0 then (e|tonumber) else null end;
    {timestamp:$timestamp, event:$event,
     remote_identity:n($remote_identity), branch:n($branch), feature:n($feature),
     journal_commit:n($journal_commit), journal_seq:num($journal_seq),
     transition:n($transition), stage_status:n($stage_status), action:n($action),
     target_role:n($target_role), pane_id:n($pane_id), result:n($result),
     duration_ms:num($duration_ms), error_code:n($error_code),
     error_context:n($error_context), next_action:n($next_action)}' \
    >> "$evf" 2>/dev/null
}

# ---- ledger (§13) --------------------------------------------------------------
# ledger_path  — echoes the absolute ledger path (W_FEATDIR/ledger.json).
ledger_path() { printf '%s/ledger.json' "$W_FEATDIR"; }

# ledger_read  — read+schema-validate the ledger; echoes a tab-separated
#   feature<TAB>seq<TAB>commit<TAB>role<TAB>pane<TAB>command<TAB>delivery, or empty
#   + LEDGER_ERR on failure/absence. Never called on a rejected path.
LEDGER_ERR=""
ledger_read() {
  LEDGER_ERR=""
  local led; led=$(ledger_path)
  if [ ! -f "$led" ]; then LEDGER_ERR="absent"; return 1; fi
  [ -L "$led" ] && { LEDGER_ERR="ledger is a symlink"; return 1; }
  local prob j
  if ! j=$(jq -e . "$led" 2>&1 >/dev/null); then LEDGER_ERR="not JSON: ${j:-unreadable}"; return 1; fi
  if prob=$(ledger_schema_problem "$led") && [ -n "$prob" ]; then LEDGER_ERR="schema: $prob"; return 1; fi
  jq -r '[.feature,.journal_seq,.journal_commit,.target_role,.pane,.command,.delivery]|@tsv' "$led" 2>/dev/null
}

# ledger_write <seq> <commit> <role> <pane> <command-name> <delivery> — atomic
#   0600 write of the full §13 ledger record.
ledger_write() {
  local seq=$1 commit=$2 role=$3 pane=$4 cmdname=$5 delivery=$6
  jq -nc --arg feature "$W_FEATURE" --argjson seq "$seq" --arg commit "$commit" \
        --arg role "$role" --arg pane "$pane" --arg command "$cmdname" --arg delivery "$delivery" \
    '{feature:$feature, journal_seq:$seq, journal_commit:$commit, target_role:$role,
      pane:$pane, command:$command, delivery:$delivery}' \
    | atomic_write "$(ledger_path)" 600
}

# ledger_clear  — remove the dispatch record (back to observed-idle) atomically:
#   rewrite to an "idle" marker (delivery="idle"), so status/doctor still see a
#   valid record but watch treats it as no in-flight dispatch.
ledger_clear() {
  jq -nc --arg feature "$W_FEATURE" --argjson seq 0 --arg commit "" \
        --arg role "" --arg pane "" --arg command "" --arg delivery "idle" \
    '{feature:$feature, journal_seq:$seq, journal_commit:"", target_role:"",
      pane:"", command:"", delivery:"idle"}' \
    | atomic_write "$(ledger_path)" 600
}

# ---- lock (§13/§19) -------------------------------------------------------------
# lock_acquire <featdir> — atomic mkdir of <featdir>/lock + a 0600 pidfile. Returns
#   0 if acquired; on a pre-existing lock, sets LOCK_STATE (held|stale) + LOCK_PID
#   and returns nonzero (caller fatalizes LOCK_HELD / LOCK_STALE).
LOCK_STATE=""; LOCK_PID=""
lock_acquire() {
  local featd=$1 lockd="$1/lock" pidf
  LOCK_STATE=""; LOCK_PID=""
  if mkdir "$lockd" 2>/dev/null; then
    chmod 700 "$lockd" 2>/dev/null || true
    pidf="$lockd/pid"
    printf '%s\n' "$$" | atomic_write "$pidf" 600 || { rmdir "$lockd" 2>/dev/null || true; return 1; }
    W_LOCK_HELD=1; return 0
  fi
  # lock exists — inspect the recorded PID (the pidfile must be a regular file).
  pidf="$lockd/pid"
  if [ -L "$pidf" ] || [ ! -f "$pidf" ]; then LOCK_STATE="stale"; LOCK_PID=""; return 1; fi
  LOCK_PID=$(cat "$pidf" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then LOCK_STATE="held"; else LOCK_STATE="stale"; fi
  return 1
}

# lock_release — remove the pidfile + lock dir this process created. Best-effort;
# only called when W_LOCK_HELD=1. Never removes another process's lock.
lock_release() {
  [ "$W_LOCK_HELD" = "1" ] || return 0
  local lockd="$W_FEATDIR/lock" pidf="$W_FEATDIR/lock/pid"
  local mine=""
  [ -f "$pidf" ] && mine=$(cat "$pidf" 2>/dev/null || echo "")
  if [ "$mine" = "$$" ]; then rm -f -- "$pidf" 2>/dev/null || true; rmdir "$lockd" 2>/dev/null || true; fi
  W_LOCK_HELD=0
}

# ---- the §14 fatal path --------------------------------------------------------
# coord_fatal <code> <where> <input> <reason> <next_action> [resume_guard] — the
#   ordered §14 sequence: stop dispatches (implicit) → audit fatal → halt.json →
#   stderr tuple → bounded ON_HALT_EXEC (argv [halt.json path]) → release lock →
#   exit 1. Falls back to sanitized stderr if the audit/halt sink is unavailable.
coord_fatal() {
  local code=$1 where=$2 input=$3 reason=$4 action=$5 guard=${6:-}
  [ -n "$guard" ] || guard="fix the above, then re-run \`coordinate.sh doctor --config $CONF\`; resume never bypasses it"
  local haltf=""
  if [ -n "$W_FEATDIR" ] && [ -d "$W_FEATDIR" ]; then
    A_EVENT="fatal"; A_ERROR_CODE="$code"; A_NEXT_ACTION="$action"; A_ERROR_CONTEXT="$where: $reason"
    audit_commit "$W_FEATDIR" 2>/dev/null || true
    A_EVENT=""; A_ERROR_CODE=""; A_NEXT_ACTION=""; A_ERROR_CONTEXT=""
    haltf="$W_FEATDIR/halt.json"
    jq -nc --arg ts "$(now_iso)" --arg code "$code" --arg where "$where" --arg input "$input" \
          --arg reason "$reason" --arg next_action "$action" --arg resume_guard "$guard" \
          --arg feature "${W_FEATURE:-}" --arg remote_identity "${W_RKEY:-}" --arg branch "${BRANCH:-}" '
      {timestamp:$ts, code:$code, where:$where, input:$input, reason:$reason,
       next_action:$next_action, resume_guard:$resume_guard,
       feature:n($feature), remote_identity:n($remote_identity), branch:n($branch)}' \
      | atomic_write "$haltf" 600 2>/dev/null || haltf=""
  fi
  printf '\n=== COORDINATOR FATAL ===\n'        >&2
  printf 'code:        %s\n' "$code"            >&2
  printf 'where:       %s\n' "$where"           >&2
  printf 'input:       %s\n' "$input"           >&2
  printf 'reason:      %s\n' "$reason"          >&2
  printf 'next_action: %s\n' "$action"          >&2
  printf 'resume_guard: %s\n' "$guard"          >&2
  if [ -n "$haltf" ] && [ -n "${ON_HALT_EXEC:-}" ] && [ -x "$ON_HALT_EXEC" ] && [ ! -L "$ON_HALT_EXEC" ]; then
    # argv vector, no shell, bounded 10s; hook failure is reported but never masks.
    bounded_run_ms 10000 "$ON_HALT_EXEC" "$haltf" >/dev/null 2>&1 || \
      note "coordinate.sh: ON_HALT_EXEC exited nonzero (reported; the original fatal above stands)" >&2
  fi
  lock_release
  exit 1
}

# ---- route table (design §7) ---------------------------------------------------
# route_classify <from> <to> <status> <next_kind> — validates the parsed tail
#   against the §7 allowlist. Both the header transition AND the NEXT_KIND must
#   match (design: "do not equate the header arrow mechanically with the next
#   command"). Sets DECISION_KIND (dispatch|merge-wait|complete), DECISION_ROLE
#   (CC|PI|CODEX), DECISION_CMD (prefix to type; empty for impl-delegate),
#   DECISION_CMDNAME (audit name), DECISION_DELEGATE (herdr|drive.sh). Returns 1
#   and sets ROUTE_ERRCODE/ROUTE_ERRMSG on a protocol fatal (TRANSITION_ILLEGAL /
#   NEXT_INVALID). Card-counter (§15) validation runs separately in the watch loop
#   for the retry/rejection/blocked routes; this function owns only the transition
#   allowlist. NB: FROM is best-effort (genesis ∅→prd leaves FROM empty).
route_classify() {
  local from=$1 to=$2 status=$3 nk=$4
  DECISION_KIND=""; DECISION_ROLE=""; DECISION_CMD=""; DECISION_CMDNAME=""; DECISION_DELEGATE=""
  ROUTE_ERRCODE=""; ROUTE_ERRMSG=""
  # terminal: review->done completed (any NEXT_KIND — parse-tail marks it "other").
  if [ "$to" = done ] && [ "$status" = completed ]; then
    DECISION_KIND=complete; return 0
  fi
  # WAITING_HUMAN_MERGE: the EXACT marker is only valid on review->review completed.
  if [ "$nk" = merge-wait ]; then
    if [ "$to" = review ] && [ "$status" = completed ]; then DECISION_KIND=merge-wait; return 0; fi
    ROUTE_ERRCODE=NEXT_INVALID; ROUTE_ERRMSG="merge-wait marker with to=$to status=$status — only review->review completed is a valid merge gate"; return 1
  fi
  case "$nk" in
    run-arch)
      [ "$status" = completed ] && [ "$to" = prd ] || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="Run pipeline-arch requires a completed PRD entry (to=prd); got to=$to status=$status"; return 1; }
      DECISION_KIND=dispatch; DECISION_ROLE=CC; DECISION_CMD=${CC_ARCH_CMD:-}; DECISION_CMDNAME=pipeline-arch; DECISION_DELEGATE=herdr ;;
    run-task)
      { [ "$status" = completed ] && { [ "$to" = arch ] || [ "$to" = hunt ]; }; } || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="Run pipeline-task requires completed arch (to=arch) or hunt (to=hunt); got to=$to status=$status"; return 1; }
      DECISION_KIND=dispatch; DECISION_ROLE=CC; DECISION_CMD=${CC_TASK_CMD:-}; DECISION_CMDNAME=pipeline-task; DECISION_DELEGATE=herdr ;;
    run-impl)
      # task->impl (start), impl->impl (continue/informed-retry), review->impl
      # (changes-requested), hunt->impl (reset). All delegate to drive.sh.
      case "$to" in
        task) [ "$status" = completed ] || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="task->impl requires completed task; got status=$status"; return 1; } ;;
        impl) { [ "$status" = completed ] || [ "$status" = failed ]; } || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="impl->impl requires completed|failed; got status=$status"; return 1; } ;;
        *) ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="Run pipeline-impl with unexpected to=$to (expected task|impl)"; return 1 ;;
      esac
      DECISION_KIND=dispatch; DECISION_ROLE=PI; DECISION_CMD=""; DECISION_CMDNAME=pipeline-impl; DECISION_DELEGATE=drive.sh ;;
    run-review)
      { [ "$status" = completed ] && [ "$to" = review ]; } || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="Run pipeline-review requires impl->review completed (to=review); got to=$to status=$status"; return 1; }
      DECISION_KIND=dispatch; DECISION_ROLE=CODEX; DECISION_CMD=${CODEX_REVIEW_CMD:-}; DECISION_CMDNAME=pipeline-review; DECISION_DELEGATE=herdr ;;
    run-hunt)
      { [ "$status" = blocked ] && { [ "$to" = hunt ] || [ "$from" = impl ] || [ "$from" = review ]; }; } || { ROUTE_ERRCODE=TRANSITION_ILLEGAL; ROUTE_ERRMSG="Run pipeline-hunt requires a blocked impl/review->hunt; got from=$from to=$to status=$status"; return 1; }
      DECISION_KIND=dispatch; DECISION_ROLE=CC; DECISION_CMD=${CC_HUNT_CMD:-}; DECISION_CMDNAME=pipeline-hunt; DECISION_DELEGATE=herdr ;;
    run-*) ROUTE_ERRCODE=NEXT_INVALID; ROUTE_ERRMSG="unknown Run pipeline-<stage>: $nk"; return 1 ;;
    "")
      ROUTE_ERRCODE=NEXT_INVALID; ROUTE_ERRMSG="no usable NEXT_KIND from the tail handoff (to=$to status=$status)"; return 1 ;;
    *)
      ROUTE_ERRCODE=NEXT_INVALID; ROUTE_ERRMSG="unroutable NEXT_KIND=$nk (to=$to status=$status) — the coordinator never infers a route from prose"; return 1 ;;
  esac
  return 0
}

# ---- arg dispatch --------------------------------------------------------------
usage() {
  cat >&2 <<EOF
usage: coordinate.sh <subcommand> --config <path> [--reason <text]

subcommands:
  doctor   read-only full preflight (deps / config / remote / journal / panes / authority / state)
  status   read-only local state summary (one human line + one JSON object)
  watch    not implemented this phase — see coordinator-design.md
  resume   not implemented this phase — see coordinator-design.md
EOF
}

SUBCMD="${1:-}"; shift || true
CONF=""; REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || { echo "coordinate.sh: --config needs a path" >&2; exit 2; }; CONF=$2; shift 2 ;;
    --reason) [ $# -ge 2 ] || { echo "coordinate.sh: --reason needs text" >&2; exit 2; }; REASON=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "coordinate.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$SUBCMD" in
  doctor)
    [ -n "$CONF" ] || { echo "coordinate.sh: doctor requires --config <path>" >&2; usage; exit 2; }
    [ -f "$CONF" ] || coord_die CONFIG_INVALID "doctor:arg-parse" "$CONF" "config file not found" "create it from coordinate.config.example"
    # shellcheck disable=SC1090
    . "$CONF" || coord_die CONFIG_INVALID "doctor:load_config" "$CONF" "config file failed to source (bash syntax error)" "fix the bash syntax in $CONF"
    cmd_doctor
    ;;
  status)
    [ -n "$CONF" ] || { echo "coordinate.sh: status requires --config <path>" >&2; usage; exit 2; }
    [ -f "$CONF" ] || coord_die CONFIG_INVALID "status:arg-parse" "$CONF" "config file not found" "create it from coordinate.config.example"
    # shellcheck disable=SC1090
    . "$CONF" || coord_die CONFIG_INVALID "status:load_config" "$CONF" "config file failed to source (bash syntax error)" "fix the bash syntax in $CONF"
    cmd_status
    ;;
  watch)
    echo "coordinate.sh watch: not implemented in this phase — see coordinator-design.md" >&2
    exit 1
    ;;
  resume)
    echo "coordinate.sh resume: not implemented in this phase — see coordinator-design.md" >&2
    exit 1
    ;;
  "")
    usage; exit 2
    ;;
  *)
    echo "coordinate.sh: unknown subcommand: $SUBCMD" >&2; usage; exit 2
    ;;
esac
