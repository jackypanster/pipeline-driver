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
# redact_remote <url>: strip credential userinfo (user[:password]@) from a remote
# URL for SAFE display. Keeps the scheme. Used on EVERY diagnostic/output path so a
# secret embedded as https://alice:ghp_SECRET@host/... can never reach stderr/
# stdout or a derived key (§14 sanitized-input / §19; finding: credential sanitize).
redact_remote() {
  printf '%s' "$1" | sed -E 's#(^[a-zA-Z][a-zA-Z0-9+.-]*://)?[A-Za-z0-9._~%+-]+(:[^@/]*)?@#\1#'
}

# normalize_remote <url>: map https / ssh / scp-like forms of the SAME remote to
# ONE canonical key — scheme-stripped, userinfo-stripped FIRST, .git-stripped,
# scp-colon -> /, host lowercased; path case preserved. Credential stripping runs
# before everything else so the derived §13 repo key never carries a secret.
# Verified forms:
#   https://alice:secret@github.com/acme/x.git   ssh://git@github.com/acme/x.git
#   git@github.com:acme/x.git                     https://github.com/acme/x
# all -> github.com/acme/x
normalize_remote() {
  printf '%s' "$1" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[A-Za-z0-9._~%+-]+(:[^@/]*)?@##; s#\.git$##; s#([^/]*):#\1/#' \
    | awk -F/ 'BEGIN{OFS="/"} { $1=tolower($1); print }'
}

# repo_key_from <workdir> — single-segment, COLLISION-SAFE key from origin.url.
# The normalized identity is percent-encoded (jq @uri) so structural separators are
# preserved: github.com/a/b_c and github.com/a_b/c map to DIFFERENT keys (finding:
# collision-safe key). Empty on failure.
repo_key_from() {
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || url=""
  [ -n "$url" ] || return 1
  normalize_remote "$url" | jq -rR '@uri'
}

