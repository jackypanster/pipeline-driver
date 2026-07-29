#!/usr/bin/env bash
# drive.sh — the deterministic impl-loop driver for the `pipeline` toolchain.
#
# WHAT IT IS: a forbidden-to-be-smart code loop that auto-advances ONLY the
# pipeline-impl multi-card loop and HALTS at every contract gate. It holds ZERO
# authoritative state — the target repo's .pipeline/<feature>/journal.md on the
# remote is the single source of truth. It is the write-side twin of the read-only
# pipeline-dashboard: an OPTIONAL external driver above an UNCHANGED contract.
#
# THE TWO GATES IT PRESERVES (never crosses):
#   GATE 1 (before the loop): the frozen red test is read + its spec-rev echoed.
#     WHO reads is the operator's risk-tier policy (README §For agents) — this
#     script only enforces the read-then-bind ritual on a TTY.
#   GATE 2 (after the loop):  pipeline-review — semantic review + the explicit
#     HUMAN merge confirm (never delegated). The driver never merges.
#
# HALT PREDICATE (the whole brain — normative statement + halt table: stop-points.md):
#     CONTINUE iff NEXT == impl AND STATUS != blocked
#                  AND (FROM != review OR the rejection seq was ACKed at the REJECTION GATE)
#                  AND LIVE_SPEC_REV == CONFIRMED_SPEC_REV
# Anything else halts and tells you exactly what to run next. FROM == review is a
# review REJECTION (a human semantic decision): the REJECTION GATE demands the same
# read-then-bind ritual as GATE 1 (type the rejection seq after reading reviews/*) —
# EOF/mismatch halts; the ack is per-invocation, in-process only. The spec-rev clause
# both authorizes the first card AND auto-halts on any re-freeze (a new spec-rev the
# human has not re-read), re-firing GATE 1.
#
# Usage:  ./drive.sh [path/to/drive.config]      (defaults to ./drive.config)
#         ./drive.sh doctor [path/to/drive.config]
#                    — install/config diagnosis for the pipeline+dashboard+driver
#                      trio: prints one line per check with the exact remediation
#                      command; installs nothing, touches no network.
#
# CONFIG LAYERING: an optional global defaults file
# (${XDG_CONFIG_HOME:-~/.config}/pipeline-driver/drive.defaults, see
# drive.defaults.example) is sourced BEFORE the per-feature drive.config, so
# stable cross-feature preferences live in one place and drive.config always
# wins. Override the path with $DRIVE_DEFAULTS (tests use this to stay hermetic).
#
# IMPL TRANSPORT: IMPL_TRANSPORT=claude (default) spawns a headless `claude` child
# per card. IMPL_TRANSPORT=herdr instead sends "$IMPL_SLASH_CMD …" into a live coder
# TUI (e.g. pi running GLM) in a Herdr pane and polls origin/<BRANCH> until the
# journal seq advances (or CARD_TIMEOUT): `herdr pane run` (atomic text+Enter), a
# read-first {done,idle} status guard, and a fail-closed check that the pane's agent
# state is authoritative (hook/manifest, never the always-idle fallback). Same halt
# predicate, gates and guards both ways — only the "run one card" primitive changes.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/parse-tail.awk"

SUBCMD=""
case "${1:-}" in doctor) SUBCMD=doctor; shift ;; esac
CONF="${1:-$HERE/drive.config}"
if [ "$SUBCMD" != "doctor" ]; then
  [ -f "$CONF" ] || { echo "drive.sh: config not found: $CONF" >&2; exit 2; }
fi
# Herdr injects HERDR_PANE_ID (among other HERDR_*) into EVERY pane it manages —
# including the one running this driver. Inheriting it would silently point the impl
# dispatch at the driver's own pane. Config-file-only: SAVE the inherited value as
# "the pane running THIS driver" so discovery can EXCLUDE it (a driver launched
# inside the target worktree would otherwise be a discovery candidate and type the
# stage command into itself) and a pinned target equal to it can be rejected, then
# drop it before sourcing.
DRIVER_SELF_PANE="${HERDR_PANE_ID:-}"
unset HERDR_PANE_ID 2>/dev/null || true
# Global defaults first (optional), per-feature config second — drive.config wins.
DEFAULTS="${DRIVE_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/pipeline-driver/drive.defaults}"
# shellcheck disable=SC1090
[ -f "$DEFAULTS" ] && . "$DEFAULTS"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# ---- config defaults ----------------------------------------------------------
if [ "$SUBCMD" != "doctor" ]; then   # doctor diagnoses a missing config instead of dying on it
  : "${WORKDIR:?set WORKDIR (a local clone of the target repo) in drive.config}"
  : "${BRANCH:?set BRANCH (trunk, e.g. main/master) in drive.config}"
  : "${FEATURE:?set FEATURE (the .pipeline/<feature> name) in drive.config}"
fi
IMPL_MODEL="${IMPL_MODEL:-haiku}"
MAX_CONSEC_FAIL="${MAX_CONSEC_FAIL:-2}"
RETRY_ON_FAIL="${RETRY_ON_FAIL:-1}"
SETTINGS_TMPL="${SETTINGS:-$HERE/settings.driver.json}"
IMPL_TRANSPORT="${IMPL_TRANSPORT:-claude}"          # claude | herdr (see header)
HERDR_PANE_ID="${HERDR_PANE_ID:-}"                  # explicit w1:p1 pane id (wins over discovery; never the driver's own pane)
HERDR_PANE_CWD_MATCH="${HERDR_PANE_CWD_MATCH:-}"    # cwd substring filter REPLACING the ==WORKDIR match (e.g. TUI opened in a subdir)
HERDR_IDLE_TIMEOUT_MS="${HERDR_IDLE_TIMEOUT_MS:-60000}"
HERDR_RESET_CMD="${HERDR_RESET_CMD:-}"              # optional per-card TUI reset (e.g. /new on pi); empty = off
HERDR_RESET_SETTLE_MS="${HERDR_RESET_SETTLE_MS:-2000}"  # post-reset window to observe the TUI taking the reset before re-guarding
IMPL_SLASH_CMD="${IMPL_SLASH_CMD:-/pipeline-impl}"  # stage command typed into the TUI (pi registers skills as /skill:pipeline-impl)
CARD_TIMEOUT="${CARD_TIMEOUT:-2700}"                # herdr transport: max seconds to wait for one card
POLL_SECS="${POLL_SECS:-30}"                        # herdr transport: journal poll interval
# YOLO=1 records the operator's STANDING ex-ante grant for LOW-RISK drive features
# (README §YOLO): the coordinating agent may read the frozen spec and echo the
# spec-rev at GATE 1 without a fresh chat authorization. It does NOT auto-start
# drive (still explicit per feature), never touches the merge confirm, and
# DANGEROUS features never use the driver at all.
YOLO="${YOLO:-0}"
# Sibling-repo locations, used by `drive.sh doctor` (pipeline README canonical layout).
PIPELINE_REPO="${PIPELINE_REPO:-$HOME/workspace/pipeline}"
DASHBOARD_REPO="${DASHBOARD_REPO:-$HOME/workspace/pipeline-dashboard}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.agents/skills}"
# Where the TUI-transport agent (herdr; e.g. pi) loads skills from — doctor
# checks the impl slot resolves THERE, since that is the runtime that runs the stage.
TUI_SKILLS_DIR="${TUI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
# Runtime skill dirs (space-separated) that `drive.sh doctor` sweeps for stale
# pipeline-* mounts — each entry must resolve to / match $SKILLS_DIR/<name>. Empty
# = info-skip (never blocking). See drive.defaults.example for the full semantics.
SKILL_MOUNTS="${SKILL_MOUNTS:-}"
# Board auto-refresh: non-empty BOARD_OUT re-renders the read-only dashboard there
# after GATE 1, after every advanced card, and on halt. Best-effort side effect —
# a render failure never halts the loop.
BOARD_OUT="${BOARD_OUT:-}"
# Walk-away notify hook: non-empty NOTIFY_EXEC names an ABSOLUTE-path executable
# invoked best-effort at the same three moments as BOARD_OUT — after GATE 1, after
# every advanced card, and on every halt — event name in $1 (gate1|card|halt),
# context in DRIVE_* env (README §Board & walk-away notify). Canonical adapter:
# pipeline-dispatch/notify.sh (Hermes -> Telegram). Config is validated fail-loud
# at preflight (the operator walks away trusting these pings, so a broken notifier
# must stop the run BEFORE GATE 1, not silently never fire); runtime failures warn
# once and never halt the loop. One-way: nothing flows from the notifier back in.
NOTIFY_EXEC="${NOTIFY_EXEC:-}"
# Hard deadline (ms) per notifier invocation. A wedged or TERM-immune send is killed
# — its WHOLE process group, via perl setpgrp (TERM then KILL) — and degrades to a
# single warn, so it can never suppress GATE 1, card progress, or the halt banner.
# NOTIFY_TIMEOUT_MS is a BOUNDED POSITIVE INTEGER, validated at preflight: it flows
# into arithmetic on the halt() path, so a non-integer (e.g. 1.5) must fail loud
# BEFORE GATE 1 instead of raising an error inside halt() that skips the banner+exit.
NOTIFY_TIMEOUT_MS="${NOTIFY_TIMEOUT_MS:-5000}"
# The notifier is a TRUSTED executable that runs as YOUR user. `env -i` only drops
# INHERITED environment variables — it is NOT an OS sandbox: the hook keeps normal
# filesystem/process/network access. By default it receives ONLY PATH + HOME + the
# DRIVE_* context; ambient exports (GH_TOKEN, ANTHROPIC_*, the var named by
# IMPL_AUTH_TOKEN_ENV) are NOT inherited. NOTIFY_ENV_ALLOW opts further names in.
NOTIFY_ENV_ALLOW="${NOTIFY_ENV_ALLOW:-}"   # opt-in: space-separated NAMES forwarded to the notifier
NOTIFY_READY=""                             # armed only after preflight validates path + timeout + perl
JOURNAL=".pipeline/${FEATURE:-}/journal.md"
TASKS=".pipeline/${FEATURE:-}/tasks"

