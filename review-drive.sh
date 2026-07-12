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
# comment replays across rounds or sessions. SHA echoes bind exactly (full 40
# chars, string equality — never a prefix). The scope is ENFORCED, not just
# documented: the PR's repo must match REVIEW_REPO_RE (default: the pipeline
# toolchain repos) and fork (cross-repository) PRs are refused at preflight.
#
# The TUIs never talk to each other and the driver never forwards review TEXT —
# each side reads the PR itself via gh; orca only types the dispatch line
# (medium is git, per the operator's SOP). Completion signals are PR facts:
# a new protocol comment (scanned by comment-INDEX baseline, immune to clock skew
# between this machine and GitHub), an advanced head SHA whose history still
# CONTAINS the reviewed head (a diverged compare = force-push/rebase = halt) and
# whose value the fixer's `fixed:` line must echo, and a base OID pinned per
# review round (a moved base = the verdict binds a stale merge-base = halt).
# Kill+restart RESUMES: prior rounds, the findings history, the digest AND the
# phase are rebuilt from the PR thread itself — a restart cannot mint a fresh
# round budget, a stale 'approved' (older head) never blesses later pushes, and
# an unfixed changes-requested resumes at its fix phase.
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
# Optional skill-invocation prefix for the review dispatch (e.g. codex '$pipeline-review'),
# shared with drive.sh's one-key relay — the relayed review IS pipeline-review, meta-PR mode.
REVIEW_SLASH_CMD="${REVIEW_SLASH_CMD:-}"

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
nonce() { od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }   # 16 hex chars, regex-safe
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
# "verdict:" line. TSV: verdict, reviewed-head (or "none"), findings (or "-"), url.
scan_verdict() {
  printf '%s' "$1" | jq -r --argjson idx "$2" --arg who "$WHO" --arg nonce "$3" '
    .comments[$idx:]
    | map(select((.author.login // "") == $who))
    | map(select(.body | test("(?:^|\\n)review-nonce: *" + $nonce)))
    | map(select(.body | test("(?:^|\\n)verdict: *(approved|changes-requested)")))
    | last // empty
    | [ (.body | capture("(?:^|\\n)verdict: *(?<v>approved|changes-requested)").v),
        ((.body | capture("(?:^|\\n)reviewed-head: *(?<h>[0-9a-fA-F]{40})").h) // "none"),
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

# ---- preflight ---------------------------------------------------------------------
for dep in gh jq orca; do
  command -v "$dep" >/dev/null 2>&1 || halt "$dep not on PATH" "install $dep, then re-run" 2
done
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

SNAP=$(pr_snap)
[ -n "$SNAP" ] || halt "cannot read PR #$PR on $REPO_SLUG via gh" "check gh auth / the PR number" 2
assert_open "$SNAP"
[ "$(snap_field "$SNAP" isCrossRepository)" != "true" ] \
  || halt "PR #$PR is a FORK (cross-repository) PR — foreign head, no fixer push path" \
          "review fork PRs by hand; this loop only drives same-repo toolchain branches" 2
HEAD_REF=$(snap_field "$SNAP" headRefName)
BASE_REF=$(snap_field "$SNAP" baseRefName)

# ---- start gate: bind the confirmation to the PR (wrong-PR accidents die here) ------
note "PR      : #$PR $PR_URL"
note "title   : $(snap_field "$SNAP" title)"
note "branch  : $HEAD_REF -> $BASE_REF   head=$(snap_field "$SNAP" headRefOid | cut -c1-7)"
note "loop    : MAX_ROUNDS=$MAX_ROUNDS  HUNT_AFTER=$HUNT_AFTER  reviewer=$REVIEWER  fixer=$FIXER"
note "gates   : the loop never merges; 'verdict: approved' halts for the meta-PR merge gate (human-confirm + reviewer-only squash-merge)"
printf 'GATE — type the PR number above to start the loop: ' >&2
read -r ACK || halt "the start gate needs an interactive terminal (stdin closed)" "run attached to a TTY" 2
[ "$ACK" = "$PR" ] || halt "PR number not confirmed (got '$ACK')" "re-run with the intended PR" 2

# ---- resume: rebuild loop state from the PR thread itself -----------------------------
# Kill+restart must not mint a fresh round budget, forget the findings history, or
# misread the PHASE: every prior AUTHENTICATED verdict comment counts as a consumed
# round; an 'approved' ends the run ONLY if it binds the LIVE head (a stale approval
# of an older head can never bless later pushes); and an unfixed changes-requested
# whose head is still live resumes at its FIX phase, not with a wasted re-review.
rounds_done=0
prev_findings=""      # findings value from the previous review ("-" = unparseable)
have_prior=0          # 1 once any verdict has been consumed (resumed or live)
nondrop_streak=0      # consecutive reviews without a PROVEN decrease in findings
last_verdict="" last_rhead="" last_url=""
while IFS=$(printf '\t') read -r v h n u; do
  [ -n "$v" ] || continue
  rounds_done=$((rounds_done + 1))
  DIGEST="$DIGEST$(printf '%-6s %-18s %-9s %-14s %s' "$rounds_done" "$v" "$n" "$(printf '%s' "$h" | cut -c1-7)" "$u")
"
  if [ "$have_prior" = 1 ]; then
    if is_num "$n" && is_num "$prev_findings" && [ "$n" -lt "$prev_findings" ]; then nondrop_streak=0
    else nondrop_streak=$((nondrop_streak + 1)); fi
  fi
  have_prior=1; prev_findings="$n"; last_verdict="$v"; last_rhead="$h"; last_url="$u"
done <<EOF
$(scan_all_verdicts "$SNAP")
EOF
pending_fix=0
cur_head=$(snap_field "$SNAP" headRefOid)
if [ "$rounds_done" -gt 0 ]; then
  note "resume: $rounds_done prior review round(s) found on the PR thread"
  if [ "$last_verdict" = "approved" ]; then
    if [ "$last_rhead" = "$cur_head" ]; then
      halt "the thread's last verdict is already 'approved' and binds the LIVE head — nothing to drive" \
           "confirm the merge through the review lane (meta-PR gate: human-confirm + reviewer-only squash-merge)" 0
    fi
    note "resume: the last 'approved' binds $(printf '%s' "$last_rhead" | cut -c1-7) but the live head is $(printf '%s' "$cur_head" | cut -c1-7) — STALE approval, a fresh review round is required"
  fi
  [ "$rounds_done" -lt "$MAX_ROUNDS" ] \
    || halt "round cap: the thread already carries $MAX_ROUNDS review round(s) — a restart cannot mint a fresh budget" \
            "read the digest above and the PR thread; continue by hand" 0
  [ "$nondrop_streak" -lt 2 ] \
    || halt "no convergence on the resumed thread: no proven decrease in findings for 2 consecutive reviews" \
            "read the last two reviews; decide the direction yourself" 0
  if [ "$last_verdict" = "changes-requested" ] && [ "$last_rhead" = "$cur_head" ]; then
    pending_fix=1
    note "resume: round $rounds_done's changes-requested still binds the live head — resuming at its FIX phase"
  fi
fi
if [ "$pending_fix" = 1 ]; then round=$rounds_done; else round=$((rounds_done + 1)); fi

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

  # --- review phase (skipped once when resuming into a pending fix) -------------------
  if [ "$pending_fix" = 1 ]; then
    pending_fix=0
    verdict="changes-requested"; curl_="$last_url"
    note ""
    note ">>> round $round/$MAX_ROUNDS: resuming at the FIX phase (verdict: $curl_)"
  else

  # Role separation inside one account: each dispatch carries a fresh nonce, typed
  # ONLY into that role's terminal; the protocol comment must echo it. The fixer
  # never sees the review nonce, so it cannot forge a verdict — and vice versa.
  RNONCE=$(nonce)
  [ -n "$RNONCE" ] || halt "cannot generate a review dispatch nonce (od / /dev/urandom)" "fix the environment, re-run" 2
  note ""
  note ">>> round $round/$MAX_ROUNDS: review dispatch (head=$(printf '%s' "$head" | cut -c1-7)) ..."
  send_to "$REVIEWER" "${REVIEW_SLASH_CMD:+$REVIEW_SLASH_CMD }Review PR $PR_URL at head $head in meta-PR mode (CONTRACT.md §Self-improvement: semantic review only — real improvement, no weakening, every hard rule and frozen invariant preserved). Read the full diff and every earlier round's comments via gh, verify the claims hold, then post EXACTLY ONE PR comment (gh pr comment) whose first four lines are: 'verdict: approved' or 'verdict: changes-requested', then 'reviewed-head: $head' (that FULL 40-char sha), then 'findings: <count>', then 'review-nonce: $RNONCE' — followed by each finding with file:line and a concrete failure scenario. Never merge, never close the PR, never push, never use GitHub review approvals: the comment IS the verdict." \
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
        IFS=$(printf '\t') read -r verdict rhead findings curl_ <<EOF
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

  # Exact binding: the echo must BE the round head, full 40 chars — no prefixes.
  [ "$rhead" = "$head" ] \
    || halt "reviewer echoed reviewed-head '$rhead' but round $round head is $head — stale or misdirected review" \
            "read $curl_; re-run when review targets the live head" 1
  DIGEST="$DIGEST$(printf '%-6s %-18s %-9s %-14s %s' "$round" "$verdict" "$findings" "$(printf '%s' "$head" | cut -c1-7)" "$curl_")
"
  note "<<< round $round verdict: $verdict (findings: $findings) — $curl_"

  # --- verdict routing ----------------------------------------------------------------
  if [ "$verdict" = "approved" ]; then
    halt "verdict: approved at round $round — meta-PR merge gate ahead (CONTRACT.md §Self-improvement: human-confirm + reviewer-only squash-merge; this loop merges nothing and the proposer never merges)" \
         "read the PR, then confirm the merge through the review lane; optionally run pipeline-update after" 0
  fi

  # No-progress detector, fail-closed: only a PROVEN numeric decrease resets the
  # streak — a missing/unparseable findings count can never smuggle progress.
  if [ "$have_prior" = 1 ]; then
    if is_num "$findings" && is_num "$prev_findings" && [ "$findings" -lt "$prev_findings" ]; then
      nondrop_streak=0
    else
      nondrop_streak=$((nondrop_streak + 1))
    fi
    [ "$nondrop_streak" -lt 2 ] \
      || halt "no convergence: no proven decrease in findings for 2 consecutive reviews ($prev_findings -> $findings)" \
              "read the last two reviews — ping-pong, scope growth, or protocol drift; decide the direction yourself" 0
  fi
  have_prior=1
  prev_findings="$findings"

  [ "$round" -lt "$MAX_ROUNDS" ] \
    || halt "round cap: review $MAX_ROUNDS still requests changes" \
            "read the digest above and the PR thread; continue by hand or re-run for another window" 0

  base_idx=$(comment_count "$SNAP")
  fi   # end review phase

  # --- dispatch the fixer --------------------------------------------------------------
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
