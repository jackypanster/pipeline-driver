## seq=7x · 2026-06-24T08:00:00Z · impl→review · completed · by=coder/local
done:   The seq token is "7x" — a base-10 prefix followed by a NON-delimiter
        character. This MUST parse-fail (PARSE_ERR=malformed-header →
        JOURNAL_SEQ_INVALID / JOURNAL_MALFORMED), never truncate to SEQ=7.
output: src/hello.sh
--- handoff ---
>>> NEXT
Run pipeline-review on the Hermes coder profile, FRESH session.
<<< END