halt_banner() { printf '\n=== DRIVER HALT ===\n%s\nNEXT (human): %s\n' "$1" "$2" >&2; }
halt() { # <reason> <what-the-human-should-run-next> [exit-code]
  render_board   # the last board reflects the halt state (best-effort no-op when off)
  notify_hook halt "$1" "$2"   # ping fires before the banner: the walked-away operator is the audience
  halt_banner "$1" "$2"
  exit "${3:-0}"
}
note() { printf '%s\n' "$*" >&2; }

# Re-render the read-only dashboard (BOARD_OUT non-empty = on). Never fails the
# caller; complains at most once per run.
render_board() {
  [ -n "${BOARD_OUT:-}" ] || return 0
  if ! command -v node >/dev/null 2>&1 || [ ! -f "${DASHBOARD_REPO:-}/dist/cli.js" ]; then
    [ -n "${BOARD_WARNED:-}" ] || note "board: need node + a built $DASHBOARD_REPO/dist/cli.js — BOARD_OUT disabled this run (drive.sh doctor)"
    BOARD_WARNED=1; return 0
  fi
  if node "$DASHBOARD_REPO/dist/cli.js" "$WORKDIR" --out "$BOARD_OUT" >/dev/null 2>&1; then :
  else
    [ -n "${BOARD_WARNED:-}" ] || note "board: render failed (non-fatal) — check: node $DASHBOARD_REPO/dist/cli.js $WORKDIR --out $BOARD_OUT"
    BOARD_WARNED=1
  fi
  return 0
}

# Invoke the external notifier (NOTIFY_EXEC non-empty AND armed = on): event name
# in $1, context in DRIVE_* env. The NOTIFY_READY gate is load-bearing: it stays
# inert until preflight has validated the path, so a halt() fired DURING preflight
# (e.g. the transport check) can never invoke an unvalidated/relative NOTIFY_EXEC
# via PATH (field-found: NOTIFY_EXEC=touch created ./halt from the transport halt).
# Best-effort side effect, same posture as render_board: never fails the caller.
notify_hook() {   # <event> [halt-reason] [halt-next-step]
  [ "$NOTIFY_READY" = "1" ] && [ -n "${NOTIFY_EXEC:-}" ] || return 0
  run_notify "$NOTIFY_EXEC" "$@"
}

