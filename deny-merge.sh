#!/usr/bin/env bash
# PreToolUse hook — a BEST-EFFORT merge speed-bump for the autonomous driver.
#
# IMPORTANT: this is NOT a security boundary. It regexes the Bash command string, so
# any indirection a determined child can reach — a wrapper that builds the command
# from base64, a variable, a file, or a not-yet-enumerated interpreter — can bypass
# it. It catches the DIRECT forms and common quoted/wrapped forms (so a confused or
# lightly-wrapped cheap model does not accidentally merge), nothing more.
#
# The REAL merge safety is elsewhere and does not depend on this hook:
#   1. control flow — the driver only ever runs `/pipeline-impl` and HALTS before the
#      review/merge stage, so in normal operation a merge is never even attempted; and
#   2. server-side — trunk BRANCH PROTECTION (require PR review / restrict who merges)
#      rejects a merge from the driven child regardless of any client-side check.
#      drive.sh pre-flights this and WARNS when it is absent.
#
# Deny ⇒ print the decision JSON to stdout, exit 0. Allow ⇒ no output, exit 0.

payload=$(cat)
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  cmd=$(printf '%s' "$payload" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null)
else
  cmd=$payload   # fail safe: match against the raw payload
fi

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"driver merge-gate: %s blocked — only pipeline-review merges, after explicit human confirm (CONTRACT.md)"}}\n' "$1"
  exit 0
}

# Flatten tabs / newlines / backslash line-continuations so split commands match.
c=$(printf '%s' "$cmd" | tr '\n\t\\' '   ')

# trunk ref names: the real configured trunk plus the common safety net.
TRUNKS="master|main|trunk"
[ -n "${DRIVER_TRUNK:-}" ] && TRUNKS="${DRIVER_TRUNK}|${TRUNKS}"
# a trunk name as a complete ref token (optionally refs/heads/-prefixed), bounded by
# start/space/:/+/= and space/:/end — NOT a path segment like feat/main-refactor.
TRUNK_REF="(^|[ :+=])(refs/heads/)?(${TRUNKS})([ :]|\$)"

# 1) PR / branch merges — direct AND quoted/comma/space-wrapped forms. We tolerate
#    non-lowercase separators between tokens (so gh","pr","merge from a python/bash -c
#    wrapper is caught), but keep precise tails (merge, not merge-base/mergetool).
printf '%s' "$c" | grep -Eq 'gh[^a-z]+pr[^a-z]+merge'   && deny "gh pr merge"
printf '%s' "$c" | grep -Eq 'git[^a-z]+merge([^a-z-]|$)' && deny "git merge"
printf '%s' "$c" | grep -Eq 'pulls/[0-9]+/merge'         && deny "PR merge REST endpoint (gh api/curl/wget)"
printf '%s' "$c" | grep -Eq 'mergePullRequest'           && deny "graphql mergePullRequest"
printf '%s' "$c" | grep -Eq 'gitee-cli[^|;&]+merge'      && deny "gitee-cli merge"

# 2) force / delete pushes touching a TRUNK ref. Plain pushes to trunk (impl's
#    metadata fast-forward) and feat/* --force-with-lease stay allowed.
if printf '%s' "$c" | grep -Eq '(^|[;&|( ])git[^a-z]+push'; then
  if printf '%s' "$c" | grep -Eq "$TRUNK_REF"; then
    printf '%s' "$c" | grep -Eq '(--force|--force-with-lease|--delete)( |=|$)|(^| )-[fd]( |$)' && deny "force/delete push touching trunk"
    printf '%s' "$c" | grep -Eq "[ =]\\+(refs/heads/)?[^ ]*(${TRUNKS})"        && deny "force refspec (+) to trunk"
    printf '%s' "$c" | grep -Eq "[ =]:(refs/heads/)?(${TRUNKS})([ :]|\$)"       && deny "delete trunk ref (:refspec)"
  fi
  printf '%s' "$c" | grep -Eq '(--force( |$)|(^| )-f( |$))' && deny "raw --force push (use --force-with-lease on feat/*)"
fi

exit 0   # allow