state_root() {
  if [ -n "${STATE_DIR:-}" ]; then printf '%s' "$STATE_DIR"
  else printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/pipeline-driver"; fi
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
    $armed = 0; ualarm(0);        # disarm: the leader exited of its own accord
    $drain->();                   # but a descendant may still hold stdout
    exit $rc;
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
# Appends "CODE: message" lines to CFG_V[] and sets CFG_BAD=1 on any violation.
# Runs EVERY check (does not short-circuit) so doctor can report the full list.
CFG_V=(); CFG_BAD=0
cfg_violation() { CFG_V+=("$1: $2"); CFG_BAD=1; }

validate_config() {
  CFG_V=(); CFG_BAD=0
  local wdvar wd url norm i ok_abs
  # 1. workdirs: absolute, existing git clones.
  for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    wd="${!wdvar:-}"
    if [ -z "$wd" ]; then cfg_violation CONFIG_INVALID "$wdvar is unset"; continue; fi
    case "$wd" in /*) ;; *) cfg_violation WORKDIR_INVALID "$wdvar not absolute: $wd"; continue ;; esac
    if [ ! -d "$wd" ]; then cfg_violation WORKDIR_INVALID "$wdvar does not exist: $wd"; continue; fi
    if ! git -C "$wd" rev-parse --git-dir >/dev/null 2>&1; then
      cfg_violation WORKDIR_INVALID "$wdvar is not a git clone: $wd"; continue; fi
  done
  # 2. remote-identity agreement across all four clones that resolved above.
  norm=""; ok_abs=1
  for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
    wd="${!wdvar:-}"
    case "$wd" in /*) ;; *) ok_abs=0 ;; esac
    [ -d "$wd" ] || ok_abs=0
    git -C "$wd" rev-parse --git-dir >/dev/null 2>&1 || ok_abs=0
    if [ "$ok_abs" = "1" ]; then
      url=$(git -C "$wd" config --get remote.origin.url 2>/dev/null) || url=""
      if [ -z "$url" ]; then cfg_violation WORKDIR_INVALID "$wdvar has no remote.origin.url"
      elif [ -z "$norm" ]; then norm=$(normalize_remote "$url")
      elif [ "$(normalize_remote "$url")" != "$norm" ]; then
        cfg_violation REMOTE_MISMATCH "$wdvar remote ($(redact_remote "$url")) != observer ($norm)"
      fi
    fi
  done
  # 3. BRANCH non-empty.
  [ -n "${BRANCH:-}" ] || cfg_violation CONFIG_INVALID "BRANCH is unset"
  # 4. command prefixes: non-empty, single-line (no embedded newline).
  local cmdvar
  for cmdvar in CC_ARCH_CMD CC_TASK_CMD CC_HUNT_CMD PI_IMPL_CMD CODEX_REVIEW_CMD; do
    wd="${!cmdvar:-}"   # reuse varname slot for the VALUE
    if [ -z "$wd" ]; then cfg_violation CONFIG_INVALID "$cmdvar is unset"; continue; fi
    case "$wd" in *$'\n'*) cfg_violation CONFIG_INVALID "$cmdvar spans multiple lines" ;; esac
  done
  # 5. optional pane IDs: single-line opaque, non-empty (when set).
  for cmdvar in CC_PANE_ID PI_PANE_ID CODEX_PANE_ID; do
    wd="${!cmdvar:-}"
    [ -z "$wd" ] && continue
    case "$wd" in *$'\n'*) cfg_violation CONFIG_INVALID "$cmdvar spans multiple lines" ;; esac
  done
  # 6. timeouts: positive base-10 ints within documented upper bounds.
  if ! is_pos_int "${POLL_SECS:-0}"; then cfg_violation CONFIG_INVALID "POLL_SECS not a positive integer"
  elif [ "${POLL_SECS:-0}" -gt "$POLL_SECS_MAX" ]; then cfg_violation CONFIG_INVALID "POLL_SECS exceeds $POLL_SECS_MAX"; fi
  if ! is_pos_int "${PANE_READY_TIMEOUT_MS:-0}"; then cfg_violation CONFIG_INVALID "PANE_READY_TIMEOUT_MS not a positive integer"
  elif [ "${PANE_READY_TIMEOUT_MS:-0}" -gt "$PANE_READY_TIMEOUT_MS_MAX" ]; then cfg_violation CONFIG_INVALID "PANE_READY_TIMEOUT_MS exceeds $PANE_READY_TIMEOUT_MS_MAX"; fi
  if ! is_pos_int "${STAGE_TIMEOUT_SECS:-0}"; then cfg_violation CONFIG_INVALID "STAGE_TIMEOUT_SECS not a positive integer"
  elif [ "${STAGE_TIMEOUT_SECS:-0}" -gt "$STAGE_TIMEOUT_SECS_MAX" ]; then cfg_violation CONFIG_INVALID "STAGE_TIMEOUT_SECS exceeds $STAGE_TIMEOUT_SECS_MAX"; fi
  # 7. ON_HALT_EXEC (if set): absolute, executable, regular file, NOT a symlink.
  if [ -n "${ON_HALT_EXEC:-}" ]; then
    case "$ON_HALT_EXEC" in /*) ;; *) cfg_violation CONFIG_INVALID "ON_HALT_EXEC not absolute: $ON_HALT_EXEC" ;;
    esac
    if [ -L "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC is a symlink: $ON_HALT_EXEC"
    elif [ ! -f "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC not a regular file: $ON_HALT_EXEC"
    elif [ ! -x "$ON_HALT_EXEC" ]; then cfg_violation CONFIG_INVALID "ON_HALT_EXEC not executable: $ON_HALT_EXEC"
    fi
  fi
  # 8. STATE_DIR (if set): outside EVERY configured clone.
  if [ -n "${STATE_DIR:-}" ]; then
    case "$STATE_DIR" in /*) ;; *) cfg_violation CONFIG_INVALID "STATE_DIR not absolute: $STATE_DIR" ;; esac
    for wdvar in OBSERVER_WORKDIR CC_WORKDIR PI_WORKDIR CODEX_WORKDIR; do
      wd="${!wdvar:-}"
      [ -z "$wd" ] && continue
      case "$STATE_DIR" in
        "$wd"|"$wd"/*) cfg_violation CONFIG_INVALID "STATE_DIR ($STATE_DIR) is inside $wdvar ($wd)" ;;
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
  # d_code <CODE> <label> <fix> — drive.sh d_miss shape, with the §14 code surfaced
  # so a caller can match the exact failure (the handoff's break-one-prereq cases).
  d_code() { printf 'MISS  [%s] %s\n      fix: %s\n' "$1" "$2" "$3"; bad=$((bad+1)); }

  printf -- '--- deps ----------------------------------------------------------\n'
  if   command -v git   >/dev/null 2>&1; then d_ok "git on PATH"
  else d_code DEPENDENCY_MISSING "git not on PATH" "install git (xcode-select --install / package manager)"; fi
  if   command -v jq    >/dev/null 2>&1; then d_ok "jq on PATH"
  else d_code DEPENDENCY_MISSING "jq not on PATH" "brew install jq"; fi
  if   command -v herdr >/dev/null 2>&1; then d_ok "herdr on PATH"
  else d_code DEPENDENCY_MISSING "herdr not on PATH" "install Herdr (https://herdr.dev)"; fi
  if   command -v perl  >/dev/null 2>&1; then d_ok "perl on PATH (bounded exec + authority timeout)"
  else d_code DEPENDENCY_MISSING "perl not on PATH" "install perl (base system package on macOS/Linux)"; fi

  printf -- '--- config --------------------------------------------------------\n'
  validate_config || true
  if [ "${CFG_BAD:-0}" = "1" ]; then
    local v
    for v in "${CFG_V[@]}"; do d_code "${v%%:*}" "${v#*: }" "edit $CONF (coordinate.config.example documents each rule)"; done
  else
    d_ok "config valid ($CONF): workdirs/remote/branch/commands/timeouts all pass §11"
  fi

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
    [ -n "$rkey" ] && d_ok "normalized repo key: $rkey" || d_code REMOTE_MISMATCH "observer has no remote.origin.url" "git -C $OBSERVER_WORKDIR remote add origin <url>"

    printf -- '--- observed remote trunk (fetch + git show) ----------------------\n'
    local fetch_ok=0 observed_commit=""
    if git -C "$OBSERVER_WORKDIR" fetch origin --quiet 2>/dev/null; then
      d_ok "git fetch origin ($OBSERVER_WORKDIR)"; fetch_ok=1
    else
      d_code GIT_FETCH_FAILED "git fetch origin failed in $OBSERVER_WORKDIR" "check network / remote access / auth from $OBSERVER_WORKDIR"
    fi
    if [ "$fetch_ok" = "1" ]; then
      if git -C "$OBSERVER_WORKDIR" rev-parse --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
        observed_commit=$(git -C "$OBSERVER_WORKDIR" rev-parse "origin/$BRANCH")
        d_ok "origin/$BRANCH resolves -> ${observed_commit:0:12}"
      else
        d_code REMOTE_REF_MISSING "origin/$BRANCH missing after fetch" "confirm BRANCH=$BRANCH matches the remote trunk"
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
        [ -n "$FEATURE" ] && d_ok "active feature: $FEATURE" || d_info "current.json carries no .feature (human mode / idle)"
      fi

      if [ -n "$FEATURE" ]; then
        CTL=$(show_remote ".pipeline/$FEATURE/control.json") || CTL=""
        if [ -z "$CTL" ]; then
          d_info "no control.json (human mode — feature observed but never dispatched)"
        elif printf '%s' "$CTL" | jq -e '.schema_version == 1 and (.mode == "human" or .mode == "coordinated") and .merge_gate == "human-direct"' >/dev/null 2>&1; then
          d_ok "control.json valid (mode=$(printf '%s' "$CTL" | jq -r .mode))"
        else
          d_code CONTROL_MALFORMED "control.json malformed or violates schema (schema_version/mode/merge_gate)" "inspect .pipeline/$FEATURE/control.json on origin/$BRANCH"
        fi

        J=$(show_remote ".pipeline/$FEATURE/journal.md") || J=""
        if [ -z "$J" ]; then
          d_warn "no journal.md for $FEATURE on origin/$BRANCH" "feature may be pre-first-commit"
        else
          local SEQ="" STATUS="" FROM="" TO="" NEXT="" NEXT_KIND="" PARSE_ERR=""
          # shellcheck disable=SC1090
          eval "$(printf '%s' "$J" | awk -f "$AWK" 2>/dev/null)"
          case "${PARSE_ERR:-}" in
            malformed-header) d_code JOURNAL_MALFORMED "journal tail header malformed (seq/status/to incomplete)" "inspect the tail entry of .pipeline/$FEATURE/journal.md on origin/$BRANCH" ;;
            no-entries)       d_warn "journal has no entries yet" "feature is pre-first-commit" ;;
            "")               d_ok "journal tail: SEQ=$SEQ STATUS=$STATUS FROM=$FROM TO=$TO NEXT=${NEXT:-<empty>} NEXT_KIND=${NEXT_KIND:-<none>}" ;;
          esac
        fi
      fi
    fi

    printf -- '--- role panes (herdr) --------------------------------------------\n'
    local panes_json=""
    panes_json=$(bounded_run_ms "$PANE_LIST_TIMEOUT_MS" herdr pane list 2>/dev/null) || panes_json=""
    if [ -z "$panes_json" ] || ! printf '%s' "$panes_json" | jq -e . >/dev/null 2>&1; then
      d_code DEPENDENCY_MISSING "'herdr pane list' returned no JSON" "is Herdr running? (herdr status; socket: ~/.config/herdr/herdr.sock)"
    else
      d_ok "herdr pane list reachable ($(printf '%s' "$panes_json" | jq '.result.panes | length') panes)"
      coord_check_role "CC"    "$CC_WORKDIR"    "${CC_PANE_ID:-}"
      coord_check_role "PI"    "$PI_WORKDIR"    "${PI_PANE_ID:-}"
      coord_check_role "CODEX" "$CODEX_WORKDIR" "${CODEX_PANE_ID:-}"
    fi
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
    d_code "$RES_CODE" "$role pane: $RES_MSG" "see coordinate.config.example (${role}_PANE_ID / role clone cwd)"
    return
  fi
  auth=$(authority_of "$pane" "$AUTH_TIMEOUT_MS")
  if [ "$auth" = "1" ]; then
    d_ok "$role pane lifecycle authority: confirmed (hook/matched-rule, no idle fallback)"
  else
    d_code AGENT_STATUS_INVALID "$role pane $pane: agent status source NOT authoritative (no lifecycle hook / no MATCHED manifest rule — always-idle fallback)" "attach that agent's Herdr integration, or pin to a pane with hook authority (design §24.2)"
  fi
}

# coord_doctor_state — state root existence/permissions, ledger integrity, lock, halt.
coord_doctor_state() {
  local root rkey repodir
  root=$(state_root)
  rkey=$(repo_key_from "$OBSERVER_WORKDIR" 2>/dev/null) || rkey=""
  repodir="$root/${rkey:-<unknown>}"
  if [ ! -d "$root" ]; then
    d_info "state root not created yet: $root (created 0700 on first write; design §13)"
    return
  fi
  d_ok "state root exists: $root"
  if [ -d "$repodir" ]; then
    local perm; perm=$(stat_perms "$repodir" 2>/dev/null)
    [ "$perm" = "700" ] && d_ok "repo state dir 0700: $repodir" || d_warn "repo state dir not 0700 ($perm): $repodir" "chmod 700 $repodir"
    # halt.json (unresolved halt blocks watch; resume is the only bypass).
    local haltf
    haltf=$(find "$repodir" -name halt.json -type f 2>/dev/null | head -1)
    if [ -n "$haltf" ]; then
      local code; code=$(jq -r '.code // "HALTED"' "$haltf" 2>/dev/null || echo HALTED)
      d_warn "unresolved halt.json present ($code): $haltf" "inspect it, then `coordinate.sh resume --config $CONF --reason <text>` (not implemented this phase)"
    fi
    # lock dir (held = a watch is running; stale = dead PID, resume clears it).
    local lockd
    lockd=$(find "$repodir" -type d -name lock 2>/dev/null | head -1)
    if [ -n "$lockd" ]; then
      local pidf="" pid="" st="held"
      pidf=$(find "$lockd" -type f 2>/dev/null | head -1)
      [ -n "$pidf" ] && pid=$(cat "$pidf" 2>/dev/null || echo "")
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then st="stale"; fi
      d_warn "watch lock present ($st): $lockd" $([ "$st" = stale ] && echo "resume clears a stale lock after preflight" || echo "a watch is running — that is expected")
    fi
    # ledger.json integrity (if present for any feature).
    local led ffeat lerr=""
    for led in $(find "$repodir" -name ledger.json -type f 2>/dev/null); do
      ffeat=$(basename "$(dirname "$led")")
      if lerr=$(jq -e . "$led" 2>&1 >/dev/null); then
        d_ok "ledger.json valid ($ffeat)"
      else
        d_code LEDGER_CORRUPT "ledger.json unreadable ($ffeat): ${lerr:-not JSON}" "inspect $led; remove only after confirming no dispatch is in flight"
      fi
    done
  else
    d_info "no state for repo key ${rkey:-<unknown>} (idle)"
  fi
}

# ---- status (read-only; design §12) -------------------------------------------
cmd_status() {
  validate_config || {
    local first="${CFG_V[0]:-CONFIG_INVALID: unknown}"
    coord_die "${first%%:*}" "status:validate_config" "$CONF" "${first#*: }" "edit $CONF (coordinate.config.example)"
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
# Internal test hooks (double-underscore, hidden from usage). They bypass --config
# arg-parsing so coordinate.sh's pure helpers are exercisable by the regression
# suite without a full config / Herdr topology. NOT a public API.
case "$SUBCMD" in
  __repo-key)    repo_key_from "$1"; exit $? ;;   # <workdir> -> collision-safe key
  __bounded-run) bounded_run_ms "$@"; exit $? ;;  # <ms> <cmd...> -> bounded exec
esac
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