# Run the notifier under a hard deadline (NOTIFY_TIMEOUT_MS), stdin from /dev/null,
# and a reduced environment — best-effort, never fails the caller; warns at most once
# per run. The deadline kills the notifier's WHOLE process group (perl setpgrp —
# REQUIRED and preflight-checked, since macOS has no setsid/timeout and a
# direct-child-only kill would leave descendants running), so a wedged or TERM-immune
# send cannot suppress GATE 1, card progress, or the halt banner. rc>=128 means the
# deadline killed the notifier (TERM then KILL).
#
# NOT A SANDBOX: `env -i` drops INHERITED environment variables only. The notifier is
# a TRUSTED executable that still runs as YOUR user with normal filesystem/process/
# network access (it can read files under HOME, write DRIVE_WORKDIR, or run tools on
# PATH). The reduced env + NOTIFY_ENV_ALLOW allowlist are defense-in-depth for the
# common "don't leak GH_TOKEN/ANTHROPIC_* by accident" case, NOT a credential or OS
# isolation boundary. NOTIFY_EXEC must be trusted.
run_notify() {   # <exec-path> <event> [halt-reason] [halt-next-step]
  local exec="$1"; shift
  local event="$1" reason="${2:-}" hnext="${3:-}" rc=0 nm val
  local -a envv=( env -i "PATH=$PATH" )
  if [ -n "${HOME:-}" ]; then envv+=( "HOME=$HOME" ); fi
  envv+=(
    "DRIVE_EVENT=$event"
    "DRIVE_FEATURE=${FEATURE:-}" "DRIVE_BRANCH=${BRANCH:-}" "DRIVE_WORKDIR=${WORKDIR:-}"
    "DRIVE_TRANSPORT=${IMPL_TRANSPORT:-}" "DRIVE_SEQ=${SEQ:-}" "DRIVE_STATUS=${STATUS:-}"
    "DRIVE_NEXT=${NEXT:-}" "DRIVE_HALT_REASON=$reason" "DRIVE_HALT_NEXT=$hnext" )
  # Operator opt-in allowlist: forward only shell-safe NAMES the notifier needs
  # (e.g. HERMES_TOKEN). The ambient environment is NOT forwarded — deny by default.
  # Split via `read -ra` (no pathname expansion) on a LOCALLY fixed delimiter: a plain
  # `read -ra` would inherit the ambient/config IFS, so a hostile global IFS could
  # split one listed name into pieces and forward a DIFFERENT ambient secret
  # (field-found: NOTIFY_ENV_ALLOW=BOGUS_SECRET + IFS=_ -> notifier got
  # SECRET=ambient-secret, not BOGUS_SECRET). `local IFS` binds the split to the
  # documented whitespace delimiter, independent of ambient/config state, and is
  # bash-3.2-safe (restored on return). The identifier check then runs on each
  # ORIGINAL token, so '*' is rejected, not expanded.
  local IFS=$' \t\n'
  local _allow=()
  read -ra _allow <<< "$NOTIFY_ENV_ALLOW"
  for nm in ${_allow[@]+"${_allow[@]}"}; do
    case "$nm" in [A-Za-z_]*) ;; *) continue ;; esac
    case "$nm" in *[!A-Za-z0-9_]*) continue ;; esac
    eval "val=\${$nm:-}"
    if [ -n "${val:-}" ]; then envv+=( "$nm=$val" ); fi
  done
  envv+=( "$exec" "$event" )
  # NOTIFY_TIMEOUT_MS is a validated canonical base-10 positive integer (preflight
  # rejects leading zeros). Force base 10 here too as defense-in-depth, so this
  # arithmetic — on the halt() path — can never hit an octal/arith error regardless
  # of the validated input.
  local ms=$((10#$NOTIFY_TIMEOUT_MS)) term_ms grace_ms term_s grace_s
  term_ms=$(( ms > 200 ? ms - 200 : 0 )); grace_ms=$(( ms - term_ms ))
  term_s=$(awk -v m="$term_ms"   'BEGIN{printf "%.3f", m/1000}')
  grace_s=$(awk -v m="$grace_ms" 'BEGIN{printf "%.3f", m/1000}')
  ( perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- "${envv[@]}" </dev/null >/dev/null 2>&1 & c=$!
    perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- bash -c \
      '[ "$1" = "0.000" ] || { sleep "$1"; kill -TERM -- "-$3" 2>/dev/null; }; sleep "$2"; kill -KILL -- "-$3" 2>/dev/null' \
      watchdog "$term_s" "$grace_s" "$c" >/dev/null 2>&1 & w=$!
    ec=0; wait "$c" || ec=$?
    kill -KILL -- -"$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    exit "$ec" ) || rc=$?
  if [ "$rc" -eq 0 ]; then :
  elif [ "$rc" -ge 128 ]; then
    [ -n "${NOTIFY_WARNED:-}" ] || note "notify: $exec exceeded the ${NOTIFY_TIMEOUT_MS}ms deadline and was killed (non-fatal) — event pings degraded this run"
    NOTIFY_WARNED=1
  else
    [ -n "${NOTIFY_WARNED:-}" ] || note "notify: $exec failed (non-fatal) — event pings degraded this run"
    NOTIFY_WARNED=1
  fi
  return 0
}

git_q() { git -C "$WORKDIR" "$@"; }
show_origin() { git_q show "origin/$BRANCH:$1" 2>/dev/null; }   # read a path from the REMOTE ref

# ---- doctor ---------------------------------------------------------------------
# `drive.sh doctor` — one line per check, with the EXACT remediation command on a
# MISS. Installs nothing, touches no network (freshness is pipeline-update's job).
# MISS = blocks a drive run (exit 1). warn = degraded but drivable. info = context.
doctor() {
  local bad=0 warn=0 slot
  d_ok()   { printf 'ok    %s\n' "$1"; }
  d_miss() { printf 'MISS  %s\n      fix: %s\n' "$1" "$2"; bad=$((bad+1)); }
  d_warn() { printf 'warn  %s\n      %s\n' "$1" "$2"; warn=$((warn+1)); }
  d_info() { printf 'info  %s\n' "$1"; }

  printf -- '--- deps ----------------------------------------------------------\n'
  if command -v git >/dev/null 2>&1; then d_ok "git on PATH"
  else d_miss "git not on PATH" "install git (xcode-select --install / your package manager)"; fi
  case "$IMPL_TRANSPORT" in
    herdr)
      if command -v herdr >/dev/null 2>&1; then d_ok "herdr on PATH (IMPL_TRANSPORT=herdr)"
      else d_miss "herdr not on PATH but IMPL_TRANSPORT=herdr" "install Herdr (https://herdr.dev), or set IMPL_TRANSPORT=claude"; fi
      if command -v jq >/dev/null 2>&1; then d_ok "jq on PATH (herdr transport needs it)"
      else d_miss "jq not on PATH but IMPL_TRANSPORT=herdr" "brew install jq"; fi
      if command -v perl >/dev/null 2>&1; then d_ok "perl on PATH (herdr transport: monotonic deadlines + process-group kills)"
      else d_miss "perl not on PATH but IMPL_TRANSPORT=herdr" "install perl (base system package on macOS/Linux)"; fi ;;
    claude)
      if command -v claude >/dev/null 2>&1; then d_ok "claude on PATH (IMPL_TRANSPORT=claude)"
      else d_miss "claude not on PATH but IMPL_TRANSPORT=claude" "install Claude Code, or set IMPL_TRANSPORT=herdr"; fi
      if command -v jq >/dev/null 2>&1; then d_ok "jq on PATH"
      else d_warn "jq not on PATH" "needed only for the herdr transport: brew install jq"; fi ;;
    *)
      d_miss "unknown IMPL_TRANSPORT '$IMPL_TRANSPORT' (drive.sh would halt on it)" \
        "set IMPL_TRANSPORT=claude or herdr in $DEFAULTS / drive.config" ;;
  esac
  if command -v gh >/dev/null 2>&1; then d_ok "gh on PATH"
  else d_warn "gh not on PATH" "trunk-protection preflight + PR review degrade: brew install gh"; fi
  if command -v node >/dev/null 2>&1; then d_ok "node on PATH"
  else d_warn "node not on PATH" "dashboard rendering unavailable: install node"; fi

  printf -- '--- sibling repos (pipeline / dashboard / driver) ------------------\n'
  if [ -d "$PIPELINE_REPO/.git" ]; then d_ok "pipeline repo at $PIPELINE_REPO"
  else d_miss "pipeline repo not found at $PIPELINE_REPO" \
       "git clone https://github.com/jackypanster/pipeline.git $PIPELINE_REPO   # or set PIPELINE_REPO in $DEFAULTS"; fi
  if [ -d "$DASHBOARD_REPO/.git" ]; then
    d_ok "dashboard repo at $DASHBOARD_REPO"
    if [ -f "$DASHBOARD_REPO/dist/cli.js" ]; then
      d_ok "dashboard built (dist/cli.js)"
      # Freshness: dist/cli.js must not predate the tracked sources. Catches the real
      # "git pull'd new sources, forgot `npm run build`" case — dashboard is the one
      # sibling whose deploy step is NOT just `git pull` (build = tsc && chmod +x).
      # KNOWN LIMITATION (exactly why this is a WARN, not blocking): a fresh clone has
      # every file at checkout mtime, so dist/cli.js is never older and this silently
      # passes — it is not a constructively-correct freshness proof. Do NOT substitute
      # HEAD commit time: `git pull` only bumps mtimes on CHANGED files, so a commit-
      # time comparison would false-report in several normal cases. `find -newer` is
      # POSIX and `-print -quit` stops at the first hit; no `stat -f %m`/`stat -c %Y`
      # branching is opened (the repo has zero `stat` calls and we keep it that way).
      if find "$DASHBOARD_REPO/src" "$DASHBOARD_REPO/package.json" "$DASHBOARD_REPO/tsconfig.json" \
             -newer "$DASHBOARD_REPO/dist/cli.js" -print -quit 2>/dev/null | grep -q .; then
        d_warn "dashboard dist/cli.js is stale (a tracked source is newer)" \
          "(cd $DASHBOARD_REPO && npm run build)"
      else
        d_ok "dashboard dist/cli.js is up to date"
      fi
    else d_miss "dashboard not built (no dist/cli.js)" "(cd $DASHBOARD_REPO && npm install && npm run build)"; fi
  else
    d_miss "dashboard repo not found at $DASHBOARD_REPO" \
      "git clone https://github.com/jackypanster/pipeline-dashboard.git $DASHBOARD_REPO   # or set DASHBOARD_REPO in $DEFAULTS"
  fi
  d_ok "driver at $HERE (you are running it)"

  printf -- '--- skills (canonical shared layout) -------------------------------\n'
  if [ -d "$SKILLS_DIR/pipeline-impl" ]; then d_ok "pipeline-impl shim in $SKILLS_DIR"
  else d_miss "pipeline-impl shim not in $SKILLS_DIR" \
       "cp -r $PIPELINE_REPO/skills/pipeline-* $SKILLS_DIR/   # then attach each runtime (pipeline README §Install)"; fi

  # Sweep every DECLARED runtime mount (SKILL_MOUNTS, space-separated): each
  # pipeline-* entry in each listed dir is checked against $SKILLS_DIR/<name>. This
  # is the check that catches the incident doctor used to miss — a review runtime
  # ran a stale pipeline-review (a real dir whose content had drifted from
  # canonical) while doctor reported 0 blocking, because that runtime's skill dir
  # was not among the two hard-coded ones above. Classification mirrors
  # pipeline-update's update.sh: physical-path equality for symlinks (cd + pwd -P,
  # NOT readlink's raw string — an absolute and a relative link to the same target
  # must compare equal), diff -rq for real dirs, and a skill merely ABSENT from a
  # mount is not flagged (a runtime need not carry every skill). Empty SKILL_MOUNTS
  # = info-skip, never blocking — existing installs must not go red on upgrade.
  # sweep_skill_mount <mount-dir> <canon-phys>  (nested so it sees d_ok/d_miss/...)
  sweep_skill_mount() {
    local M="$1" canon_phys="$2" E name canon_entry src_phys tgt diff_out diff_rc
    for E in "$M"/pipeline-*; do
      [ -e "$E" ] || [ -L "$E" ] || continue   # glob didn't expand / no pipeline-* -> next
      name=$(basename "$E")
      canon_entry="$SKILLS_DIR/$name"
      src_phys=$(cd "$canon_entry" 2>/dev/null && pwd -P || true)
      if [ -z "$src_phys" ]; then
        d_info "$name in $M has no canonical $canon_entry to compare"
        continue
      fi
      if [ -L "$E" ]; then
        # cd fails = dangling (target gone). readlink's stored target is printed for
        # the human even when dangling, so they can see what it pointed at.
        tgt=$(cd "$E" 2>/dev/null && pwd -P || true)
        if [ -z "$tgt" ]; then
          d_miss "dangling symlink: $E -> $(readlink "$E" 2>/dev/null || printf '?')" \
            "rm $E && ln -s $canon_entry $E"
        elif [ "$tgt" = "$src_phys" ]; then
          d_ok "$name in $M -> $src_phys"
        else
          d_miss "$name in $M -> $tgt (expected $src_phys)" \
            "rm $E && ln -s $canon_entry $E"
        fi
      elif [ -d "$E" ]; then
        # diff -rq: rc 0 = identical, 1 = differs, >=2 = error. ANY stderr voids
        # trust (BSD diff can warn and still exit 0 — reproduced in update.sh).
        diff_out=$(diff -rq "$canon_entry" "$E" 2>&1 >/dev/null) && diff_rc=0 || diff_rc=$?
        if [ -n "$diff_out" ] || [ "$diff_rc" -ge 2 ]; then
          d_warn "cannot trust diff for $name in $M (rc=$diff_rc)" \
            "check the paths/permissions, then re-run doctor"
        elif [ "$diff_rc" = 0 ]; then
          d_ok "$name in $M matches $canon_entry"
        else
          d_miss "$name in $M differs from $canon_entry (stale copy)" \
            "rm -rf $E && ln -s $canon_entry $E"
        fi
      else
        d_miss "$name in $M is neither a dir nor a symlink" \
          "rm $E && ln -s $canon_entry $E"
      fi
    done
  }
  if [ -z "${SKILL_MOUNTS:-}" ]; then
    d_info "SKILL_MOUNTS unset — runtime mount sweep skipped (the two hard-coded dirs above are still checked). To enable, set SKILL_MOUNTS in $DEFAULTS to the space-separated runtime skill dirs (e.g. \$HOME/.codex/skills \$HOME/.claude/skills \$HOME/.pi/agent/skills)"
  elif [ ! -d "$SKILLS_DIR" ]; then
    d_info "SKILL_MOUNTS set but SKILLS_DIR $SKILLS_DIR is not a dir — mount sweep skipped (fix canonical first)"
  else
    canon_phys=$(cd "$SKILLS_DIR" && pwd -P)
    for M in $SKILL_MOUNTS; do
      # A declared mount that is itself a dangling symlink is an active breakage.
      if [ -L "$M" ] && [ ! -e "$M" ]; then
        d_miss "declared SKILL_MOUNTS entry is a dangling symlink: $M -> $(readlink "$M" 2>/dev/null || printf '?')" \
          "fix or remove the link, or drop $M from SKILL_MOUNTS in $DEFAULTS"
        continue
      fi
      # A declared mount that simply isn't there: warn (not blocking) — the operator
      # may have listed a runtime they have not installed; the sweep's job is stale
      # ENTRIES, and absence is not a stale entry.
      if [ ! -d "$M" ]; then
        d_warn "declared SKILL_MOUNTS dir not found: $M" \
          "create it, or drop $M from SKILL_MOUNTS in $DEFAULTS"
        continue
      fi
      # Skip self: the canonical dir IS the reference, not a subject.
      m_phys=$(cd "$M" && pwd -P 2>/dev/null || true)
      [ -n "$m_phys" ] && [ "$m_phys" = "$canon_phys" ] && continue
      sweep_skill_mount "$M" "$canon_phys"
    done
  fi

  printf -- '--- config ----------------------------------------------------------\n'
  if [ -f "$DEFAULTS" ]; then d_ok "global defaults: $DEFAULTS"
  else d_warn "no global defaults file ($DEFAULTS)" \
       "mkdir -p $(dirname "$DEFAULTS") && cp $HERE/drive.defaults.example $DEFAULTS   # one-time"; fi
  if [ -f "$CONF" ]; then
    local missing=""
    [ -n "${WORKDIR:-}" ] || missing="$missing WORKDIR"
    [ -n "${BRANCH:-}" ]  || missing="$missing BRANCH"
    [ -n "${FEATURE:-}" ] || missing="$missing FEATURE"
    if [ -z "$missing" ]; then d_ok "per-feature config: $CONF (WORKDIR/BRANCH/FEATURE all set)"
    else d_miss "required setting(s) unset after sourcing defaults+config:$missing" \
         "set them in $CONF (see drive.config.example) — drive.sh would die on them"; fi
  else d_warn "no per-feature config ($CONF)" \
       "cp $HERE/drive.config.example ${CONF}   # then set WORKDIR / BRANCH / FEATURE"; fi
  if [ "$YOLO" = "1" ]; then
    d_info "YOLO=1 — standing low-risk grant on record: the coordinating agent may echo the spec-rev at GATE 1"
  else
    d_info "YOLO=0 — GATE 1 expects a human to read the frozen spec and echo its spec-rev"
  fi

  if [ -n "${WORKDIR:-}" ]; then
    printf -- '--- target repo -----------------------------------------------------\n'
    if git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1; then
      d_ok "WORKDIR is a git repo: $WORKDIR"
      if [ -f "$WORKDIR/.pipeline/current.json" ]; then d_ok "target has .pipeline/current.json"
      else d_warn "target has no .pipeline/current.json" "start the feature with pipeline-prd (it seeds current.json)"; fi
      if [ -f "$WORKDIR/.pipeline/roles.yaml" ]; then
        # `|| true` matters: under set -e/pipefail a failing pipeline inside $()
        # would abort doctor mid-report instead of printing the summary.
        slot=$(awk -F'#' '{print $1}' "$WORKDIR/.pipeline/roles.yaml" 2>/dev/null \
               | awk -F'[][, ]+' '/^impl:/{print $2}' | head -1 || true)
        if [ -n "${slot:-}" ]; then
          if [ -d "$SKILLS_DIR/$slot" ]; then
            d_ok "impl slot '$slot' present in $SKILLS_DIR (canonical copy)"
          else
            d_warn "impl slot '$slot' not in $SKILLS_DIR" \
              "install it there + attach the impl runtime (pipeline README §Verify dependencies)"
          fi
          # Resolution check on the runtime that will actually RUN impl. Skills register
          # by frontmatter `name:` (field-verified 2026-07-12: a symlinked dir name does
          # NOT register on Claude Code), so grep the name, not the directory.
          case "$IMPL_TRANSPORT" in
            herdr)
              if grep -qs "^name: ${slot}\$" "$TUI_SKILLS_DIR"/*/SKILL.md 2>/dev/null; then
                d_ok "impl slot '$slot' resolves in the TUI agent's skill dir ($TUI_SKILLS_DIR)"
              else
                d_miss "impl slot '$slot' not registered under $TUI_SKILLS_DIR — the $IMPL_TRANSPORT-driven TUI agent would STOP at slot resolution" \
                  "ln -s $SKILLS_DIR/$slot $TUI_SKILLS_DIR/$slot   # or set TUI_SKILLS_DIR in $DEFAULTS"
              fi ;;
            claude)
              if grep -qs "^name: ${slot}\$" "$HOME/.claude/skills"/*/SKILL.md 2>/dev/null; then
                d_ok "impl slot '$slot' resolves on the Claude runtime (~/.claude/skills)"
              else
                d_warn "impl slot '$slot' not found by frontmatter name under ~/.claude/skills" \
                  "attach it there (symlink whose SKILL.md name matches, or a name-shim wrapper)"
              fi ;;
          esac
        else
          d_warn "roles.yaml has no parseable impl slot" "check $WORKDIR/.pipeline/roles.yaml"
        fi
      else
        d_warn "target has no .pipeline/roles.yaml" \
          "seed it: cp $PIPELINE_REPO/roles.yaml $WORKDIR/.pipeline/roles.yaml"
      fi
    else
      d_miss "WORKDIR is not a git repo: $WORKDIR" "clone the target repo there, or fix WORKDIR in $CONF"
    fi
  fi

  printf -- '---------------------------------------------------------------------\n'
  printf 'doctor: %d blocking, %d warning(s)\n' "$bad" "$warn"
  [ "$bad" -eq 0 ]
}
if [ "$SUBCMD" = "doctor" ]; then doctor; exit $?; fi

