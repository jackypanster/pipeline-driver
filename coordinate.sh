#!/usr/bin/env bash
# coordinate.sh — the read-only preflight + summary companion to drive.sh for the
# `pipeline` toolchain (design v1.3).
#
# WHAT IT IS: `doctor` (read-only full preflight) and `status` (read-only
# summary) are the COMPLETE surface — not a phase of something larger. The tool
# is stateless: it only reads the target repo's .pipeline/<feature>/
# artifacts (and, for doctor, the role panes). drive.sh owns the impl card loop.
#
# The dispatch half (`watch`/`resume`) was deliberately rejected: bash dispatch
# cannot satisfy the design without breaking drive.sh's interactive trust gate.
# PR #14 was closed unmerged: https://github.com/jackypanster/pipeline-driver/pull/14
# The pivot to coordinated-mode dispatch (the CC-as-coordinator playbook) is
# recorded in the design doc v1.3 §25, pinned at:
# https://github.com/jackypanster/pipeline-driver/blob/19e8c954/coordinator-design.md
# (PR #15 documented the pivot: https://github.com/jackypanster/pipeline-driver/pull/15).
#
# INVARIANTS (design §11 / §19): every config value is validated before use; a
# configured command prefix is DATA appended to a safely-constructed argv, never
# `eval`'d; target Git is read-only (fetch + `git show`, never a checked-out
# worktree); the coordinator excludes its OWN pane and proves lifecycle authority
# per pane.
#
# Usage:
#   coordinate.sh doctor --config <path>
#   coordinate.sh status --config <path>
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
# Herdr daemon would hang the whole pane section. Same bounded guard as agent explain.
PANE_LIST_TIMEOUT_MS="${COORD_PANE_LIST_TIMEOUT_MS:-5000}"

# ---- error model (design §14; drive.sh's where/input/reason/next_action) --------
# coord_die <code> <where> <input> <reason> <next_action>  — hard abort, exit 1.
coord_die() {
  printf '\n=== COORDINATOR FATAL ===\n'        >&2
  printf 'code:        %s\n' "$1"                >&2
  printf 'where:       %s\n' "$2"                >&2
  printf 'input:       %s\n' "$3"                >&2
  printf 'reason:      %s\n' "$4"                >&2
  printf 'next_action: %s\n' "$5"                >&2
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
# stderr/stdout or a redacted diagnostic string (§14 sanitized-input / §19). FILESYSTEM paths are
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
#   network:    net:<host[:port]/path>         userinfo + query/fragment + .git
#               stripped, host lowercased. https/ssh/scp forms of one remote agree;
#               an ssh:// port host:2222 stays distinct from a /2222 path segment.
#   filesystem: fs:<physical path>             the value is preserved EXACTLY (no
#               userinfo/query/fragment/.git stripping — '@', '?', '#' are legal
#               filename bytes; /srv/x and /srv/x.git are different repos) and
#               resolved against the DECLARING clone: `origin.git` in four clones
#               names four different repositories.
# Contract: this canonical form is used ONLY for equality comparison — never a key,
# path segment, or concatenated with another value. If that ever changes, reintroduce
# a length prefix (or an explicit unambiguous encoding) FIRST. The kind tag is chosen
# by classification, never taken from input. Classification runs on the RAW value
# BEFORE any stripping (finding: 'x@../shared' is a literal local path, not userinfo).
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
      printf 'fs:%s' "$v"
      ;;
    net-scheme)
      u=$(strip_userinfo "$raw"); u=${u#*://}; u=${u%.git}
      v=$(printf '%s' "$u" | awk -F/ 'BEGIN{OFS="/"} { $1=tolower($1); print }')
      printf 'net:%s' "$v"
      ;;
    net-scp)
      u=$(strip_userinfo "$raw")
      u=$(printf '%s' "$u" | sed -E 's#([^/]*):#\1/#')   # scp host:path -> host/path
      u=${u%.git}
      v=$(printf '%s' "$u" | awk -F/ 'BEGIN{OFS="/"} { $1=tolower($1); print }')
      printf 'net:%s' "$v"
      ;;
  esac
}

