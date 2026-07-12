#!/usr/bin/env bash
# review-drive.sh — the deterministic review↔fix loop driver for TOOLCHAIN-repo PRs
# (the pipeline meta-repo and its siblings). The second — and last — sanctioned
# exception to "no scheduler": authorized in the canonical design (pipeline
# DESIGN.md §Constraints, amended via its own gated meta-PR lane; the first
# exception is drive.sh's impl loop). The review it relays IS pipeline-review in
# meta-PR mode (CONTRACT.md §Self-improvement): the loop automates the TYPING
# between verdicts, never the review, never the merge.
#
# WHAT IT IS: a forbidden-to-be-smart code loop that shuttles ONE PR between a
# reviewer TUI (e.g. codex) and a fixer TUI (e.g. pi) until the reviewer approves,
# a round cap / no-progress detector fires, or anything unexpected happens — then
# HALTS with a per-round digest for the human. It holds ZERO authoritative state —
# the GitHub PR (head SHA + comment protocol lines) is the single source of truth.
#
# WHAT IT IS NOT: a feature-pipeline scheduler. The 5-stage contract's review gate
# (pipeline-review + the HUMAN merge confirm) stays human-relayed by design — this
# loop never merges, never approves via GitHub reviews, never touches a target
# repo's .pipeline/ state. Scope: PRs on the toolchain repos only.
#
# WHY COMMENTS, NOT GitHub REVIEWS: reviewer and fixer share one account, and
# GitHub forbids approve/request-changes on your own PR — so the verdict travels
# as machine-readable protocol lines in a plain PR comment (same family as the
# spec-rev echo and the ">>> NEXT" handoff):
#
#   reviewer comment:   verdict: approved | changes-requested
#                       reviewed-head: <the FULL 40-char sha it reviewed>
#                       reviewed-base: <the FULL 40-char base tip it reviewed against>
#                       findings: <count>
#                       review-nonce: <echo of this dispatch's nonce>
#                       ...then the findings (file:line + failure scenario)
#   fixer comment:      fixed: <the FULL 40-char new head sha>
#                       fix-nonce: <echo of this dispatch's nonce>
#                       ...then per-finding evidence
#
# Protocol comments are AUTHENTICATED twice over: only comments authored by the
# gh-authenticated login (override: PROTOCOL_AUTHOR) parse at all — a drive-by
# "verdict: approved" is inert text — and within the shared account the ROLES are
# separated by per-dispatch nonces typed only into that role's terminal, so the
# fixer cannot forge a verdict, the reviewer cannot forge a fix, and no stale
# comment steers the LIVE loop (live acceptance always demands the current
# dispatch's nonce; ACROSS sessions, where nonces are unknowable, history is
# folded fail-closed — see resume below). SHA echoes bind exactly (full 40
# chars, string equality — never a prefix), and a verdict must name BOTH the
# head and the base tip it reviewed. The scope is ENFORCED, not just
# documented: the PR's repo must match REVIEW_REPO_RE (default: the pipeline
# toolchain repos), fork (cross-repository) PRs are refused at preflight, the
# review dispatch's first token must invoke pipeline-review (REVIEW_SLASH_CMD,
# required non-empty), and WRITE instructions go to the fixer terminal only
# after its worktree is PROVEN to be this PR's repo on the PR's topic branch,
# CLEAN, and synced to exactly the round's live head.
#
# The TUIs never talk to each other and the driver never forwards review TEXT —
# each side reads the PR itself via gh; orca only types the dispatch line
# (medium is git, per the operator's SOP). Completion signals are PR facts:
# a new protocol comment (scanned by comment-INDEX baseline, immune to clock skew
# between this machine and GitHub), an advanced head SHA whose history still
# CONTAINS the reviewed head (a diverged compare = force-push/rebase = halt) and
# whose value the fixer's `fixed:` line must echo, and a base OID pinned per
# review round (a moved base = the verdict binds a stale merge-base = halt).
# Kill+restart RESUMES fail-closed: prior same-author verdicts are folded ONLY
# into quantities they can TIGHTEN (round budget, no-progress streak, digest) —
# never into approval or phase, because a prior session's nonces are unknowable
# and an unauthenticated history must not steer anything. The streak only ever
# GROWS from history: a findings decrease is proven — and resets it — solely
# between two LIVE nonce-bound verdicts. A restart therefore always re-reviews
# the live head/base with a fresh nonce.
#
# HALT PREDICATE (the whole brain — halt table: stop-points.md §review-drive):
#     CONTINUE iff verdict == changes-requested AND round < MAX_ROUNDS
#                  AND findings decreased within the last 2 reviews
#                  AND the PR is OPEN, un-conflicted, and nobody else pushed
#
# Usage:  ./review-drive.sh <pr-number-or-url> [path/to/review-drive.config]
#
# CONFIG LAYERING: same as drive.sh — the optional global defaults file
# (${XDG_CONFIG_HOME:-~/.config}/pipeline-driver/drive.defaults) is sourced BEFORE
# the per-run config, so terminal titles and tuning live in one place. The reviewer
# terminal shares drive.sh's REVIEW_TERMINAL_HANDLE/TITLE; the fixer terminal is
# FIX_TERMINAL_HANDLE/TITLE. Pin HANDLES per run — titles go stale (field-tested).

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

