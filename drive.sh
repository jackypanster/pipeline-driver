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
#     CONTINUE iff NEXT == impl AND STATUS != blocked AND FROM != review
#                  AND LIVE_SPEC_REV == CONFIRMED_SPEC_REV
# Anything else halts and tells you exactly what to run next. FROM != review halts a
# review REJECTION (a human semantic decision) for a human read; the spec-rev clause
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
# per card. IMPL_TRANSPORT=orca instead sends "$IMPL_SLASH_CMD …" into a live
# Orca-managed TUI terminal (e.g. pi running GLM) and polls origin/<BRANCH> until
# the journal seq advances (or CARD_TIMEOUT). Same halt predicate, gates and
# guards either way — only the "run one card" primitive changes.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/parse-tail.awk"

SUBCMD=""
case "${1:-}" in doctor) SUBCMD=doctor; shift ;; esac
CONF="${1:-$HERE/drive.config}"
if [ "$SUBCMD" != "doctor" ]; then
  [ -f "$CONF" ] || { echo "drive.sh: config not found: $CONF" >&2; exit 2; }
fi
# Orca injects ORCA_TERMINAL_HANDLE (among other ORCA_*) into EVERY terminal it
# manages — including the one running this driver. Inheriting it would silently
# point the impl dispatch at the driver's own terminal. Config-file-only: SAVE the
# inherited value as "the terminal running THIS driver" so discovery can EXCLUDE it
# (a driver launched inside the target worktree would otherwise be a discovery
# candidate and type the stage command into itself), then drop it before sourcing.
DRIVER_SELF_TERMINAL="${ORCA_TERMINAL_HANDLE:-}"
unset ORCA_TERMINAL_HANDLE ORCA_TERMINAL_TITLE 2>/dev/null || true
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
IMPL_TRANSPORT="${IMPL_TRANSPORT:-claude}"          # claude | orca (see header)
ORCA_TERMINAL_HANDLE="${ORCA_TERMINAL_HANDLE:-}"    # explicit term_… handle (wins over discovery)
ORCA_TERMINAL_TITLE="${ORCA_TERMINAL_TITLE:-}"      # substring match on the tab title (disambiguator)
ORCA_IDLE_TIMEOUT_MS="${ORCA_IDLE_TIMEOUT_MS:-60000}"
ORCA_RESET_CMD="${ORCA_RESET_CMD:-}"                # optional per-card TUI reset (e.g. /new on pi); empty = off
IMPL_SLASH_CMD="${IMPL_SLASH_CMD:-/pipeline-impl}"  # stage command typed into the TUI (pi registers skills as /skill:pipeline-impl)
CARD_TIMEOUT="${CARD_TIMEOUT:-2700}"                # orca transport: max seconds to wait for one card
POLL_SECS="${POLL_SECS:-30}"                        # orca transport: journal poll interval
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
# Board auto-refresh: non-empty BOARD_OUT re-renders the read-only dashboard there
# after GATE 1, after every advanced card, and on halt. Best-effort side effect —
# a render failure never halts the loop.
BOARD_OUT="${BOARD_OUT:-}"
# One-key review relay (README §Board & review relay): when the loop halts at
# NEXT=review and a review terminal is configured, OFFER to type the review stage
# command into it — the human reads the halt and presses y. Never automatic; the
# GATE 2 merge confirm is untouched. Handle wins over title discovery.
REVIEW_TERMINAL_HANDLE="${REVIEW_TERMINAL_HANDLE:-}"
REVIEW_TERMINAL_TITLE="${REVIEW_TERMINAL_TITLE:-}"
REVIEW_SLASH_CMD="${REVIEW_SLASH_CMD:-/pipeline-review}"
JOURNAL=".pipeline/${FEATURE:-}/journal.md"
TASKS=".pipeline/${FEATURE:-}/tasks"