# resolve_path <path> — absolute, symlink-resolved (PHYSICAL). Resolves the longest
# EXISTING ancestor via perl Cwd::abs_path and re-appends the not-yet-created tail,
# so a path that does not exist yet still resolves to its intended physical
# location. Used for distinct-workdir checks so lexical tricks ("..", symlinks
# INTO a clone) cannot bypass physical isolation.
resolve_path() {
  local p=$1 base dir
  case "$p" in "") printf '%s' ""; return 0 ;; /*) ;; *) p="$PWD/$p" ;; esac
  base=$p
  while [ "$base" != "/" ] && [ ! -e "$base" ]; do base=$(dirname "$base"); done
  if [ "$base" = "/" ]; then
    # Nothing below / exists and / itself is never a symlink: the path IS its own
    # physical form — return it WHOLE. Truncating to '/' collapsed every distinct
    # nonexistent top-level path into one comparison identity (finding: preserve the
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

# valid_feature_slug <slug> — 0 iff <slug> is safe to interpolate into a `git show`
# path and diagnostic output. Rejects empty, '.', '..', any '/', leading
# '-', newline/tab/CR (grep is line-based, so an embedded newline would otherwise
# let a forged second line pass the allowlist), and anything outside
# [A-Za-z0-9._-] — so a malicious feature read from HEAD's current.json can never
# traverse the git-show path or inject forged output lines. (finding: slug.)
valid_feature_slug() {
  local s=$1
  [ -n "$s" ] || return 1
  case "$s" in -*|*/*|*".."*|*$'\n'*|*$'\t'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$s" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# ---- machine bindings (optional CC/IMPL/REVIEW _AGENT + _MODEL_EXPECT fields) ---
# Six OPTIONAL fields, set in the global defaults file, overridable per-config in
# coordinate.config (config wins — same precedence direction as drive.sh). All of
# this is ADDITIVE: an install with none of the fields behaves exactly as before
# (every field <unset>, zero new MISS).

# defaults_path — the global defaults file location, verbatim from drive.sh
# ($DRIVE_DEFAULTS overrides; the test harness pins it).
defaults_path() { printf '%s' "${DRIVE_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/pipeline-driver/drive.defaults}"; }

# valid_agent <value> — [A-Za-z0-9][A-Za-z0-9._-]*, ≤32 BYTES. Byte-exact and
# line-agnostic: the allowed byte class is deleted with LC_ALL=C tr and ZERO bytes
# may remain (an internal LF/CR/NUL/any control byte or any byte ≥0x80 ⇒ INVALID —
# never "each line validated separately"); the first byte must be alphanumeric.
# (No URLs/paths/control bytes can ever reach a diagnostic through these fields.)
valid_agent() {
  local v=$1 leftover
  [ -n "$v" ] || return 1
  [ "$(_byte_len "$v")" -le 32 ] || return 1
  # Bytes outside the class (incl. any LF/CR/control/≥0x80): NONE may remain.
  # Count BYTES, not string emptiness — $(...) strips trailing LFs, so an
  # emptiness test on the substituted text could never see a leftover that
  # consists only of newlines (the internal-LF bypass).
  leftover=$(printf '%s' "$v" | LC_ALL=C tr -d 'A-Za-z0-9._-' | wc -c | awk '{print $1}')
  [ "$leftover" = "0" ] || return 1
  case "$v" in [A-Za-z0-9]*) return 0 ;; *) return 1 ;; esac
}

# valid_model_expect <value> — printable ASCII ONLY (bytes 0x20–0x7E; internal
# spaces allowed): the class is deleted with LC_ALL=C tr and ZERO bytes may
# remain, so any control byte (LF, CR, TAB, 0x7F) or any byte ≥0x80 (0xff, any
# UTF-8 multibyte) ⇒ INVALID. No leading/trailing space (the only whitespace the
# class admits), non-empty, ≤64 BYTES. With LF impossible, a diagnostic echoing
# the value is single-line BY CONSTRUCTION and the footer matcher sees exactly ONE
# fixed string. (Empty means UNSET and is handled by the caller.) Matched as a
# LITERAL case-insensitive ASCII substring — never regex/glob.
valid_model_expect() {
  local v=$1 leftover
  [ -n "$v" ] || return 1
  [ "$(_byte_len "$v")" -le 64 ] || return 1
  # Same byte-count discipline as valid_agent (an LF-only leftover is invisible
  # to a $(...) emptiness test — count the bytes instead).
  leftover=$(printf '%s' "$v" | LC_ALL=C tr -d ' -~' | wc -c | awk '{print $1}')
  [ "$leftover" = "0" ] || return 1
  case "$v" in ' '*|*' ') return 1 ;; esac
  return 0
}