PR_ARG="${1:-}"
[ -n "$PR_ARG" ] || { echo "usage: review-drive.sh <pr-number-or-url> [config]" >&2; exit 2; }
CONF="${2:-$HERE/review-drive.config}"

# Orca injects ORCA_TERMINAL_HANDLE into EVERY terminal it manages — including the
# one running this driver. Save it as "self" so resolution can exclude it, then drop
# it before sourcing config (same dance as drive.sh, same reason).
DRIVER_SELF_TERMINAL="${ORCA_TERMINAL_HANDLE:-}"
unset ORCA_TERMINAL_HANDLE ORCA_TERMINAL_TITLE 2>/dev/null || true

DEFAULTS="${DRIVE_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/pipeline-driver/drive.defaults}"
# shellcheck disable=SC1090
[ -f "$DEFAULTS" ] && . "$DEFAULTS"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# ---- config defaults ------------------------------------------------------------
REVIEW_REPO="${REVIEW_REPO:-jackypanster/pipeline}"  # owner/repo for a bare PR number
# The sanctioned scope, enforced at preflight: the PR's owner/repo must match this ERE.
REVIEW_REPO_RE="${REVIEW_REPO_RE:-^jackypanster/pipeline(-driver|-dashboard|-dispatch)?$}"
PROTOCOL_AUTHOR="${PROTOCOL_AUTHOR:-}"  # login whose comments carry protocol; default: the gh-authenticated user
MAX_ROUNDS="${MAX_ROUNDS:-5}"          # hard cap on REVIEW rounds (so at most MAX_ROUNDS-1 fixes)
HUNT_AFTER="${HUNT_AFTER:-3}"          # fix dispatch >= this switches to the root-cause template
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-2700}"   # max seconds to wait for one verdict comment
FIX_TIMEOUT="${FIX_TIMEOUT:-2700}"         # max seconds to wait for one pushed fix + evidence
POLL_SECS="${POLL_SECS:-30}"
ORCA_IDLE_TIMEOUT_MS="${ORCA_IDLE_TIMEOUT_MS:-60000}"
REVIEW_TERMINAL_HANDLE="${REVIEW_TERMINAL_HANDLE:-}"   # reviewer TUI (e.g. codex) — shared with drive.sh's relay
REVIEW_TERMINAL_TITLE="${REVIEW_TERMINAL_TITLE:-}"
FIX_TERMINAL_HANDLE="${FIX_TERMINAL_HANDLE:-}"         # fixer TUI (e.g. pi)
FIX_TERMINAL_TITLE="${FIX_TERMINAL_TITLE:-}"
# Skill invocation for the review dispatch — REQUIRED non-empty: the canonical
# authorization (pipeline DESIGN.md §Constraints) is conditional on the relayed
# review BEING pipeline-review in meta-PR mode, so the dispatch's first token must
# be the reviewer runtime's skill command. Shared with drive.sh's one-key relay.
# Claude-style default; codex >=0.144 wants '$pipeline-review' (single-quote it).
# The `-` (not `:-`) default keeps an explicitly-emptied value visible to preflight.
REVIEW_SLASH_CMD="${REVIEW_SLASH_CMD-/pipeline-review}"

# ---- PR identity ------------------------------------------------------------------
case "$PR_ARG" in
  https://github.com/*/pull/*)
    REPO_SLUG="${PR_ARG#https://github.com/}"; REPO_SLUG="${REPO_SLUG%%/pull/*}"
    PR="${PR_ARG##*/pull/}"; PR="${PR%%[!0-9]*}" ;;
  *[!0-9]*) echo "review-drive: PR must be a number or a github.com PR URL: $PR_ARG" >&2; exit 2 ;;
  *) REPO_SLUG="$REVIEW_REPO"; PR="$PR_ARG" ;;
esac
[ -n "$PR" ] || { echo "review-drive: cannot parse a PR number from: $PR_ARG" >&2; exit 2; }
printf '%s' "$REPO_SLUG" | grep -Eq "$REVIEW_REPO_RE" || {
  echo "review-drive: $REPO_SLUG is outside the sanctioned toolchain scope (REVIEW_REPO_RE=$REVIEW_REPO_RE)" >&2
  echo "              feature work goes through the 5-stage pipeline, never this loop" >&2
  exit 2
}
PR_URL="https://github.com/$REPO_SLUG/pull/$PR"

