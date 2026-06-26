#!/usr/bin/env bash
# Tests for deny-merge.sh — the best-effort merge speed-bump. Includes the bypass
# cases from code review (wrapped merge via python -c; trunk delete by full refspec).
# NOTE: this hook is NOT a security boundary (see its header + README); these tests
# cover the DIRECT and common WRAPPED forms it is meant to catch, not every possible
# obfuscation. The durable gate is branch protection + the driver halting before review.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../deny-merge.sh"
pass=0 fail=0

# check <deny|allow> <command> [DRIVER_TRUNK]
check() {
  local want=$1 cmd=$2 trunk=${3:-master} out got
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" \
        | DRIVER_TRUNK="$trunk" bash "$HOOK")
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %-6s %s\n' "$got" "$cmd"
  else fail=$((fail+1)); printf 'FAIL want=%s got=%s  %s\n' "$want" "$got" "$cmd"; fi
}

echo "-- review bypasses: must DENY --"
check deny 'python3 -c '\''import subprocess; subprocess.run(["gh","pr","merge","23","--squash"])'\'''
check deny 'bash -c "gh pr merge 23 --squash"'
check deny 'git push origin :refs/heads/main'
check deny 'git push origin +refs/heads/main'
check deny 'git push origin :refs/heads/develop' develop

echo "-- direct merge routes: must DENY --"
check deny 'gh pr merge --squash 9'
check deny 'git merge feat/x'
check deny 'gh api repos/o/r/pulls/9/merge -X PUT'
check deny 'curl -X PUT https://api.github.com/repos/o/r/pulls/9/merge'
check deny 'gh api graphql -f query="mutation{mergePullRequest(input:{})}"'
check deny 'gitee-cli pr merge 9'

echo "-- trunk force/delete: must DENY --"
check deny 'git push --force origin master'
check deny 'git push --force-with-lease origin master'
check deny 'git push origin --delete master'
check deny 'git push origin :master'
check deny 'git push -d origin main'
check deny 'git push --force-with-lease origin develop' develop

echo "-- legit impl ops: must ALLOW --"
check allow 'git push --force-with-lease origin feat/stats-report'
check allow 'git push --force-with-lease origin feat/main-refactor'
check allow 'git push origin feat/x'
check allow 'git push origin master'
check allow 'git push origin HEAD:master'
check allow 'gh pr create --fill --base master --head feat/x'
check allow 'gh pr view 9 --json mergeable'
check allow 'gh pr list | grep merge'
check allow 'git commit -m "fix the merge-conflict bug"'
check allow 'git merge-base --is-ancestor a b'
check allow 'git push origin merge-feature'
check allow 'bash tests/report_test.sh test_governance'

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