halt() { # <reason> <what-the-human-should-run-next> [exit-code]
  render_board   # the last board reflects the halt state (best-effort no-op when off)
  printf '\n=== DRIVER HALT ===\n%s\nNEXT (human): %s\n' "$1" "$2" >&2
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

git_q() { git -C "$WORKDIR" "$@"; }
show_origin() { git_q show "origin/$BRANCH:$1" 2>/dev/null; }   # read a path from the REMOTE ref

# ---- doctor ---------------------------------------------------------------------
# `drive.sh doctor` — one line per check, with the EXACT remediation command on a
# MISS. Installs nothing, touches no network (freshness is pipeline-update's job).
# MISS = blocks a drive run (exit 1). warn = degraded but drivable. info = context.
doctor() {
  local bad=0 warn=0 t slot terms
  d_ok()   { printf 'ok    %s\n' "$1"; }
  d_miss() { printf 'MISS  %s\n      fix: %s\n' "$1" "$2"; bad=$((bad+1)); }
  d_warn() { printf 'warn  %s\n      %s\n' "$1" "$2"; warn=$((warn+1)); }
  d_info() { printf 'info  %s\n' "$1"; }

  printf -- '--- deps ----------------------------------------------------------\n'
  if command -v git >/dev/null 2>&1; then d_ok "git on PATH"
  else d_miss "git not on PATH" "install git (xcode-select --install / your package manager)"; fi
  case "$IMPL_TRANSPORT" in
    orca)
      if command -v orca >/dev/null 2>&1; then d_ok "orca on PATH (IMPL_TRANSPORT=orca)"
      else d_miss "orca not on PATH but IMPL_TRANSPORT=orca" "install the Orca CLI, or set IMPL_TRANSPORT=claude"; fi
      if command -v jq >/dev/null 2>&1; then d_ok "jq on PATH (orca transport needs it)"
      else d_miss "jq not on PATH but IMPL_TRANSPORT=orca" "brew install jq"; fi ;;
    claude)
      if command -v claude >/dev/null 2>&1; then d_ok "claude on PATH (IMPL_TRANSPORT=claude)"
      else d_miss "claude not on PATH but IMPL_TRANSPORT=claude" "install Claude Code, or set IMPL_TRANSPORT=orca"; fi
      if command -v jq >/dev/null 2>&1; then d_ok "jq on PATH"
      else d_warn "jq not on PATH" "needed only for the orca transport + terminal listing: brew install jq"; fi ;;
    *)
      d_miss "unknown IMPL_TRANSPORT '$IMPL_TRANSPORT' (drive.sh would halt on it)" \
        "set IMPL_TRANSPORT=claude or orca in $DEFAULTS / drive.config" ;;
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
    if [ -f "$DASHBOARD_REPO/dist/cli.js" ]; then d_ok "dashboard built (dist/cli.js)"
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
            d_ok "impl slot '$slot' present in $SKILLS_DIR (verify the impl runtime is attached to it)"
          else
            d_warn "impl slot '$slot' not in $SKILLS_DIR" \
              "install it there + attach the impl runtime (pipeline README §Verify dependencies)"
          fi
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

  # Live Orca terminals (info only): where to pin ORCA_TERMINAL_HANDLE from.
  if command -v orca >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    terms=$(orca terminal list --json 2>/dev/null \
      | jq -r '.result.terminals[]? | "\(.handle)\t\(.title)\t\(.worktreePath)"' 2>/dev/null || true)
    if [ -n "${terms:-}" ]; then
      d_info "live Orca terminals (pin ORCA_TERMINAL_HANDLE from here; handles die on app restart):"
      printf '%s\n' "$terms" | sed 's/^/      /'
    fi
  fi

  printf -- '---------------------------------------------------------------------\n'
  printf 'doctor: %d blocking, %d warning(s)\n' "$bad" "$warn"
  [ "$bad" -eq 0 ]
}
if [ "$SUBCMD" = "doctor" ]; then doctor; exit $?; fi

