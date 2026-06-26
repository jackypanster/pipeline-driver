#!/usr/bin/env bash
# Unit tests for parse-tail.awk against a format-faithful sample journal (the exact
# header / handoff shapes of a real pipeline run) plus synthetic tails for cases a
# straight-line run never produces. Sample cases are derived by truncating the sample
# just BEFORE a given seq, so the tail under test is the prior block — exercising
# "pick the last of N".
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/../parse-tail.awk"
REAL="$HERE/fixtures/sample-journal.md"
pass=0 fail=0

parse() { awk -f "$AWK" "$1" 2>/dev/null; }

# assert_tail <name> <file> <SEQ> <STATUS> <FROM> <NEXT>
assert_tail() {
  local name=$1 file=$2 wseq=$3 wstat=$4 wfrom=$5 wnext=$6
  local SEQ STATUS FROM NEXT; eval "$(parse "$file")"
  if [ "${SEQ:-}" = "$wseq" ] && [ "${STATUS:-}" = "$wstat" ] && [ "${FROM:-}" = "$wfrom" ] && [ "${NEXT:-}" = "$wnext" ]; then
    pass=$((pass+1)); printf 'ok   %-22s SEQ=%s STATUS=%s FROM=%s NEXT=%s\n' "$name" "$SEQ" "$STATUS" "$FROM" "${NEXT:-<empty>}"
  else
    fail=$((fail+1)); printf 'FAIL %-22s got SEQ=%s STATUS=%s FROM=%s NEXT=%s | want %s %s %s %s\n' \
      "$name" "${SEQ:-}" "${STATUS:-}" "${FROM:-}" "${NEXT:-<empty>}" "$wseq" "$wstat" "$wfrom" "${wnext:-<empty>}"
  fi
}

through() { awk -v n="$1" '$0 ~ ("^## seq=" n " ") {exit} {print}' "$REAL"; }

# --- real-journal cases (the driver's actual decision points) ---
through 6  > "$HERE/.t" ; assert_tail "start: arch->task"   "$HERE/.t" 5  completed arch   impl
through 8  > "$HERE/.t" ; assert_tail "loop: impl->impl"     "$HERE/.t" 7  completed impl   impl
through 12 > "$HERE/.t" ; assert_tail "halt: impl->review"   "$HERE/.t" 11 completed impl   review
through 13 > "$HERE/.t" ; assert_tail "halt: review await"   "$HERE/.t" 12 completed review ""
cp "$REAL" "$HERE/.t"   ; assert_tail "halt: review->done"   "$HERE/.t" 13 completed review ""

# --- synthetic cases ---
assert_tail "continue: failed retry" "$HERE/fixtures/synthetic-failed.md"  8  failed  impl   impl
assert_tail "halt: blocked->hunt"    "$HERE/fixtures/synthetic-blocked.md" 9  blocked impl   hunt
assert_tail "C1: body >>>NEXT decoy" "$HERE/fixtures/c1-body-decoy.md"     20 completed impl  review
assert_tail "C4: status vs by= tag"  "$HERE/fixtures/c4-status-tag.md"     30 failed  impl   impl
assert_tail "C7: review->impl bounce" "$HERE/fixtures/c7-review-reject.md" 40 failed  review impl

# --- degenerate: empty journal ---
printf '' > "$HERE/.t"
if parse "$HERE/.t" | grep -q no-entries; then pass=$((pass+1)); echo "ok   empty journal         -> no-entries"
else fail=$((fail+1)); echo "FAIL empty journal        -> expected no-entries"; fi

rm -f "$HERE/.t"
echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
