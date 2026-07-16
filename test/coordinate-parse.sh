#!/usr/bin/env bash
# Unit tests for the parse-tail.awk extension (TO + NEXT_KIND + malformed-header),
# over and above the backward-compat cases in test/run.sh. Each fixture asserts all
# six fields (SEQ/STATUS/FROM/TO/NEXT/NEXT_KIND); the malformed fixture additionally
# asserts PARSE_ERR=malformed-header. Run: bash test/coordinate-parse.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AWK="$HERE/../parse-tail.awk"
pass=0 fail=0

parse() { awk -f "$AWK" "$1" 2>/dev/null; }

# assert_tail6 <name> <file> <SEQ> <STATUS> <FROM> <TO> <NEXT> <NEXT_KIND>
assert_tail6() {
  local name=$1 file=$2 wseq=$3 wstat=$4 wfrom=$5 wto=$6 wnext=$7 wkind=$8
  local SEQ STATUS FROM TO NEXT NEXT_KIND
  eval "$(parse "$file")"
  if [ "${SEQ:-}" = "$wseq" ] && [ "${STATUS:-}" = "$wstat" ] && [ "${FROM:-}" = "$wfrom" ] \
     && [ "${TO:-}" = "$wto" ] && [ "${NEXT:-}" = "$wnext" ] && [ "${NEXT_KIND:-}" = "$wkind" ]; then
    pass=$((pass+1))
    printf 'ok   %-26s SEQ=%s STATUS=%s FROM=%s TO=%s NEXT=%s NEXT_KIND=%s\n' \
      "$name" "$SEQ" "$STATUS" "$FROM" "$TO" "${NEXT:-<empty>}" "${NEXT_KIND:-<empty>}"
  else
    fail=$((fail+1))
    printf 'FAIL %-26s got SEQ=%s STATUS=%s FROM=%s TO=%s NEXT=%s NEXT_KIND=%s\n' \
      "$name" "${SEQ:-}" "${STATUS:-}" "${FROM:-}" "${TO:-}" "${NEXT:-<empty>}" "${NEXT_KIND:-<empty>}"
    printf '                       want SEQ=%s STATUS=%s FROM=%s TO=%s NEXT=%s NEXT_KIND=%s\n' \
      "$wseq" "$wstat" "$wfrom" "$wto" "${wnext:-<empty>}" "${wkind:-<empty>}"
  fi
}

# --- the four new fixtures (coordinator-design §7 route-table shapes) ---
assert_tail6 "impl->impl continuation"  "$HERE/fixtures/coord-impl-impl.md"       7  completed impl   impl   impl run-impl
assert_tail6 "review merge-wait marker" "$HERE/fixtures/coord-review-merge-wait.md" 12 completed review review ""   merge-wait
assert_tail6 "review->done terminal"    "$HERE/fixtures/coord-review-done.md"      13 completed review done   ""   other

# --- re-verify the two existing synthetic tails now also carry TO + NEXT_KIND ---
assert_tail6 "failed retry (impl->impl)" "$HERE/fixtures/synthetic-failed.md"  8 failed  impl impl impl run-impl
assert_tail6 "blocked -> hunt"           "$HERE/fixtures/synthetic-blocked.md" 9 blocked impl hunt hunt run-hunt
assert_tail6 "review->impl bounce"       "$HERE/fixtures/c7-review-reject.md"  40 failed  review impl impl run-impl

# --- malformed header: the EXACT §7.1 merge-wait line must NOT be mis-read as a
#      command, and a missing arrow on the tail entry parse-fails (TO load-bearing).
m=$(parse "$HERE/fixtures/coord-malformed.md")
if printf '%s' "$m" | grep -q 'PARSE_ERR=malformed-header'; then
  pass=$((pass+1)); echo "ok   malformed header         -> PARSE_ERR=malformed-header"
else
  fail=$((fail+1)); echo "FAIL malformed header          -> expected PARSE_ERR=malformed-header, got: $m"
fi

# --- a near-miss merge-wait line (trailing word) MUST classify as 'other', not
#      merge-wait — the marker is matched EXACTLY (coordinator-design §7.1).
T=$(mktemp); trap 'rm -f "$T"' EXIT
cat > "$T" <<'EOF'
## seq=5 · 2026-06-24T10:00:00Z · review→review · completed · by=claude-code/opus
done:   approve.
--- handoff ---
>>> NEXT
Await human-direct merge confirmation in this reviewer session please.
<<< END
EOF
assert_tail6 "merge marker near-miss"   "$T" 5 completed review review "" other

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