# ---- orca transport helpers -----------------------------------------------------
# Resolve the impl terminal: explicit handle > (worktree==WORKDIR + connected+writable,
# optionally narrowed by a title substring). Exactly ONE match required — the driver
# must never type into an ambiguous terminal.
resolve_orca_terminal() {
  if [ -n "$ORCA_TERMINAL_HANDLE" ]; then
    # A pinned handle must never be the driver's own terminal (config error).
    if [ -n "${DRIVER_SELF_TERMINAL:-}" ] && [ "$ORCA_TERMINAL_HANDLE" = "$DRIVER_SELF_TERMINAL" ]; then
      note "orca: ORCA_TERMINAL_HANDLE equals the terminal running drive.sh — the driver cannot type into itself"
      return 1
    fi
    printf '%s\n' "$ORCA_TERMINAL_HANDLE"; return 0
  fi
  local js n
  js=$(orca terminal list --json 2>/dev/null) \
    || { note "orca: 'terminal list' failed — is the Orca runtime running? (orca status)"; return 1; }
  # Exclude the driver's own terminal: when drive.sh runs inside an Orca terminal in
  # the target worktree, it would otherwise match its own discovery filter.
  js=$(printf '%s' "$js" | jq --arg wd "$WORKDIR" --arg t "$ORCA_TERMINAL_TITLE" --arg self "${DRIVER_SELF_TERMINAL:-}" \
        '[.result.terminals[]? | select(.worktreePath==$wd and .connected and .writable)
          | select(.handle != $self)
          | select(($t=="") or (.title | contains($t)))]') || return 1
  n=$(printf '%s' "$js" | jq 'length')
  case "$n" in
    1) printf '%s' "$js" | jq -r '.[0].handle' ;;
    0) note "orca: no connected writable terminal for worktree $WORKDIR${ORCA_TERMINAL_TITLE:+ with title ~ '$ORCA_TERMINAL_TITLE'} (the driver's own terminal is excluded)"; return 1 ;;
    *) note "orca: $n terminals match in $WORKDIR — rename the impl tab and set ORCA_TERMINAL_TITLE, or set ORCA_TERMINAL_HANDLE"; return 1 ;;
  esac
}

remote_seq() {   # seq of the LAST journal entry on origin/<BRANCH>; empty output on parse failure
  local J
  J=$(show_origin "$JOURNAL") || return 1
  printf '%s' "$J" | awk -f "$AWK" | sed -n 's/^SEQ=\([0-9][0-9]*\);.*/\1/p'
}

