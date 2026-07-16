## seq=7 · 2026-06-24T08:00:00Z · impl→ · completed · by=coder/local
done:   This header has an EMPTY to-stage: the token immediately after the arrow is
        the field separator, not a lowercase run ("impl→ · completed"). TO is the
        token ADJACENT to the arrow grammar; it MUST NOT scan forward into the
        status token and accept "completed" as TO. Empty TO ⇒ PARSE_ERR=malformed-header.
output: src/hello.sh
--- handoff ---
>>> NEXT
Run pipeline-impl on the Hermes coder profile (goal-driven-implementation), FRESH session.
<<< END