note() { printf '%s\n' "$*" >&2; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# 16 hex chars, regex-safe; EMPTY output on any failure (callers halt on empty) —
# the braces + || true keep set -e/pipefail from killing the run before the HALT.
nonce() { { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; } 2>/dev/null || true; }
DIGEST=""   # one row per review round, printed on every halt

halt() { # <reason> <what-the-human-should-run-next> [exit-code]
  printf '\n=== REVIEW-DRIVE HALT (PR #%s, %s) ===\n' "$PR" "$REPO_SLUG" >&2
  if [ -n "$DIGEST" ]; then
    printf 'round  verdict            findings  reviewed-head  comment\n%s\n' "$DIGEST" >&2
  fi
  printf '%s\nNEXT (human): %s\n' "$1" "$2" >&2
  exit "${3:-0}"
}

# ---- gh/jq helpers (the PR is the only state bus) ----------------------------------
pr_snap() {   # one JSON snapshot; empty output on a transient gh failure (caller keeps polling)
  gh pr view "$PR" -R "$REPO_SLUG" --json state,mergeable,headRefOid,headRefName,baseRefName,baseRefOid,isCrossRepository,title,comments 2>/dev/null || true
}
snap_field() { printf '%s' "$1" | jq -r ".$2"; }
comment_count() { printf '%s' "$1" | jq -r '.comments | length'; }

# Protocol scans are AUTHENTICATED twice over: (1) only comments authored by $WHO
# count — any other author's "verdict:"/"fixed:" line is inert text; (2) within the
# shared account, ROLES are separated by per-dispatch nonces — a verdict must echo
# the review-nonce typed only into the reviewer terminal, a fix the fix-nonce typed
# only into the fixer terminal, so neither side can forge the other's protocol
# (and a stale comment from an earlier round/session can never replay).
# SHA echoes capture the FULL 40 chars — prefixes never parse.
# NOTE jq regexes anchor ^ to the STRING start only (its "m" flag is dotall,
# not multiline anchors) — line-leading is spelled (?:^|\n) throughout.

# Last authenticated comment at index >= $2 echoing review-nonce $3, with a
# "verdict:" line. TSV: verdict, reviewed-head (or "none"), reviewed-base (or
# "none"), findings (or "-"), url.
scan_verdict() {
  printf '%s' "$1" | jq -r --argjson idx "$2" --arg who "$WHO" --arg nonce "$3" '
    .comments[$idx:]
    | map(select((.author.login // "") == $who))
    | map(select(.body | test("(?:^|\\n)review-nonce: *" + $nonce)))
    | map(select(.body | test("(?:^|\\n)verdict: *(approved|changes-requested)")))
    | last // empty
    | [ (.body | capture("(?:^|\\n)verdict: *(?<v>approved|changes-requested)").v),
        ((.body | capture("(?:^|\\n)reviewed-head: *(?<h>[0-9a-fA-F]{40})").h) // "none"),
        ((.body | capture("(?:^|\\n)reviewed-base: *(?<b>[0-9a-fA-F]{40})").b) // "none"),
        ((.body | capture("(?:^|\\n)findings: *(?<n>[0-9]+)").n) // "-"),
        .url ]
    | @tsv'
}
# EVERY authenticated verdict comment on the thread (index 0), one TSV row each —
# the resume path rebuilds rounds/history/digest from this. No nonce filter: prior
# sessions' nonces are unknowable; history informs the budget and the phase, while
# LIVE acceptance always demands the current dispatch's nonce.
scan_all_verdicts() {
  printf '%s' "$1" | jq -r --arg who "$WHO" '
    .comments
    | map(select((.author.login // "") == $who))
    | map(select(.body | test("(?:^|\\n)verdict: *(approved|changes-requested)")))
    | .[]
    | [ (.body | capture("(?:^|\\n)verdict: *(?<v>approved|changes-requested)").v),
        ((.body | capture("(?:^|\\n)reviewed-head: *(?<h>[0-9a-fA-F]{40})").h) // "none"),
        ((.body | capture("(?:^|\\n)findings: *(?<n>[0-9]+)").n) // "-"),
        .url ]
    | @tsv'
}
# Last authenticated comment at index >= $2 echoing fix-nonce $3, with a "fixed:"
# line. TSV: sha, url.
scan_fixed() {
  printf '%s' "$1" | jq -r --argjson idx "$2" --arg who "$WHO" --arg nonce "$3" '
    .comments[$idx:]
    | map(select((.author.login // "") == $who))
    | map(select(.body | test("(?:^|\\n)fix-nonce: *" + $nonce)))
    | map(select(.body | test("(?:^|\\n)fixed: *[0-9a-fA-F]{40}")))
    | last // empty
    | [ ((.body | capture("(?:^|\\n)fixed: *(?<s>[0-9a-fA-F]{40})").s) // "none"), .url ]
    | @tsv'
}

# The fixed head must still CONTAIN the reviewed head — "ahead" is the only clean
# continuation; "diverged"/"behind" means force-push/rebase rewrote reviewed history.
compare_status() { gh api "repos/$REPO_SLUG/compare/$1...$2" 2>/dev/null | jq -r '.status // "unknown"'; }

# PR liveness, checked on every poll tick: anything but OPEN is a human-level event.
assert_open() {   # $1 = snapshot
  case "$(snap_field "$1" state)" in
    OPEN) : ;;
    MERGED) halt "PR was merged out from under the loop" "nothing — verify the merge was intended" 0 ;;
    CLOSED) halt "PR was closed mid-loop" "reopen it or drop the run" 0 ;;
    *) : ;;    # transient/empty snapshot: caller keeps polling
  esac
}

# ---- terminal resolution (pinned handle > unique title; never self; never shared) --
resolve_terminal() {   # <role> <handle> <title>
  local role="$1" handle="$2" title="$3" js n
  if [ -n "$handle" ]; then
    if [ -n "${DRIVER_SELF_TERMINAL:-}" ] && [ "$handle" = "$DRIVER_SELF_TERMINAL" ]; then
      note "$role: pinned handle is the terminal running review-drive itself"; return 1
    fi
    printf '%s\n' "$handle"; return 0
  fi
  [ -n "$title" ] || { note "$role: set a *_TERMINAL_HANDLE (preferred) or *_TERMINAL_TITLE"; return 1; }
  js=$(orca terminal list --json 2>/dev/null) \
    || { note "$role: 'orca terminal list' failed — is the Orca runtime running?"; return 1; }
  js=$(printf '%s' "$js" | jq --arg t "$title" --arg self "${DRIVER_SELF_TERMINAL:-}" \
        '[.result.terminals[]? | select(.connected and .writable)
          | select(.handle != $self)
          | select((.title // "") | contains($t))]') || return 1
  n=$(printf '%s' "$js" | jq 'length')
  [ "$n" = "1" ] || { note "$role: $n terminals match title ~ '$title' — pin the handle"; return 1; }
  printf '%s' "$js" | jq -r '.[0].handle'
}

send_to() {   # <handle> <text> — idle guard is load-bearing: never type into a busy TUI
  orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$ORCA_IDLE_TIMEOUT_MS" >/dev/null 2>&1 \
    || { note "orca: terminal $1 not idle within ${ORCA_IDLE_TIMEOUT_MS}ms"; return 1; }
  orca terminal send --terminal "$1" --text "$2" --enter >/dev/null 2>&1 \
    || { note "orca: 'terminal send' failed for $1"; return 1; }
}

tail_of() { orca terminal read --terminal "$1" 2>/dev/null | tail -20 >&2 || true; }

# A pinned handle is not an identity. Cheap liveness: the handle must be present,
# connected and writable in the CURRENT orca listing (handles die on app restart).
handle_live() {   # <handle>
  local n
  n=$(orca terminal list --json 2>/dev/null \
      | jq --arg h "$1" '[.result.terminals[]? | select(.handle==$h and .connected and .writable)] | length' 2>/dev/null) || n=0
  [ "${n:-0}" = "1" ]
}
# Strong identity for the FIXER — the terminal that receives WRITE-and-push
# instructions: its orca worktreePath must be a git checkout whose origin IS this
# PR's repo — and, when $1=1 (re-proved before EVERY fix dispatch), sitting on the
# PR's topic branch with a CLEAN working tree whose HEAD IS the live PR head ($2):
# a stale checkout would build the fix on the wrong base, a dirty one would mix
# unrelated state into pushed commits. Any unprovable step fails closed; a stale
# or mistyped handle must never be typed write instructions for an unrelated or
# unsynced checkout.
verify_fixer_worktree() {   # <check_branch: 0|1> [expected_head]
  local wt url slug_re br st hd
  wt=$(orca terminal list --json 2>/dev/null \
       | jq -r --arg h "$FIXER" '[.result.terminals[]? | select(.handle==$h)][0].worktreePath // ""' 2>/dev/null) || wt=""
  [ -n "$wt" ] || { note "fixer worktree: terminal $FIXER has no worktreePath in the live orca listing"; return 1; }
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) \
    || { note "fixer worktree: $wt is not a git checkout with an origin remote"; return 1; }
  slug_re=$(printf '%s' "$REPO_SLUG" | sed 's/[.[\*^$()+?{|]/\\&/g')
  printf '%s' "$url" | grep -Eq "(^|[@/])github\.com[:/]${slug_re}(\.git)?/?$" \
    || { note "fixer worktree: $wt origin '$url' is not $REPO_SLUG"; return 1; }
  if [ "$1" = "1" ]; then
    br=$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null) || br=""
    [ "$br" = "$HEAD_REF" ] \
      || { note "fixer worktree: $wt is on '${br:-<detached>}', not the PR branch '$HEAD_REF'"; return 1; }
    st=$(git -C "$wt" status --porcelain 2>/dev/null) || st="<unreadable>"
    [ -z "$st" ] \
      || { note "fixer worktree: $wt is not clean (uncommitted/untracked changes) — a fix would mix unrelated state"; return 1; }
    hd=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || hd=""
    [ "$hd" = "${2:-}" ] \
      || { note "fixer worktree: $wt HEAD ${hd:-<none>} is not the live PR head ${2:-<unset>} — sync the checkout first"; return 1; }
  fi
  return 0
}

# ---- preflight ---------------------------------------------------------------------
for dep in gh jq orca git; do
  command -v "$dep" >/dev/null 2>&1 || halt "$dep not on PATH" "install $dep, then re-run" 2
done
[ -n "$REVIEW_SLASH_CMD" ] \
  || halt "REVIEW_SLASH_CMD is empty — the relayed review MUST invoke pipeline-review (meta-PR mode), never generic prose" \
          "set it: claude-style '/pipeline-review', codex '\$pipeline-review' (single-quoted)" 2
[ -n "$(nonce)" ] \
  || halt "cannot generate dispatch nonces (od / tr / /dev/urandom unavailable)" "fix the environment, then re-run" 2
# Numeric config must be sane BEFORE anything is dispatched — a bad value would
# otherwise break arithmetic or disarm a timeout mid-loop. Fail here, fail closed.
for v in MAX_ROUNDS HUNT_AFTER REVIEW_TIMEOUT FIX_TIMEOUT POLL_SECS ORCA_IDLE_TIMEOUT_MS; do
  eval "val=\${$v}"
  is_num "$val" || halt "config: $v='$val' is not a non-negative integer" "fix it in $DEFAULTS / $CONF" 2
done
{ [ "$MAX_ROUNDS" -ge 1 ] && [ "$HUNT_AFTER" -ge 1 ] && [ "$REVIEW_TIMEOUT" -ge 1 ] \
  && [ "$FIX_TIMEOUT" -ge 1 ] && [ "$ORCA_IDLE_TIMEOUT_MS" -ge 1 ]; } \
  || halt "config: MAX_ROUNDS, HUNT_AFTER, REVIEW_TIMEOUT, FIX_TIMEOUT and ORCA_IDLE_TIMEOUT_MS must all be >= 1 (only POLL_SECS may be 0)" \
          "fix the offending value in $DEFAULTS / $CONF" 2
# The identity whose comments carry protocol — reviewer and fixer both post through
# the operator's gh auth, so the default is the authenticated login itself.
WHO="${PROTOCOL_AUTHOR:-$(gh api user 2>/dev/null | jq -r '.login // empty')}"
[ -n "$WHO" ] || halt "cannot resolve the gh-authenticated login (protocol-comment authentication needs it)" \
  "check 'gh auth status', or set PROTOCOL_AUTHOR" 2
REVIEWER=$(resolve_terminal "reviewer" "$REVIEW_TERMINAL_HANDLE" "$REVIEW_TERMINAL_TITLE") \
  || halt "cannot resolve the REVIEWER terminal" "open the reviewer TUI in Orca; pin REVIEW_TERMINAL_HANDLE" 2
FIXER=$(resolve_terminal "fixer" "$FIX_TERMINAL_HANDLE" "$FIX_TERMINAL_TITLE") \
  || halt "cannot resolve the FIXER terminal" "open the fixer TUI in Orca; pin FIX_TERMINAL_HANDLE" 2
[ "$REVIEWER" != "$FIXER" ] \
  || halt "reviewer and fixer resolve to the SAME terminal ($REVIEWER)" "pin two distinct handles" 2
handle_live "$REVIEWER" \
  || halt "reviewer terminal $REVIEWER is not live+writable in the current orca listing (handles die on app restart)" \
          "re-pin REVIEW_TERMINAL_HANDLE from 'orca terminal list --json'" 2
handle_live "$FIXER" \
  || halt "fixer terminal $FIXER is not live+writable in the current orca listing (handles die on app restart)" \
          "re-pin FIX_TERMINAL_HANDLE from 'orca terminal list --json'" 2

SNAP=$(pr_snap)
[ -n "$SNAP" ] || halt "cannot read PR #$PR on $REPO_SLUG via gh" "check gh auth / the PR number" 2
assert_open "$SNAP"
[ "$(snap_field "$SNAP" isCrossRepository)" != "true" ] \
  || halt "PR #$PR is a FORK (cross-repository) PR — foreign head, no fixer push path" \
          "review fork PRs by hand; this loop only drives same-repo toolchain branches" 2
HEAD_REF=$(snap_field "$SNAP" headRefName)
BASE_REF=$(snap_field "$SNAP" baseRefName)
verify_fixer_worktree 0 \
  || halt "cannot prove the fixer terminal's worktree is a checkout of $REPO_SLUG" \
          "open the fixer TUI in the PR repo's checkout; re-pin FIX_TERMINAL_HANDLE from the live listing" 2

# ---- start gate: bind the confirmation to the PR (wrong-PR accidents die here) ------
note "PR      : #$PR $PR_URL"
note "title   : $(snap_field "$SNAP" title)"
note "branch  : $HEAD_REF -> $BASE_REF   head=$(snap_field "$SNAP" headRefOid | cut -c1-7)"
note "loop    : MAX_ROUNDS=$MAX_ROUNDS  HUNT_AFTER=$HUNT_AFTER  reviewer=$REVIEWER  fixer=$FIXER"
note "gates   : the loop never merges; 'verdict: approved' halts for the meta-PR merge gate (human-confirm + reviewer-only squash-merge)"
printf 'GATE — type the PR number above to start the loop: ' >&2
read -r ACK || halt "the start gate needs an interactive terminal (stdin closed)" "run attached to a TTY" 2
[ "$ACK" = "$PR" ] || halt "PR number not confirmed (got '$ACK')" "re-run with the intended PR" 2

# ---- resume: rebuild the LOOP BUDGET from the PR thread itself -------------------------
# One shared account cannot authenticate ACROSS sessions (a prior session's nonces
# are unknowable), so history is folded FAIL-CLOSED: same-author verdict comments
# count ONLY toward the round budget, the no-progress streak and the digest —
# quantities a forged or nonce-less comment can only TIGHTEN, never loosen. History
# never approves and never picks a phase: a restart always re-reviews the live
# head/base with a fresh nonce, so no stale verdict — approval or rejection — can
# steer a new session.
rounds_done=0
prev_findings=""      # findings value from the previous review ("-" = unparseable)
prev_auth=0           # 1 iff prev_findings came from a LIVE nonce-bound verdict
have_prior=0          # 1 once any verdict has been consumed (resumed or live)
nondrop_streak=0      # consecutive reviews without a PROVEN decrease in findings
last_verdict=""
while IFS=$(printf '\t') read -r v h n u; do
  [ -n "$v" ] || continue
  rounds_done=$((rounds_done + 1))
  DIGEST="$DIGEST$(printf '%-6s %-18s %-9s %-14s %s' "$rounds_done" "$v" "$n" "$(printf '%s' "$h" | cut -c1-7)" "$u")
"
  if [ "$have_prior" = 1 ]; then
    if is_num "$n" && is_num "$prev_findings" && [ "$n" -lt "$prev_findings" ]; then
      : # an UNAUTHENTICATED decrease proves nothing — it must never RESET the streak
    else
      nondrop_streak=$((nondrop_streak + 1))
    fi
  fi
  have_prior=1; prev_findings="$n"; last_verdict="$v"
done <<EOF
$(scan_all_verdicts "$SNAP")
EOF
if [ "$rounds_done" -gt 0 ]; then
  note "resume: $rounds_done prior review round(s) on the thread — counted toward the budget, never trusted for approval or phase"
  [ "$last_verdict" != "approved" ] \
    || note "resume: the thread ends in 'approved', but a historical verdict cannot terminate a NEW session — re-reviewing the live head fail-closed"
  [ "$rounds_done" -lt "$MAX_ROUNDS" ] \
    || halt "round cap: the thread already carries $MAX_ROUNDS review round(s) — a restart cannot mint a fresh budget" \
            "read the digest and the thread, then continue by hand; a new window requires deliberately raising MAX_ROUNDS in config" 0
  [ "$nondrop_streak" -lt 2 ] \
    || halt "no convergence on the resumed thread: no proven decrease in findings for 2 consecutive reviews" \
            "read the last two reviews; decide the direction yourself" 0
fi
round=$((rounds_done + 1))

# ---- the loop ------------------------------------------------------------------------
while : ; do
  SNAP=$(pr_snap)
  [ -n "$SNAP" ] || halt "gh stopped answering at round $round start" "check connectivity, re-run" 1
  assert_open "$SNAP"
  [ "$(snap_field "$SNAP" mergeable)" != "CONFLICTING" ] \
    || halt "PR conflicts with $BASE_REF — rebasing is a human decision" "resolve/rebase by hand, re-run" 0
  head=$(snap_field "$SNAP" headRefOid)
  base_oid=$(snap_field "$SNAP" baseRefOid)   # the verdict binds THIS merge-base
  base_idx=$(comment_count "$SNAP")

  # --- review phase: ALWAYS runs — approval and phase are never taken from history ----
  # Role separation inside one account: each dispatch carries a fresh nonce, typed
  # ONLY into that role's terminal; the protocol comment must echo it. The fixer
  # never sees the review nonce, so it cannot forge a verdict — and vice versa.
  RNONCE=$(nonce)
  [ -n "$RNONCE" ] || halt "cannot generate a review dispatch nonce (od / /dev/urandom)" "fix the environment, re-run" 2
  note ""
  note ">>> round $round/$MAX_ROUNDS: review dispatch (head=$(printf '%s' "$head" | cut -c1-7)) ..."
  send_to "$REVIEWER" "$REVIEW_SLASH_CMD Review PR $PR_URL at head $head in meta-PR mode (CONTRACT.md §Self-improvement: semantic review only — real improvement, no weakening, every hard rule and frozen invariant preserved). Read the full diff and every earlier round's comments via gh, verify the claims hold, then post EXACTLY ONE PR comment (gh pr comment) whose first five lines are: 'verdict: approved' or 'verdict: changes-requested', then 'reviewed-head: $head' (that FULL 40-char sha), then 'reviewed-base: $base_oid' (the base branch tip you reviewed against, FULL 40-char), then 'findings: <count>', then 'review-nonce: $RNONCE' — followed by each finding with file:line and a concrete failure scenario. Never merge, never close the PR, never push, never use GitHub review approvals: the comment IS the verdict." \
    || halt "cannot dispatch to the reviewer terminal $REVIEWER" "inspect it in Orca, re-run" 1

  # --- wait for the verdict (PR facts only; TUI text is never a signal) --------------
  verdict="" rhead="" findings="" curl_=""
  start=$SECONDS
  while : ; do
    sleep "$POLL_SECS"
    SNAP=$(pr_snap)
    if [ -n "$SNAP" ]; then
      assert_open "$SNAP"
      if [ "$(snap_field "$SNAP" headRefOid)" != "$head" ]; then
        halt "head moved during review round $round — someone else is pushing to this PR" \
             "find out who/what pushed; re-run when the PR is quiet" 1
      fi
      if [ "$(snap_field "$SNAP" baseRefOid)" != "$base_oid" ]; then
        halt "base $BASE_REF moved during review round $round — the verdict would bind a stale merge-base" \
             "re-run when the repo is quiet; the next round reviews against the new base" 1
      fi
      row=$(scan_verdict "$SNAP" "$base_idx" "$RNONCE")
      if [ -n "$row" ]; then
        IFS=$(printf '\t') read -r verdict rhead rbase findings curl_ <<EOF
$row
EOF
        break
      fi
    fi
    if [ $((SECONDS - start)) -ge "$REVIEW_TIMEOUT" ]; then
      note "reviewer terminal tail:"; tail_of "$REVIEWER"
      halt "no verdict comment within ${REVIEW_TIMEOUT}s (round $round)" \
           "inspect the reviewer TUI; the PR is untouched by this round" 1
    fi
  done

  # Exact binding: the echoes must BE the round head AND base, full 40 chars each —
  # no prefixes; a verdict that cannot name its exact merge-base does not count.
  [ "$rhead" = "$head" ] \
    || halt "reviewer echoed reviewed-head '$rhead' but round $round head is $head — stale or misdirected review" \
            "read $curl_; re-run when review targets the live head" 1
  [ "$rbase" = "$base_oid" ] \
    || halt "reviewer echoed reviewed-base '$rbase' but round $round base is $base_oid — the verdict binds a stale merge-base" \
            "read $curl_; re-run when the repo is quiet" 1
  DIGEST="$DIGEST$(printf '%-6s %-18s %-9s %-14s %s' "$round" "$verdict" "$findings" "$(printf '%s' "$head" | cut -c1-7)" "$curl_")
"
  note "<<< round $round verdict: $verdict (findings: $findings) — $curl_"

  # --- verdict routing ----------------------------------------------------------------
  if [ "$verdict" = "approved" ]; then
    halt "verdict: approved at round $round — meta-PR merge gate ahead (CONTRACT.md §Self-improvement: human-confirm + reviewer-only squash-merge; this loop merges nothing and the proposer never merges)" \
         "read the PR, then confirm the merge through the review lane; optionally run pipeline-update after" 0
  fi

  # No-progress detector, fail-closed: a decrease is PROVEN only between two LIVE,
  # nonce-bound verdicts — a missing/unparseable count, or a comparison against an
  # unauthenticated historical value, can never smuggle progress or reset the streak.
  if [ "$have_prior" = 1 ]; then
    if [ "$prev_auth" = 1 ] && is_num "$findings" && is_num "$prev_findings" && [ "$findings" -lt "$prev_findings" ]; then
      nondrop_streak=0
    else
      nondrop_streak=$((nondrop_streak + 1))
    fi
    [ "$nondrop_streak" -lt 2 ] \
      || halt "no convergence: no PROVEN decrease in findings for 2 consecutive reviews ($prev_findings -> $findings)" \
              "read the last two reviews — ping-pong, scope growth, or protocol drift; decide the direction yourself" 0
  fi
  have_prior=1
  prev_auth=1
  prev_findings="$findings"

  [ "$round" -lt "$MAX_ROUNDS" ] \
    || halt "round cap: review $MAX_ROUNDS still requests changes" \
            "read the digest and the thread, then continue by hand — a re-run halts here again (the budget is thread-bound); a new window requires deliberately raising MAX_ROUNDS in config" 0

  base_idx=$(comment_count "$SNAP")

  # --- dispatch the fixer --------------------------------------------------------------
  # A pinned handle is not an identity: before WRITE instructions go anywhere, prove
  # the fixer terminal's worktree IS this PR's repo, on the PR branch, CLEAN, and
  # synced to exactly this round's live head.
  verify_fixer_worktree 1 "$head" \
    || halt "cannot prove the fixer terminal's worktree is $REPO_SLUG on branch '$HEAD_REF', clean, at the live head $(printf '%s' "$head" | cut -c1-7) — refusing to dispatch write instructions" \
            "sync the fixer TUI's checkout (git checkout $HEAD_REF && git pull, stash/clean local noise), re-pin FIX_TERMINAL_HANDLE, re-run" 2
  FNONCE=$(nonce)
  [ -n "$FNONCE" ] || halt "cannot generate a fix dispatch nonce (od / /dev/urandom)" "fix the environment, re-run" 2
  hunt=""
  [ "$round" -lt "$HUNT_AFTER" ] \
    || hunt="This is fix round $round and earlier rounds did not converge — switch to root-cause mode: for EACH finding, reproduce it and confirm the root cause BEFORE changing code, and state in your evidence comment the invariant your fix restores; no symptom patches. "
  note ">>> round $round: fix dispatch ..."
  send_to "$FIXER" "${hunt}PR $PR_URL at head $head got 'verdict: changes-requested' — read the review comment $curl_ and the full thread via gh. Fix EVERY finding on the PR branch '$HEAD_REF' ONLY: no merge, no rebase, no force-push, never touch '$BASE_REF'. Push your commits, then post EXACTLY ONE PR comment (gh pr comment) whose first two lines are: 'fixed: <the new FULL 40-char head sha>', then 'fix-nonce: $FNONCE' — followed by per-finding evidence (what changed, how you verified)." \
    || halt "cannot dispatch to the fixer terminal $FIXER" "inspect it in Orca, re-run" 1

  # --- wait for the pushed fix + evidence ------------------------------------------------
  start=$SECONDS
  while : ; do
    sleep "$POLL_SECS"
    SNAP=$(pr_snap)
    if [ -n "$SNAP" ]; then
      assert_open "$SNAP"
      new_head=$(snap_field "$SNAP" headRefOid)
      row=$(scan_fixed "$SNAP" "$base_idx" "$FNONCE")
      if [ "$new_head" != "$head" ] && [ -n "$row" ]; then
        fsha=$(printf '%s' "$row" | cut -f1)
        # Exact binding, same family as the reviewed-head echo: the evidence must
        # BE the live head — an unrelated push cannot ride a stale comment.
        if [ "$fsha" = "$new_head" ]; then
          # "ahead" is the only clean continuation; a transient compare failure
          # ("unknown"/empty) keeps polling — only PROVEN divergence halts.
          case "$(compare_status "$head" "$new_head")" in
            ahead) note "<<< round $round fixed: head -> $(printf '%s' "$new_head" | cut -c1-7)"; break ;;
            diverged|behind)
              halt "PR head history was rewritten during fix round $round ($(printf '%s' "$head" | cut -c1-7) -> $(printf '%s' "$new_head" | cut -c1-7) is not fast-forward)" \
                   "a force-push/rebase needs a fresh human read; restart the loop after reading the branch" 1 ;;
            *) : ;;
          esac
        else
          [ "${fix_echo_seen:-}" = "$fsha" ] || {
            note "fix round $round: 'fixed: $fsha' does not echo the live head $(printf '%s' "$new_head" | cut -c1-7) — waiting for a matching evidence comment"
            fix_echo_seen="$fsha"
          }
        fi
      fi
    fi
    if [ $((SECONDS - start)) -ge "$FIX_TIMEOUT" ]; then
      note "fixer terminal tail:"; tail_of "$FIXER"
      halt "no pushed fix + 'fixed:' evidence comment within ${FIX_TIMEOUT}s (round $round)" \
           "inspect the fixer TUI; the last verdict still stands" 1
    fi
  done

  round=$((round + 1))
done