# ---- herdr transport helpers ------------------------------------------------------
# Resolve the impl pane: explicit HERDR_PANE_ID > discovery (agent-bearing pane whose
# .cwd == WORKDIR, or whose .cwd contains HERDR_PANE_CWD_MATCH when set — e.g. a TUI
# opened in a subdir of the worktree). Exactly ONE match required — the driver must
# never type into an ambiguous pane. `herdr pane list` prints the socket JSON envelope
# by default (there is NO --json flag); filter .cwd, NOT .foreground_cwd (a foreground
# child chdir'ing drags foreground_cwd away from the pane — PRD, live-verified).
resolve_herdr_pane() {
  if [ -n "$HERDR_PANE_ID" ]; then
    # A pinned pane must never be the driver's own pane (config error).
    if [ -n "${DRIVER_SELF_PANE:-}" ] && [ "$HERDR_PANE_ID" = "$DRIVER_SELF_PANE" ]; then
      note "herdr: HERDR_PANE_ID equals the pane running drive.sh — the driver cannot type into itself"
      return 1
    fi
    printf '%s\n' "$HERDR_PANE_ID"; return 0
  fi
  local js n
  js=$(herdr pane list 2>/dev/null) \
    || { note "herdr: 'pane list' failed — is Herdr running? (socket: ~/.config/herdr/herdr.sock)"; return 1; }
  # Exclude the driver's own pane (Herdr injects HERDR_PANE_ID into every pane it
  # manages — a driver launched inside the target worktree would otherwise match).
  # Agent-bearing only: a plain shell pane in the worktree is never a send target.
  js=$(printf '%s' "$js" | jq --arg wd "$WORKDIR" --arg m "$HERDR_PANE_CWD_MATCH" --arg self "${DRIVER_SELF_PANE:-}" \
        '[.result.panes[]? | select((.agent // "") != "")
          | select(.pane_id != $self)
          | select(if $m == "" then .cwd == $wd else ((.cwd // "") | contains($m)) end)]') || return 1
  n=$(printf '%s' "$js" | jq 'length')
  case "$n" in
    1) printf '%s' "$js" | jq -r '.[0].pane_id' ;;
    0) note "herdr: no agent-bearing pane for cwd ${HERDR_PANE_CWD_MATCH:-$WORKDIR}${HERDR_PANE_CWD_MATCH:+ (substring match)} (the driver's own pane is excluded)"; return 1 ;;
    *) note "herdr: $n panes match — narrow with HERDR_PANE_CWD_MATCH (different cwd) or pin HERDR_PANE_ID"; return 1 ;;
  esac
}

# One atomic sample per poll: agent STATE and detection AUTHORITY from the SAME
# `herdr agent explain` payload — checking them in separate reads races (a
# screen-manifest pane can leave its matched rule between the two reads and fall
# back to always-idle). Authoritative = a lifecycle hook OR a MATCHED manifest
# rule, with no fallback in effect. A merely LOADED manifest (manifest_source set,
# matched_rule null) is NOT authority: on an unrecognized screen Herdr 0.7.3
# reports exactly that plus fallback_reason=default_known_agent_idle_fallback and
# state idle — the always-idle trap this guard exists to reject.
herdr_agent_sample() {   # <pane> <timeout_ms> — echoes "<state> <1|0 authority flag>"; empty on failure/timeout
  run_with_timeout_ms "$2" herdr agent explain "$1" --json 2>/dev/null | jq -r \
    '[(.state // "unknown"),
      (if (((.screen_detection_skip_reason == "full_lifecycle_hook_authority") or (.matched_rule != null))
           and (.fallback_reason == null)) then "1" else "0" end)]
     | join(" ")' 2>/dev/null
}

