#!/usr/bin/env bash
# PreToolUse hook — the merge gate for the autonomous driver.
#
# Wired into the driven `claude` run via settings.driver.json. On every Bash tool
# call it receives the PreToolUse JSON payload on stdin and DENIES the call when the
# command would merge a PR/branch or force-/delete-push a TRUNK ref. Everything else
# is allowed (the driver does NOT sandbox the coder — impl is trusted to write code
# and run tests, exactly as in the hand-relayed pipeline; this re-adds the one thing
# autonomy removes: a human at the merge gate). It blocks the standard forge merge
# routes (gh / gitee-cli / gh api / curl / graphql); it is a gate, not a sandbox.
#
# It parses the actual command string (not a glob on a settings `if` field), so it
# is robust regardless of permission-rule syntax. The settings.driver.json `deny`
# rules are a second, independent layer. The real trunk branch is passed in via
# DRIVER_TRUNK (exported by drive.sh) and added to the master|main|trunk safety net.
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
# a trunk name appearing as a complete ref token (preceded by start/space/:/+/=,
# followed by space/:/end) — NOT a path segment like feat/main-refactor.
TRUNK_REF="(^|[ :+=])(${TRUNKS})([ :]|\$)"

# 1) PR / branch merges — every common route.
printf '%s' "$c" | grep -Eq '(^|[;&|( ])gh +pr +merge( |$)'        && deny "gh pr merge"
printf '%s' "$c" | grep -Eq '(^|[;&|( ])git +merge( |$)'          && deny "git merge"
printf '%s' "$c" | grep -Eq 'gh +api[^|;&]*pulls/[0-9]+/merge'    && deny "gh api PR merge"
printf '%s' "$c" | grep -Eq '(curl|wget)[^|;&]*pulls/[0-9]+/merge' && deny "curl/wget PR merge"
printf '%s' "$c" | grep -Eq 'mergePullRequest'                    && deny "graphql mergePullRequest"
printf '%s' "$c" | grep -Eq 'gitee-cli[^|;&]+merge'               && deny "gitee-cli merge"

# 2) force / delete pushes touching a TRUNK ref. Plain pushes to trunk (impl's
#    metadata fast-forward) and feat/* --force-with-lease stay allowed.
if printf '%s' "$c" | grep -Eq '(^|[;&|( ])git +push'; then
  if printf '%s' "$c" | grep -Eq "$TRUNK_REF"; then
    printf '%s' "$c" | grep -Eq '(--force|--force-with-lease|--delete)( |=|$)|(^| )-[fd]( |$)' && deny "force/delete push touching trunk"
    printf '%s' "$c" | grep -Eq "[ =]\\+[^ ]*(${TRUNKS})([ :]|\$)"                              && deny "force refspec (+) to trunk"
    printf '%s' "$c" | grep -Eq "[ =]:(${TRUNKS})([ :]|\$)"                                      && deny "delete trunk ref (:refspec)"
  fi
  printf '%s' "$c" | grep -Eq '(--force( |$)|(^| )-f( |$))' && deny "raw --force push (use --force-with-lease on feat/*)"
fi

exit 0   # allow