# ---- one-key review relay ---------------------------------------------------------
# Resolve the REVIEW terminal: pinned handle > title-substring discovery (title is
# REQUIRED for discovery here — the review TUI usually sits in a different worktree,
# so the impl transport's worktree filter does not apply). Exactly ONE match.
resolve_review_terminal() {
  if [ -n "$REVIEW_TERMINAL_HANDLE" ]; then
    if [ -n "${DRIVER_SELF_TERMINAL:-}" ] && [ "$REVIEW_TERMINAL_HANDLE" = "$DRIVER_SELF_TERMINAL" ]; then
      note "review relay: REVIEW_TERMINAL_HANDLE is the terminal running drive.sh itself"
      return 1
    fi
    printf '%s\n' "$REVIEW_TERMINAL_HANDLE"; return 0
  fi
  [ -n "$REVIEW_TERMINAL_TITLE" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local js n
  js=$(orca terminal list --json 2>/dev/null) || return 1
  js=$(printf '%s' "$js" | jq --arg t "$REVIEW_TERMINAL_TITLE" --arg self "${DRIVER_SELF_TERMINAL:-}" \
        '[.result.terminals[]? | select(.connected and .writable)
          | select(.handle != $self)
          | select(.title | contains($t))]') || return 1
  n=$(printf '%s' "$js" | jq 'length')
  [ "$n" = "1" ] || { note "review relay: $n terminals match title ~ '$REVIEW_TERMINAL_TITLE' — pin REVIEW_TERMINAL_HANDLE"; return 1; }
  printf '%s' "$js" | jq -r '.[0].handle'
}

# At the NEXT=review halt: OFFER to type the review stage command into the review
# terminal (e.g. codex). The human reads the halt and answers y — this automates the
# TYPING of the relay, not the decision (README §Board & review relay; the pipeline's
# review stage itself, incl. the human merge confirm, is unchanged). Skipped silently
# when unconfigured; every failure degrades to relay-by-hand.
offer_review_relay() {
  [ -n "$REVIEW_TERMINAL_HANDLE$REVIEW_TERMINAL_TITLE" ] || return 0
  command -v orca >/dev/null 2>&1 || { note "review relay: orca not on PATH — relay by hand"; return 0; }
  local h a
  h=$(resolve_review_terminal) || { note "review relay: cannot resolve the review terminal — relay by hand"; return 0; }
  printf 'review relay — send "%s repo=%s branch=%s" to terminal %s? [y/N] ' \
    "$REVIEW_SLASH_CMD" "$WORKDIR" "$BRANCH" "$h" >&2
  read -r a || { note "review relay: no answer — relay by hand"; return 0; }
  case "$a" in
    y|Y)
      orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$ORCA_IDLE_TIMEOUT_MS" >/dev/null 2>&1 \
        || { note "review relay: terminal $h not idle within ${ORCA_IDLE_TIMEOUT_MS}ms — relay by hand"; return 0; }
      if orca terminal send --terminal "$h" --text "$REVIEW_SLASH_CMD repo=$WORKDIR branch=$BRANCH" --enter >/dev/null 2>&1; then
        note "review relay: sent — GATE 2 ahead (semantic review + HUMAN merge confirm; the driver never merges)"
      else
        note "review relay: 'terminal send' failed for $h — relay by hand"
      fi ;;
    *) note "review relay: skipped — relay by hand" ;;
  esac
  return 0
}

# ---- preflight ----------------------------------------------------------------
case "$IMPL_TRANSPORT" in
  claude)
    command -v claude >/dev/null 2>&1 || halt "claude CLI not on PATH" "install Claude Code, then re-run" 2 ;;
  orca)
    command -v orca >/dev/null 2>&1 || halt "orca CLI not on PATH (IMPL_TRANSPORT=orca)" "install the Orca CLI, then re-run" 2
    command -v jq   >/dev/null 2>&1 || halt "jq not on PATH (IMPL_TRANSPORT=orca needs it)" "install jq, then re-run" 2 ;;
  *) halt "unknown IMPL_TRANSPORT '$IMPL_TRANSPORT'" "set IMPL_TRANSPORT=claude or orca in drive.config" 2 ;;
esac
git_q rev-parse --git-dir >/dev/null 2>&1 || halt "WORKDIR is not a git repo: $WORKDIR" "clone the target repo there" 2
git_q fetch origin --quiet || halt "git fetch origin failed (network / auth)" "fix connectivity, re-run" 1

# Render the settings with the absolute hook path (--bare ignores project hooks; the
# hook MUST travel in --settings). Process-local temp; cleaned on exit.
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

# Orca transport: resolve the impl terminal NOW so a bad setup halts before GATE 1.
# (run_impl_orca re-resolves per card — handles churn when tabs close/reopen.)
if [ "$IMPL_TRANSPORT" = "orca" ]; then
  _h=$(resolve_orca_terminal) || halt "cannot resolve the impl terminal in Orca (worktree: $WORKDIR)" \
      "open the coder TUI in an Orca terminal for that worktree; disambiguate with ORCA_TERMINAL_TITLE or ORCA_TERMINAL_HANDLE" 2
  note "orca transport: impl terminal = $_h"
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
    claude --bare \
      --settings "$RENDERED" \
      --permission-mode dontAsk \
      --model "$IMPL_MODEL" \
      -p "/pipeline-impl repo=$WORKDIR branch=$BRANCH"
  )
}

