## seq=7 · 2026-06-24T08:00:00Z · impl→impl · completed · by=coder/local
done:   Implemented card 04. Card gate green; a normal completed continuation.
output: src/hello.sh, tasks/04.md
--- handoff ---
>>> NEXT
Run pipeline-impl on the Hermes coder profile (goal-driven-implementation), FRESH session.
<<< END

## seq=x · 2026-06-24T08:30:00Z · impl→impl · completed · by=coder/local
done:   This trailing PHYSICAL-TAIL header has a NON-NUMERIC seq ("seq=x"). It MUST
        be recognized as a new (malformed) entry boundary so the tail routes FAIL
        (PARSE_ERR=malformed-header → JOURNAL_SEQ_INVALID / JOURNAL_MALFORMED),
        never silently fall through to the prior valid seq=7 entry.
output: (none)
--- handoff ---
>>> NEXT
Run pipeline-impl on the Hermes coder profile (goal-driven-implementation), FRESH session.
<<< END