# NB: single-quoted awk program + -v, deliberately — bash 3.2 (macOS /bin/bash)
# mangles escaped quotes nested inside $(): `"$(awk "…\"…\"…")"` brace-expands the
# program into garbage (field-hit 2026-07-15: the watchdog slept 0ms and killed
# every sample at birth).
sleep_ms() { sleep "$(awk -v ms="$1" 'BEGIN{printf "%.3f", ms/1000}')"; }

# Clock for guard deadlines: MONOTONIC when available (perl Time::HiRes
# clock_gettime — wall-clock steps from NTP/manual adjustment must not stretch or
# shrink a timeout), else HiRes wall time, else whole-second date. The source is
# probed and PINNED once (herdr transport only) — mixing epochs across calls
# would corrupt deadline arithmetic (CLOCK_MONOTONIC counts from boot).
NOW_MS_MODE=date
if [ "$IMPL_TRANSPORT" = "herdr" ]; then
  if perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'clock_gettime(CLOCK_MONOTONIC)' >/dev/null 2>&1; then
    NOW_MS_MODE=mono
  elif perl -MTime::HiRes=time -e 'time()' >/dev/null 2>&1; then
    NOW_MS_MODE=wall
  fi
fi
now_ms() {
  case "$NOW_MS_MODE" in
    mono) perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf("%.0f", clock_gettime(CLOCK_MONOTONIC)*1000)' ;;
    wall) perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' ;;
    *)    date +%s000 ;;
  esac
}

# Run <cmd…> with a hard deadline of <ms> — a wedged herdr daemon must not hang the
# guard past its budget. Portable (macOS ships neither `timeout` nor `setsid`; perl
# is a CHECKED herdr-transport dependency — preflight/doctor): both the child AND
# the watchdog run in their OWN process groups (perl setpgrp+exec), because
# (a) killing only the direct child would leave grandchildren holding the stdout
# pipe — the consumer (jq) would block until they exit — and (b) disarming only the
# watchdog shell would orphan its in-flight external `sleep` (one per poll: ~120
# strays over a 60s budget). The watchdog sends TERM at max(0, ms-200) and KILL AT
# the deadline — the 200ms grace is carved out of the budget, not appended, so a
# TERM-trapping descendant still dies ON the deadline (budgets ≤200ms skip the
# TERM phase: a straight deadline KILL beats TERMing a healthy sample at t=0).
# The disarm is a group-KILL + reap. The child's rc propagates; stdout passes
# through.
run_with_timeout_ms() {   # <ms> <cmd…>
  local ms=$1; shift
  ( term_ms=$(( ms > 200 ? ms - 200 : 0 ))
    grace_ms=$(( ms - term_ms ))
    term_s=$(awk -v ms="$term_ms" 'BEGIN{printf "%.3f", ms/1000}')
    grace_s=$(awk -v ms="$grace_ms" 'BEGIN{printf "%.3f", ms/1000}')
    perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- "$@" & c=$!
    perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- bash -c \
      '[ "$1" = "0.000" ] || { sleep "$1"; kill -TERM -- "-$3" 2>/dev/null; }; sleep "$2"; kill -KILL -- "-$3" 2>/dev/null' \
      watchdog "$term_s" "$grace_s" "$c" \
      >/dev/null 2>&1 & w=$!
    rc=0; wait "$c" || rc=$?
    kill -KILL -- -"$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    exit "$rc" )
}

# Status guard, read-first: proceed iff the SAME sample is authoritative AND its
# state ∈ {done,idle}; authoritative blocked halts fast; anything else (working /
# unknown / non-authoritative / unreadable) re-polls until a MONOTONIC deadline of
# HERDR_IDLE_TIMEOUT_MS from guard start. The budget binds for real: the deadline
# is checked before every sample, each `agent explain` call is itself KILLED at
# the remaining budget (a wedged daemon cannot hang the guard), and a ready state
# is accepted only when the sample also RETURNED within the deadline — nothing
# authorizes a send past the budget. Herdr's done = finished-unviewed vs idle =
# finished-viewed — an idle pane never re-fires done, so a bare
# `herdr wait agent-status --status done` would hang (live-verified; PRD note).
herdr_status_guard() {
  local pane="$1" sample st auth="" deadline rem step_ms=500 sl
  deadline=$(( $(now_ms) + HERDR_IDLE_TIMEOUT_MS ))
  while :; do
    rem=$(( deadline - $(now_ms) ))
    if [ "$rem" -le 0 ]; then
      [ "$auth" = "1" ] || note "herdr: agent state for pane $pane is NOT authoritative (no lifecycle hook / no MATCHED manifest rule — the always-idle fallback). Fail closed: pin HERDR_PANE_ID to a pane with hook authority, or install that agent's Herdr integration (herdr agent explain $pane)"
      return 1
    fi
    sample=$(herdr_agent_sample "$pane" "$rem") || sample=""
    st="${sample%% *}"; auth="${sample##* }"
    if [ "$auth" = "1" ]; then
      case "$st" in
        done|idle)
          [ "$(now_ms)" -le "$deadline" ] && return 0
          return 1 ;;   # sample returned past the deadline — timeout, not consent
        blocked)   note "herdr: pane $pane agent is BLOCKED — halting fast (needs a human look)"; return 1 ;;
      esac
    fi
    rem=$(( deadline - $(now_ms) ))
    [ "$rem" -le 0 ] && continue
    sl=$step_ms; [ "$rem" -lt "$sl" ] && sl=$rem
    sleep_ms "$sl"
  done
}