# binding_status <var> <agent|expect> — echoes: unset | ok | invalid.
binding_status() {
  local var=$1 kind=$2
  # NB: the indirect expansion MUST be its own statement — in bash 3.2 a single
  # `local var=$1 v="${!var:-}"` line evaluates the RHS before var is assigned.
  local v="${!var:-}"
  if [ -z "$v" ]; then printf 'unset'; return 0; fi
  case "$kind" in
    agent)  valid_agent "$v" ;;
    expect) valid_model_expect "$v" ;;
  esac && printf 'ok' || printf 'invalid'
}

# binding_token <var> <agent|expect> — the display token: the value, <unset>, or
# <invalid>. An INVALID value is never echoed (untrusted bytes stay out of output).
binding_token() {
  local var=$1 kind=$2
  case "$(binding_status "$var" "$kind")" in
    ok)      printf '%s' "${!var}" ;;
    unset)   printf '<unset>' ;;
    invalid) printf '<invalid>' ;;
  esac
}

# print_machine_bindings — the human-readable merged view (defaults file, then
# coordinate.config overrides), shared by cmd_doctor and cmd_status. impl
# transport / yolo come from the SAME merged view, display-only.
print_machine_bindings() {
  local df; df=$(defaults_path)
  printf -- '--- machine bindings (drive.defaults; coordinate.config overrides) --\n'
  if [ -f "$df" ]; then printf 'defaults file: %s\n' "$df"
  else printf 'defaults file: <absent> (cp drive.defaults.example — see README §Setup)\n'; fi
  printf '%-14s%-14s%-15s%s\n' "prd/arch/task" "(CC pane):"    "agent=$(binding_token CC_AGENT agent)"       "expect=$(binding_token CC_MODEL_EXPECT expect)"
  printf '%-14s%-14s%-15s%s\n' "impl"         "(PI pane):"    "agent=$(binding_token IMPL_AGENT agent)"     "expect=$(binding_token IMPL_MODEL_EXPECT expect)"
  printf '%-14s%-14s%-15s%s\n' "review"       "(CODEX pane):" "agent=$(binding_token REVIEW_AGENT agent)"   "expect=$(binding_token REVIEW_MODEL_EXPECT expect)"
  printf 'impl transport: %-9syolo: %s\n' "${IMPL_TRANSPORT:-<unset>}" "${YOLO:-<unset>}"
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

# ---- doctor (read-only full preflight; design §12/§24.2) -----------------------
cmd_doctor() {
  local bad=0 warn=0
  d_ok()   { printf 'ok    %s\n' "$1"; }
  d_info() { printf 'info  %s\n' "$1"; }
  d_warn() { printf 'warn  %s\n      %s\n' "$1" "$2"; warn=$((warn+1)); }
  d_miss() { printf 'MISS  %s\n      fix: %s\n' "$1" "$2"; bad=$((bad+1)); }
  # d_code <CODE> <where> <input> <reason> <next_action> — drive.sh d_miss shape
  # with the FULL §14 tuple (code/where/input/reason/next_action) so every MISS
  # stays locatable. (finding: §14 tuple.)
  d_code() {
    printf 'MISS  [%s] reason: %s
' "$1" "$4"
    printf '      where: %s | input: %s | next_action: %s
' \
      "$2" "$3" "$5"
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
    d_ok "config valid ($CONF): workdirs/remote/branch/commands all pass §11"
  fi
  # Runtime guard knobs (env): MUST be positive integers. ualarm(0) on a zero/
  # non-positive budget DISABLES the guard (finding: bounded knobs), so a wedged
  # Herdr daemon would hang preflight. Reject them up front AND skip every Herdr
  # read for the rest of this run — reporting the violation and then calling Herdr
  # with the same invalid budget would hang on a blocking leader (finding: invalid
  # budget still used; bounded_run_ms also self-guards as the backstop).
  local _k _v herdr_reads_ok=1
  for _k in AUTH_TIMEOUT_MS PANE_LIST_TIMEOUT_MS; do
    _v="${!_k:-}"
    if ! is_pos_int "$_v"; then
      d_code CONFIG_INVALID "doctor:config" "$_k=$_v" "$_k is not a positive integer (a zero/non-positive budget would disable the bounded-exec guard)" "unset $_k for the default, or set COORD_${_k} to a positive millisecond budget"
      herdr_reads_ok=0
    fi
  done

  # Machine bindings block (additive; merged defaults→config view). An INVALID
  # binding field is blocking HERE (doctor is the preflight); status prints the
  # same block with <invalid> and keeps going. Unset fields are never a MISS.
  print_machine_bindings
  local _bvar _bkind
  for _bvar in CC_AGENT CC_MODEL_EXPECT IMPL_AGENT IMPL_MODEL_EXPECT REVIEW_AGENT REVIEW_MODEL_EXPECT; do
    case "$_bvar" in *_AGENT) _bkind=agent ;; *) _bkind=expect ;; esac
    if [ "$(binding_status "$_bvar" "$_bkind")" = "invalid" ]; then
      case "$_bkind" in
        agent)  d_code CONFIG_INVALID "doctor:config" "$_bvar" "$_bvar must match [A-Za-z0-9][A-Za-z0-9._-]* and be at most 32 bytes (no control bytes, nothing ≥0x80)" "fix or unset $_bvar in $(defaults_path) or $CONF" ;;
        expect) d_code CONFIG_INVALID "doctor:config" "$_bvar" "$_bvar must be printable ASCII (bytes 0x20–0x7E, no control bytes, nothing ≥0x80), have no leading/trailing whitespace, and be at most 64 bytes" "fix or unset $_bvar in $(defaults_path) or $CONF" ;;
      esac
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
      d_info "skipping ALL Herdr reads: invalid guard budget (see the CONFIG_INVALID above) — no unbounded call is ever made"
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
    d_info "skipping remote/pane sections: one or more workdirs unusable (fix the config section above)"
  fi

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
  # Model verification (machine bindings): with the role's *_MODEL_EXPECT set and
  # valid, the live pane footer MUST contain it as a LITERAL case-insensitive
  # ASCII substring — the coordinator playbook's "read the pane footer" preflight
  # as a machine check (three roles on three models). FAIL CLOSED: EXPECT set
  # means verification is REQUIRED, so an unreadable footer is a MISS, never a
  # skip. The footer is pane-controlled output: only the EXPECTED value is ever
  # printed in a diagnostic, never the raw footer bytes (sanitized-diagnostics
  # discipline). The footer read reuses the existing single-pane-read budget
  # (AUTH_TIMEOUT_MS) — no new config field.
  local mvar mexp footer
  case "$role" in
    CC)    mvar=CC_MODEL_EXPECT ;;
    PI)    mvar=IMPL_MODEL_EXPECT ;;
    CODEX) mvar=REVIEW_MODEL_EXPECT ;;
  esac
  mexp="${!mvar:-}"
  if [ -z "$mexp" ]; then
    d_info "$role pane model: no *_MODEL_EXPECT set — skipping footer check"
  elif ! valid_model_expect "$mexp"; then
    d_info "$role pane model: $mvar invalid — skipping footer check (see the CONFIG_INVALID above)"
  else
    footer=$(bounded_run_ms "$AUTH_TIMEOUT_MS" herdr pane read "$pane" --source visible --lines 3 2>/dev/null) || footer=""
    if [ -z "$footer" ]; then
      d_code MODEL_MISMATCH "doctor:panes:$role" "$pane" "$role pane $pane model: footer unreadable — cannot verify expected model" "open the intended TUI/model in this pane, or update *_MODEL_EXPECT / coordinate.config"
    else
      # ASCII case-fold BOTH sides with LC_ALL=C tr (the expect is validated
      # printable ASCII), then ONE fixed-string match: grep -F -- so a leading
      # '-' is never an option, and a valid expect cannot contain LF, so the
      # newline-as-alternation hole is closed by construction.
      local footer_lc expect_lc
      footer_lc=$(printf '%s' "$footer" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      expect_lc=$(printf '%s' "$mexp" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      if printf '%s' "$footer_lc" | grep -Fq -- "$expect_lc"; then
        d_ok "$role pane model: footer matches expect '$mexp'"
      else
        d_code MODEL_MISMATCH "doctor:panes:$role" "$pane" "$role pane $pane model: footer does not contain expected '$mexp' (literal case-insensitive ASCII match)" "open the intended TUI/model in this pane, or update *_MODEL_EXPECT / coordinate.config"
      fi
    fi
  fi
}

# ---- status (read-only; design §12) -------------------------------------------
# stdout contract: EXACTLY one human line + one compact JSON object
# {"feature":<slug|null>}, nothing else. The machine-bindings block and any
# coord_die output go to STDERR so stdout never gains extra lines.
cmd_status() {
  validate_config || {
    # Decode the SAME tab tuple validate_config writes (CODE<TAB>input<TAB>reason)
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
  # The machine-bindings block is human-readable observability: it goes to STDERR
  # so stdout keeps its contract of exactly ONE human line + ONE JSON object.
  # Invalid optional fields print <invalid> and never abort this read-only summary.
  print_machine_bindings >&2
  # Discover the active feature from the observer's LOCAL HEAD ONLY (no fetch —
  # status never touches the network or mutates state). Best-effort: a missing or
  # unreadable current.json simply means idle.
  local cur feat=""
  cur=$(git -C "$OBSERVER_WORKDIR" show "HEAD:.pipeline/current.json" 2>/dev/null) || cur=""
  if [ -n "$cur" ]; then feat=$(printf '%s' "$cur" | jq -r '.feature // empty' 2>/dev/null) || feat=""; fi
  # The feature slug is UNTRUSTED (read from HEAD's current.json) and is echoed in
  # output — validate it BEFORE any use so a malicious slug ('..', '/', newline +
  # forged text) can neither traverse nor inject. (finding: feature slug.)
  if [ -n "$feat" ] && ! valid_feature_slug "$feat"; then
    coord_die CONFIG_INVALID "status:feature" "<redacted-slug>" \
      "feature slug from current.json is malformed or unsafe (must be a simple name [A-Za-z0-9][A-Za-z0-9._-]*)" \
      "inspect .pipeline/current.json on HEAD in $OBSERVER_WORKDIR; do NOT pass the raw value to any path"
  fi

  if [ -n "$feat" ]; then
    printf 'coordinate: feature=%s (from HEAD current.json)\n' "$feat"
  else
    printf 'coordinate: idle (no active feature)\n'
  fi
  # One compact JSON object — the ONLY other stdout line. n() coerces an empty
  # slug to null, so an idle repo prints {"feature":null}.
  jq -nc --arg feat "$feat" 'def n(e): if (e|length) > 0 then e else null end; {feature:n($feat)}'
}

# ---- arg dispatch --------------------------------------------------------------
usage() {
  cat >&2 <<EOF
usage: coordinate.sh <subcommand> --config <path>

subcommands:
  doctor   read-only full preflight (deps / config / remote / journal / panes / authority)
  status   read-only summary: active feature from HEAD current.json (one human line + one JSON object)
EOF
}

SUBCMD="${1:-}"; shift || true
CONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || { echo "coordinate.sh: --config needs a path" >&2; exit 2; }; CONF=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "coordinate.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$SUBCMD" in
  doctor)
    [ -n "$CONF" ] || { echo "coordinate.sh: doctor requires --config <path>" >&2; usage; exit 2; }
    [ -f "$CONF" ] || coord_die CONFIG_INVALID "doctor:arg-parse" "$CONF" "config file not found" "create it from coordinate.config.example"
    # Global defaults first (optional), per-invocation config second — config wins.
    # Same path expression + precedence direction as drive.sh; any unrelated
    # variable the defaults file sets flows into validate_config unchanged.
    DEFAULTS="$(defaults_path)"
    # shellcheck disable=SC1090
    [ -f "$DEFAULTS" ] && . "$DEFAULTS"
    # shellcheck disable=SC1090
    . "$CONF" || coord_die CONFIG_INVALID "doctor:load_config" "$CONF" "config file failed to source (bash syntax error)" "fix the bash syntax in $CONF"
    cmd_doctor
    ;;
  status)
    [ -n "$CONF" ] || { echo "coordinate.sh: status requires --config <path>" >&2; usage; exit 2; }
    [ -f "$CONF" ] || coord_die CONFIG_INVALID "status:arg-parse" "$CONF" "config file not found" "create it from coordinate.config.example"
    # Global defaults first (optional), per-invocation config second — config wins.
    DEFAULTS="$(defaults_path)"
    # shellcheck disable=SC1090
    [ -f "$DEFAULTS" ] && . "$DEFAULTS"
    # shellcheck disable=SC1090
    . "$CONF" || coord_die CONFIG_INVALID "status:load_config" "$CONF" "config file failed to source (bash syntax error)" "fix the bash syntax in $CONF"
    cmd_status
    ;;
  "")
    usage; exit 2
    ;;
  *)
    echo "coordinate.sh: unknown subcommand: $SUBCMD" >&2; usage; exit 2
    ;;
esac