# Orca transport: type the stage command into the live TUI terminal, then treat the
# REMOTE journal as the only completion signal — poll origin until seq advances or
# CARD_TIMEOUT. No exit code exists here; the deny-merge --settings hook does NOT
# travel into the TUI agent (the durable gates — halt-before-review + human merge +
# trunk rules — hold regardless).
run_impl_orca() {
  local handle start s
  handle=$(resolve_orca_terminal) || return 1
  if [ -n "$ORCA_RESET_CMD" ]; then
    # The idle guard is as load-bearing here as for the real send: typing the reset
    # into a BUSY TUI could corrupt an in-flight card. A wait timeout is fatal.
    orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms "$ORCA_IDLE_TIMEOUT_MS" >/dev/null 2>&1 \
      || { note "orca: terminal $handle not idle within ${ORCA_IDLE_TIMEOUT_MS}ms (before reset)"; return 1; }
    orca terminal send --terminal "$handle" --text "$ORCA_RESET_CMD" --enter >/dev/null 2>&1 \
      || { note "orca: reset send failed for $handle"; return 1; }
  fi
  orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms "$ORCA_IDLE_TIMEOUT_MS" >/dev/null 2>&1 \
    || { note "orca: terminal $handle not idle within ${ORCA_IDLE_TIMEOUT_MS}ms"; return 1; }
  orca terminal send --terminal "$handle" --text "$IMPL_SLASH_CMD repo=$WORKDIR branch=$BRANCH" --enter >/dev/null 2>&1 \
    || { note "orca: 'terminal send' failed for $handle"; return 1; }
  start=$SECONDS
  while [ $((SECONDS - start)) -lt "$CARD_TIMEOUT" ]; do
    sleep "$POLL_SECS"
    git_q fetch origin --quiet || true          # transient fetch error: keep polling
    s=$(remote_seq) || s=""
    if [ -n "$s" ] && [ "$s" -gt "$prev_seq" ]; then return 0; fi
  done
  note "orca transport: no journal progress within ${CARD_TIMEOUT}s — impl terminal tail:"
  orca terminal read --terminal "$handle" 2>/dev/null | tail -20 >&2 || true
  return 1
}

run_impl() {
  case "$IMPL_TRANSPORT" in
    orca) run_impl_orca ;;
    *)    run_impl_claude ;;
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

if [ "$IMPL_TRANSPORT" = "orca" ]; then
  note "Feature : $FEATURE   (trunk=$BRANCH)   impl transport=orca (live TUI terminal)"
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
  # re-drive a card a reviewer just bounced — halt so the human sees the verdict first.
  if [ "${FROM:-}" = "review" ] && [ "$NEXT" = "impl" ]; then
    halt "review rejected a card and routed it back to impl (seq=$SEQ) — a human semantic decision" \
         "read .pipeline/$FEATURE/reviews/*, then re-run drive.sh to resume the fix" 0
  fi

  # --- HALT PREDICATE ---
  if [ "$NEXT" != "impl" ] || [ "${STATUS}" = "blocked" ]; then
    case "$NEXT" in
      review) offer_review_relay
              halt "all cards in review (seq=$SEQ) — feature complete, human merge gate ahead" "pipeline-review (frontier, semantic review + merge confirm)" 0 ;;
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
  if [ "$IMPL_TRANSPORT" = "orca" ]; then
    note ">>> impl dispatch via orca terminal (after seq=$prev_seq) ..."
    if ! run_impl; then
      halt "the driven pipeline-impl made no journal progress after seq=$prev_seq (terminal error or card timeout)" \
           "inspect the impl terminal in Orca; pipeline-impl (manual) or pipeline-hunt" 1
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
done