# After a reset send: `pane run` only ENQUEUES text+Enter — an immediately-following
# guard could read the PRE-reset ready state and submit the card before the reset is
# processed. Watch for an observable transition (any non-ready sample = the TUI
# visibly took the reset) and hand over to the guard the moment one shows; if none
# shows before a real-clock deadline of HERDR_RESET_SETTLE_MS, fall through to the
# guard (fast TUIs can finish a reset between polls, and pane `revision` does NOT
# tick on content in Herdr 0.7.3 — live-verified — so time is the only remaining
# bound).
herdr_reset_settle() {
  local pane="$1" sample st deadline step_ms=250 rem sl
  deadline=$(( $(now_ms) + HERDR_RESET_SETTLE_MS ))
  while :; do
    rem=$(( deadline - $(now_ms) ))
    [ "$rem" -le 0 ] && return 0
    sample=$(herdr_agent_sample "$pane" "$rem") || sample=""
    st="${sample%% *}"
    case "$st" in done|idle|"") ;; *) return 0 ;; esac
    rem=$(( deadline - $(now_ms) ))
    [ "$rem" -le 0 ] && continue
    sl=$step_ms; [ "$rem" -lt "$sl" ] && sl=$rem
    sleep_ms "$sl"
  done
}

remote_seq() {   # seq of the LAST journal entry on origin/<BRANCH>; empty output on parse failure
  local J
  J=$(show_origin "$JOURNAL") || return 1
  printf '%s' "$J" | awk -f "$AWK" | sed -n 's/^SEQ=\([0-9][0-9]*\);.*/\1/p'
}

