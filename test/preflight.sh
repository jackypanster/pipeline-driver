#!/usr/bin/env bash
# Regression tests for clobber-guard.sh — the trunk-clobber preflight check used by
# drive.sh. Feeds canned `rules/branches/<branch>` JSON (both rules / only one / empty)
# and asserts protected vs unprotected. This locks the prior HIGH fix: a trunk with
# only one of {non_fast_forward, deletion} must NOT pass as protected.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../clobber-guard.sh"
pass=0 fail=0

# check <expect protected|unprotected> <label> <rules-json>
check() {
  local want=$1 label=$2 json=$3 got
  if printf '%s' "$json" | bash "$GUARD"; then got=protected; else got=unprotected; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %-22s -> %s\n' "$label" "$got"
  else fail=$((fail+1)); printf 'FAIL %-22s -> got %s want %s\n' "$label" "$got" "$want"; fi
}

# Real GitHub response shape (compact, verified against the live API).
REAL_BOTH='[{"type":"deletion","ruleset_source_type":"Repository","ruleset_id":1},{"type":"non_fast_forward","ruleset_source_type":"Repository","ruleset_id":1}]'

check protected   "both (real shape)"      "$REAL_BOTH"
check protected   "both (reordered)"       '[{"type":"non_fast_forward"},{"type":"deletion"}]'
check unprotected "only non_fast_forward"  '[{"type":"non_fast_forward"}]'
check unprotected "only deletion"          '[{"type":"deletion"}]'
check unprotected "unrelated rule only"    '[{"type":"required_linear_history"}]'
check unprotected "empty array"            '[]'
check unprotected "empty (403/404)"        ''

echo "----"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