# ---- preflight ----------------------------------------------------------------
# NOTIFY_EXEC (if set): every operator knob the hook consumes is validated and ARMED
# here, before ANY other preflight halt. This ordering is load-bearing: the
# transport/git checks below (and validation itself) call halt(), and halt() calls
# notify_hook() -> run_notify() — so a bad value must halt HERE, not break halt()
# mid-flight. Two field-found regressions this blocks: (a) an unvalidated relative
# NOTIFY_EXEC was PATH-selected by the transport halt and created ./halt; (b) a
# non-integer NOTIFY_TIMEOUT_MS (e.g. 1.5) raised an arithmetic error INSIDE halt()
# that skipped the banner+exit and let execution reach GATE 1. NOTIFY_READY stays ""
# until the whole block passes, so notify_hook is inert for every halt in this block
# (NOTIFY_EXEC is cleared before each fail-loud halt). Path rules match
# coordinate.sh ON_HALT_EXEC; the timeout is a bounded positive integer; perl
# (setpgrp) is REQUIRED for the whole-process-group kill (no portable fallback:
# a direct-child-only kill would leave descendants running, field-found).
if [ -n "$NOTIFY_EXEC" ]; then
  bad_notify=""
  case "$NOTIFY_EXEC" in /*) ;; *) bad_notify="NOTIFY_EXEC not absolute: $NOTIFY_EXEC" ;; esac
  [ -n "$bad_notify" ] || { [ ! -L "$NOTIFY_EXEC" ] || bad_notify="NOTIFY_EXEC is a symlink: $NOTIFY_EXEC"; }
  [ -n "$bad_notify" ] || { [ -f "$NOTIFY_EXEC" ]   || bad_notify="NOTIFY_EXEC not a regular file: $NOTIFY_EXEC"; }
  [ -n "$bad_notify" ] || { [ -x "$NOTIFY_EXEC" ]   || bad_notify="NOTIFY_EXEC not executable: $NOTIFY_EXEC"; }
  # NOTIFY_TIMEOUT_MS flows into arithmetic on the halt() path -> reject any non-digit
  # or out-of-range value HERE. Pattern-match first (no arithmetic on the untrusted
  # string): digits-only, then REJECT leading zeros (0[0-9]*) because bash $(( ))
  # reads them as OCTAL (field-found: 08 -> "value too great for base" inside halt(),
  # bypassing the banner+exit). A length cap avoids passing a huge number to `[`;
  # then the range.
  if [ -z "$bad_notify" ]; then
    case "$NOTIFY_TIMEOUT_MS" in
      ''|*[!0-9]*)    bad_notify="NOTIFY_TIMEOUT_MS not a positive integer: ${NOTIFY_TIMEOUT_MS:-<empty>}" ;;
      0[0-9]*)        bad_notify="NOTIFY_TIMEOUT_MS has a leading zero (bash arithmetic would read it as octal): $NOTIFY_TIMEOUT_MS" ;;
    esac
  fi
  if [ -z "$bad_notify" ]; then
    if [ "${#NOTIFY_TIMEOUT_MS}" -gt 6 ] || [ "$NOTIFY_TIMEOUT_MS" -lt 1 ] || [ "$NOTIFY_TIMEOUT_MS" -gt 300000 ]; then
      bad_notify="NOTIFY_TIMEOUT_MS out of range [1,300000]ms: $NOTIFY_TIMEOUT_MS"
    fi
  fi
  if [ -n "$bad_notify" ]; then
    NOTIFY_EXEC=""
    halt "$bad_notify" "fix NOTIFY_EXEC / NOTIFY_TIMEOUT_MS in drive.defaults/drive.config, or unset NOTIFY_EXEC" 2
  fi
  # The hard-deadline process-group kill needs perl setpgrp; macOS ships neither
  # setsid nor timeout, so there is no portable fallback that reaps descendants.
  # Require it (fail loud here), not a silent direct-child-only kill at runtime.
  perl -e 'setpgrp(0,0)' >/dev/null 2>&1 \
    || { NOTIFY_EXEC=""; halt "NOTIFY_EXEC needs perl (with setpgrp) on PATH for the hard-deadline process-group kill" "install perl, or unset NOTIFY_EXEC" 2; }
fi
NOTIFY_READY=1

case "$IMPL_TRANSPORT" in
  claude)
    command -v claude >/dev/null 2>&1 || halt "claude CLI not on PATH" "install Claude Code, then re-run" 2 ;;
  herdr)
    command -v herdr >/dev/null 2>&1 || halt "herdr CLI not on PATH (IMPL_TRANSPORT=herdr)" "install Herdr (https://herdr.dev), then re-run" 2
    command -v jq    >/dev/null 2>&1 || halt "jq not on PATH (IMPL_TRANSPORT=herdr needs it)" "install jq, then re-run" 2
    command -v perl  >/dev/null 2>&1 || halt "perl not on PATH (IMPL_TRANSPORT=herdr needs it: monotonic deadlines + process-group kills)" "install perl, then re-run" 2 ;;
  *) halt "unknown IMPL_TRANSPORT '$IMPL_TRANSPORT'" "set IMPL_TRANSPORT=claude or herdr in drive.config" 2 ;;
esac
git_q rev-parse --git-dir >/dev/null 2>&1 || halt "WORKDIR is not a git repo: $WORKDIR" "clone the target repo there" 2

git_q fetch origin --quiet || halt "git fetch origin failed (network / auth)" "fix connectivity, re-run" 1

# Render the settings with the absolute hook path (the hook travels in --settings so
# it applies regardless of the child's ambient config). Process-local temp; cleaned on exit.
RENDERED="${TMPDIR:-/tmp}/pipeline-driver-settings.$$.json"
sed "s#__DENY_MERGE_SH__#$HERE/deny-merge.sh#g" "$SETTINGS_TMPL" > "$RENDERED"
chmod +x "$HERE/deny-merge.sh" 2>/dev/null || true
trap 'rm -f "$RENDERED"' EXIT

# Preflight (claude transport): the roles.yaml impl slot must resolve to a skill
# installed on the CLAUDE runtime, else every driven pipeline-impl STOPs at
# 'skill not installed'. The driver cannot see another runtime's skill dir, so it
# reminds the operator instead of asserting where any skill lives.
roles=$(show_origin ".pipeline/roles.yaml" || true)
impl_slot=$(printf '%s\n' "$roles" | awk -F'#' '{print $1}' | awk -F'[][, ]+' '/^impl:/{print $2}' | head -1)
if [ "$IMPL_TRANSPORT" = "claude" ] && [ -n "${impl_slot:-}" ]; then
  note "NOTE: roles.yaml impl slot = '$impl_slot' — verify it is installed on the Claude runtime"
  note "      (canonical layout: one shared skills dir, runtimes attached — pipeline README §Install)."
fi

# Trunk-clobber (force-push / deletion) is best closed SERVER-SIDE by a branch ruleset;
# warn if trunk is not protected. (Normative merge-safety model: README §Merge safety.)
remote_url=$(git_q remote get-url origin 2>/dev/null || true)
case "$remote_url" in
  *github.com*)
    if command -v gh >/dev/null 2>&1; then
      rules=$( ( cd "$WORKDIR" && gh api "repos/{owner}/{repo}/rules/branches/$BRANCH" 2>/dev/null ) || true )
      # clobber-guard.sh exits 0 only when BOTH non_fast_forward AND deletion are present.
      if ! printf '%s' "$rules" | bash "$HERE/clobber-guard.sh"; then
        note "WARNING: trunk '$BRANCH' is not fully protected against force-push AND deletion server-side."
        note "         Add a ruleset with BOTH non_fast_forward + deletion — see README §Setup step 5."
        note "         (Unavailable on a free-plan private repo: rely on never-force-push discipline.)"
        note "         The feature-PR MERGE gate remains: the driver halts before review + you merge."
      fi
    fi ;;
esac

# Herdr transport: resolve the impl pane NOW so a bad setup halts before GATE 1.
# (run_impl_herdr re-resolves per card — handles churn when panes close/reopen.)
if [ "$IMPL_TRANSPORT" = "herdr" ]; then
  _p=$(resolve_herdr_pane) || halt "cannot resolve the impl pane in Herdr (cwd: $WORKDIR)" \
      "open the coder TUI in a Herdr pane for that worktree; use HERDR_PANE_CWD_MATCH or pin HERDR_PANE_ID" 2
  note "herdr transport: impl pane = $_p"
fi

# ---- run ONE impl stage: a fresh `claude` cold node on the cheap tier ----------
# The skill MUST be the first token of -p (leading prose stops slash expansion).
# Gateway env (ANTHROPIC_BASE_URL/AUTH for a non-Anthropic Anthropic-compatible
# model, e.g. GLM) is exported INSIDE a subshell, so it is scoped to the child and
# never leaks into the driver. The impl child shares this checkout on purpose:
# pipeline-impl commits card status to TRUNK and code to feat/<feature> in the same
# repo, so it cannot live in a separate worktree (trunk is checked out here). The
# driver stays safe by reading ONLY origin/<BRANCH> refs, never the working tree.
run_impl_claude() {
  (
    export DRIVER_TRUNK="$BRANCH"   # lets deny-merge.sh protect the REAL trunk, not just master|main
    if [ -n "${IMPL_BASE_URL:-}" ]; then
      export ANTHROPIC_BASE_URL="$IMPL_BASE_URL"
      if [ -n "${IMPL_AUTH_TOKEN_ENV:-}" ]; then
        eval "tok=\${$IMPL_AUTH_TOKEN_ENV:-}"
        [ -n "${tok:-}" ] && export ANTHROPIC_AUTH_TOKEN="$tok"   # never printed
      fi
    fi
    # NO --bare: on current Claude Code, --bare skips skill loading entirely
    # ("Unknown command: /pipeline-impl" — field-failed 2026-07-11, biji stats live run)
    # and restricts auth to ANTHROPIC_API_KEY (OAuth/keychain skipped). The deny-merge
    # hook still binds via --settings; ambient hooks/CLAUDE.md loading is acceptable.
    claude \
      --settings "$RENDERED" \
      --permission-mode dontAsk \
      --model "$IMPL_MODEL" \
      -p "/pipeline-impl repo=$WORKDIR branch=$BRANCH"
  )
}

# Herdr transport: type the stage command into a live coder TUI pane, then treat the
# REMOTE journal as the only completion signal — poll origin until seq advances or
# CARD_TIMEOUT. No exit code exists here; the deny-merge --settings hook does NOT
# travel into the TUI agent (the durable gates — halt-before-review + human merge +
# trunk rules — hold regardless). Herdr specifics
# (PRD .pipeline/herdr-transport/PRD.md): send is `herdr pane run` (atomic
# text+Enter, officially preferred over send-text + send-keys enter); the pre-send
# guard validates readiness AND detection authority from the SAME explain sample on
# every poll ({done,idle} both mean ready — an idle pane never re-fires done), and
# FAILS CLOSED on non-authoritative state rather than type into a pane whose
# always-idle fallback can't see a busy TUI. A reset is followed by a settle window
# (herdr_reset_settle) before the second guard.
run_impl_herdr() {
  local pane start s
  pane=$(resolve_herdr_pane) || return 1
  if [ -n "$HERDR_RESET_CMD" ]; then
    # The guard is as load-bearing for the reset as for the real send: typing the
    # reset into a BUSY TUI could corrupt an in-flight card. A guard failure is fatal.
    herdr_status_guard "$pane" \
      || { note "herdr: pane $pane not ready within ${HERDR_IDLE_TIMEOUT_MS}ms (before reset)"; return 1; }
    herdr pane run "$pane" "$HERDR_RESET_CMD" >/dev/null 2>&1 \
      || { note "herdr: reset send failed for $pane"; return 1; }
    herdr_reset_settle "$pane"
  fi
  herdr_status_guard "$pane" \
    || { note "herdr: pane $pane not ready within ${HERDR_IDLE_TIMEOUT_MS}ms"; return 1; }
  herdr pane run "$pane" "$IMPL_SLASH_CMD repo=$WORKDIR branch=$BRANCH" >/dev/null 2>&1 \
    || { note "herdr: 'pane run' failed for $pane"; return 1; }
  start=$SECONDS
  while [ $((SECONDS - start)) -lt "$CARD_TIMEOUT" ]; do
    sleep "$POLL_SECS"
    git_q fetch origin --quiet || true          # transient fetch error: keep polling
    s=$(remote_seq) || s=""
    if [ -n "$s" ] && [ "$s" -gt "$prev_seq" ]; then return 0; fi
  done
  note "herdr transport: no journal progress within ${CARD_TIMEOUT}s — impl pane tail:"
  herdr pane read "$pane" --source recent --lines 20 2>/dev/null | tail -20 >&2 || true
  return 1
}

run_impl() {
  case "$IMPL_TRANSPORT" in
    herdr) run_impl_herdr ;;
    *)     run_impl_claude ;;
  esac
}

# ---- spec-rev helpers (read from the REMOTE; all cards share one spec-rev) ------
first_card_path() {
  git_q ls-tree --name-only "origin/$BRANCH" "$TASKS/" 2>/dev/null \
    | grep -E '/[0-9]+\.md$' | sort | head -1
}
live_spec_rev() {                 # all cards share one spec-rev; read it from the first
  local card body; card=$(first_card_path) || return 1
  [ -n "$card" ] || return 1
  body=$(show_origin "$card") || return 1
  # whole-file awk (no early `exit`) avoids a SIGPIPE under `set -o pipefail`
  awk -F': *' '/^spec-rev:/{v=$2} END{if(v!="")print v}' <<<"$body"
}
stranded_in_progress() { # echoes a card path if any card is status: in-progress on the remote
  local c body
  for c in $(git_q ls-tree --name-only "origin/$BRANCH" "$TASKS/" 2>/dev/null | grep -E '/[0-9]+\.md$'); do
    body=$(show_origin "$c") || continue
    if grep -Eq '^status:[[:space:]]*in-progress' <<<"$body"; then echo "$c"; return 0; fi
  done
  return 1
}

# ---- GATE 1: bind confirmation to the frozen spec-rev --------------------------
CONFIRMED_SPEC_REV=$(live_spec_rev) || halt "no task cards under origin/$BRANCH:$TASKS — feature not decomposed yet" "run pipeline-task (human, frontier)" 2
[ -n "$CONFIRMED_SPEC_REV" ] || halt "cards carry no spec-rev — task did not freeze a spec" "run pipeline-task (human, frontier)" 2

if [ "$IMPL_TRANSPORT" = "herdr" ]; then
  note "Feature : $FEATURE   (trunk=$BRANCH)   impl transport=$IMPL_TRANSPORT (live TUI pane)"
else
  note "Feature : $FEATURE   (trunk=$BRANCH)   impl model=$IMPL_MODEL"
fi
note "Frozen spec-rev: $CONFIRMED_SPEC_REV"
note "----- frozen spec (read it before authorizing the autonomous loop) -----"
git_q show --stat "$CONFIRMED_SPEC_REV" >&2 || true
note "-----------------------------------------------------------------------"
if [ "$YOLO" = "1" ]; then
  note "YOLO=1 — standing grant on record (README §YOLO): for a LOW-RISK feature the"
  note "coordinating agent may read the frozen spec and type the spec-rev below."
  note "Merge confirm stays human; DANGEROUS features never use the driver."
fi
printf 'GATE 1 — type the spec-rev above to confirm you read the frozen red test: ' >&2
read -r ACK || halt "GATE 1 needs an interactive terminal (stdin closed)" "run drive.sh attached to a TTY" 2
[ "$ACK" = "$CONFIRMED_SPEC_REV" ] || halt "spec-rev not confirmed (got '${ACK}')" "read the frozen test, then re-run drive.sh" 2
render_board   # fresh board at drive start (no-op when BOARD_OUT is empty)
notify_hook gate1   # "loop running — you can walk away" (no-op when NOTIFY_EXEC is empty)

# ---- the loop -----------------------------------------------------------------
consec_fail=0
while : ; do
  git_q fetch origin --quiet || halt "git fetch origin failed mid-loop" "fix connectivity, re-run drive.sh" 1

  J=$(show_origin "$JOURNAL") || halt "no journal at origin/$BRANCH:$JOURNAL (meta-PR / unstarted feature)" "run pipeline-prd/arch/task (human)" 0
  eval "$(printf '%s' "$J" | awk -f "$AWK")"            # -> SEQ STATUS NEXT
  [ -n "${SEQ:-}" ] || halt "journal has no parseable entries" "inspect $JOURNAL" 1

  LIVE_SPEC_REV=$(live_spec_rev || true)

  if sc=$(stranded_in_progress); then
    halt "card stranded status:in-progress on the remote ($sc) — a prior impl run died mid-card" \
         "reset that card to status:todo on $BRANCH, then re-run drive.sh" 1
  fi

  # A review REJECTION routes review->impl with NEXT=impl and an unchanged spec-rev.
  # That is a human SEMANTIC decision (changes requested); the driver must not silently
  # re-drive a card a reviewer just bounced — the verdict must be READ first. Tail-only
  # detection cannot distinguish a seen rejection from an unseen one (zero state, and the
  # tail advances only after impl runs), so a plain halt here made its own remediation
  # ("re-run to resume") loop back into the same halt forever. The exit is a read-then-bind
  # ritual (structurally like GATE 1) that stays DIRECT-HUMAN: type the rejection seq to
  # confirm the review was read, and the loop proceeds to dispatch the fix; EOF or a
  # mismatch keeps the loop halted. The halt REASON is unchanged from the historical halt;
  # only its remediation now names the ack step. A NEW rejection (different seq) re-fires
  # the gate. NOTE: YOLO's standing grant is GATE-1-only by contract (README §YOLO — "it
  # changes NOTHING else") and is deliberately NOT extended here; reading a rejection
  # verdict is its own human checkpoint, so this ack is never delegated by YOLO.
  if [ "${FROM:-}" = "review" ] && [ "$NEXT" = "impl" ] && [ "${ACKED_REJECTION_SEQ:-}" != "$SEQ" ]; then
    note ""
    note "REJECTION GATE — review bounced a card back to impl (seq=$SEQ)."
    note "Read the verdict first: .pipeline/$FEATURE/reviews/*"
    printf 'REJECTION GATE — type the rejection seq (%s) to confirm you read the review and resume the fix: ' "$SEQ" >&2
    if ! read -r RACK || [ "$RACK" != "$SEQ" ]; then
      halt "review rejected a card and routed it back to impl (seq=$SEQ) — a human semantic decision" \
           "read .pipeline/$FEATURE/reviews/*, then re-run drive.sh and type $SEQ at the rejection gate" 0
    fi
    ACKED_REJECTION_SEQ="$SEQ"
  fi

  # --- HALT PREDICATE ---
  if [ "$NEXT" != "impl" ] || [ "${STATUS}" = "blocked" ]; then
    case "$NEXT" in
      review) halt "all cards in review (seq=$SEQ) — feature complete, human merge gate ahead" \
                   "pipeline-review (frontier, semantic review + merge confirm)" 0 ;;
      hunt)   halt "card blocked / integration incident (seq=$SEQ, status=$STATUS)" "pipeline-hunt (frontier, root-cause)" 0 ;;
      "")     halt "terminal/awaiting entry, no next command (seq=$SEQ)" "read $JOURNAL tail — likely awaiting your merge 'go', or feature done" 0 ;;
      *)      halt "tail routes to pipeline-$NEXT (seq=$SEQ, status=$STATUS) — outside the impl loop" "pipeline-$NEXT (human)" 0 ;;
    esac
  fi
  if [ "${LIVE_SPEC_REV:-}" != "$CONFIRMED_SPEC_REV" ]; then
    halt "spec-rev changed ($CONFIRMED_SPEC_REV -> ${LIVE_SPEC_REV:-none}): a re-freeze/append-card landed a NEW frozen spec" \
         "GATE 1 again — read the new frozen test, then re-run drive.sh" 0
  fi

  # --- cost/safety on informed retries (failed -> impl, attempts<3) ---
  if [ "$STATUS" = "failed" ]; then
    [ "$RETRY_ON_FAIL" = "1" ] || halt "impl failed (seq=$SEQ) and RETRY_ON_FAIL=0" "inspect, then pipeline-impl (manual) or flip RETRY_ON_FAIL=1" 0
    consec_fail=$((consec_fail + 1))
    [ "$consec_fail" -lt "$MAX_CONSEC_FAIL" ] || halt "circuit breaker: $consec_fail consecutive failed impl runs" "inspect the '## Attempt N' notes; pipeline-hunt or manual impl" 0
  else
    consec_fail=0
  fi

  # --- run ONE impl stage as a fresh cold node ---
  prev_seq=$SEQ
  note ""
  if [ "$IMPL_TRANSPORT" = "herdr" ]; then
    note ">>> impl dispatch via herdr pane (after seq=$prev_seq) ..."
    if ! run_impl; then
      halt "the driven pipeline-impl made no journal progress after seq=$prev_seq (pane error or card timeout)" \
           "inspect the impl pane in Herdr; pipeline-impl (manual) or pipeline-hunt" 1
    fi
  else
    note ">>> impl run (after seq=$prev_seq, model=$IMPL_MODEL) ..."
    if ! run_impl; then
      halt "the driven pipeline-impl exited non-zero after seq=$prev_seq (a denied tool — e.g. attempted merge — or a crash)" \
           "inspect the claude output above; pipeline-impl (manual) or pipeline-hunt" 1
    fi
  fi

  # --- NO-PROGRESS GUARD on the REMOTE seq (catches commit-not-pushed) ---
  git_q fetch origin --quiet || halt "git fetch origin failed after impl" "verify the impl run pushed; re-run drive.sh" 1
  J=$(show_origin "$JOURNAL") || halt "journal vanished from origin/$BRANCH after impl" "inspect the repo" 1
  eval "$(printf '%s' "$J" | awk -f "$AWK")"
  [ "${SEQ:-0}" -gt "$prev_seq" ] || halt "no progress: remote seq still $prev_seq after impl (stage committed nothing, or did not push)" \
       "inspect: the impl run made no pushed journal entry" 1
  note "<<< advanced to seq=$SEQ (status=$STATUS, next=$NEXT)"
  render_board
  notify_hook card
done
