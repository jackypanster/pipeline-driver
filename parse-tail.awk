# parse-tail.awk — extract the live position from a pipeline journal.md tail.
#
# Emits six shell-evalable assignments for the LAST entry of an append-only
# journal: SEQ, STATUS, FROM, TO, NEXT, NEXT_KIND.  Usage:
#     eval "$(awk -f parse-tail.awk path/to/journal.md)"
#     # -> SEQ=10; STATUS=completed; FROM=impl; TO=impl; NEXT=impl; NEXT_KIND=run-impl
#
# On a malformed LAST entry it still emits whatever it parsed but appends
# `PARSE_ERR=malformed-header` (TO is load-bearing — see below); callers MUST
# check PARSE_ERR before trusting the fields. An empty journal emits
# `PARSE_ERR=no-entries` with blank fields.
#
# Entry shape (CONTRACT.md §Handoff block / §Run journal):
#   ## seq=N · <ISO8601> · <from>→<to> · <completed|failed|blocked> · by=<tag>
#   done:   ...free prose...
#   output: ...
#   --- handoff ---
#   >>> NEXT
#   Run pipeline-<next> ...            <- the authoritative next-command line
#   ...
#   <<< END
#
# NEXT_KIND classifies the first non-empty line after `>>> NEXT` (armed only
# AFTER `--- handoff ---`, same as NEXT):
#   run-<stage>   when it matches `Run pipeline-<stage>`
#                (stage ∈ prd|arch|task|impl|review|hunt); NEXT carries <stage>.
#   merge-wait    when the line is EXACTLY
#                `Await human-direct merge confirmation in this reviewer session.`
#                (NEXT stays empty — it is not a dispatch command.)
#   other        otherwise (terminal handoffs, prose, anything else); NEXT empty.
#
# Robustness decisions:
#   (validated against a real pipeline journal — see test/fixtures/sample-journal.md
#    for a format-faithful synthetic copy.)
#   - Anchor ONLY on ASCII: "## seq=", ">>> NEXT", "--- handoff ---", "Run pipeline-".
#     We never parse the Unicode field separator " · " (U+00B7) or the genesis "∅"
#     (U+2205). The ONE Unicode glyph we touch is the transition arrow "→" (U+2192,
#     bytes \xe2\x86\x92), and we touch it via byte-literal index() only.
#   - The arrow now carries TWO fields around it. FROM (the lowercase run BEFORE the
#     arrow) stays BEST-EFFORT and non-load-bearing: the genesis entry `∅→prd` leaves
#     FROM empty and that is fine. TO (the lowercase run AFTER the arrow) is
#     LOAD-BEARING — the coordinator route table (§7) keys off it, and a missing
#     arrow or a missing to-token on the tail entry is a hard parse error
#     (PARSE_ERR=malformed-header → JOURNAL_MALFORMED), never a silent guess. Both
#     are read by the SAME byte arithmetic (the arrow is exactly 3 bytes), so a
#     byte/locale mismatch would break FROM and TO together, not silently.
#   - STATUS is matched as the keyword immediately preceding " · by=" so a status
#     word that also appears inside the free-form by=<tag> cannot shadow it.
#   - The next-command is read from the FIRST non-empty line after ">>> NEXT", and
#     ">>> NEXT" is only armed AFTER the entry's "--- handoff ---" delimiter — so a
#     stray ">>> NEXT" inside the free-form done:/output: prose cannot hijack it,
#     and the lowercase "run pipeline-<after>" decoy body lines are never read.
#   - Malformed detection is scoped to the LAST entry (the tail the coordinator
#     routes off). A malformed middle entry is not flagged here; whole-journal
#     validation is a later coordinator concern, not this tail parser's job.

/^## seq=[0-9]+ / {
    hcount++
    # seq: ASCII prefix strip.
    s = $0; sub(/^## seq=/, "", s); sub(/[^0-9].*$/, "", s); seq = s

    # status: the keyword that sits right before " · by=" (anchored, so a status
    # word inside by=<tag> can't win). Fall back to a bare scan if the header lacks by=.
    if      ($0 ~ /completed[^a-z]+by=/) status = "completed"
    else if ($0 ~ /failed[^a-z]+by=/)    status = "failed"
    else if ($0 ~ /blocked[^a-z]+by=/)   status = "blocked"
    else if (index($0, "completed"))     status = "completed"
    else if (index($0, "blocked"))       status = "blocked"
    else if (index($0, "failed"))        status = "failed"
    else                                  status = ""

    # from / to around the U+2192 arrow (bytes \342\206\222). The arrow is exactly
    # 3 bytes; index() returns a byte position and substr() counts bytes (verified
    # on BSD awk 20200816 + gawk under UTF-8). FROM is the trailing lowercase run
    # BEFORE the arrow (empty for the genesis ∅ — best-effort); TO is the leading
    # lowercase run AFTER the arrow (load-bearing).
    from = ""; to = ""; arrow_at = index($0, "\342\206\222")
    if (arrow_at > 0) {
        pre = substr($0, 1, arrow_at - 1)
        sub(/[^a-z]*$/, "", pre)              # drop trailing non-lowercase
        sub(/.*[^a-z]/, "", pre)              # keep the trailing lowercase run
        from = pre

        post = substr($0, arrow_at + 3)       # skip the 3 arrow bytes
        sub(/^[^a-z]*/, "", post)             # drop leading non-lowercase (spaces, ·)
        sub(/[^a-z].*$/, "", post)            # keep the leading lowercase run
        to = post
    }

    # malformed-header detection on THIS (eventually last) entry: seq/status are
    # mandatory, and TO is load-bearing (arrow present AND yielded a to-token).
    hdr_bad = (seq == "" || status == "" || to == "") ? 1 : 0

    in_handoff = 0; capturing = 0; next_done = 0; nextcmd = ""; nextkind = ""
    next
}

/^--- handoff ---[ \t]*$/ { in_handoff = 1; next }

# Arm the next-command capture only inside the handoff, on the first >>> NEXT.
in_handoff == 1 && next_done == 0 && /^>>> NEXT[ \t]*$/ { capturing = 1; next }

capturing == 1 {
    if ($0 ~ /[^ \t]/) {                       # first NON-EMPTY line after >>> NEXT
        line = $0; sub(/\r$/, "", line)        # CRLF safety only; otherwise EXACT match
        if (line ~ /^Run[ \t]+pipeline-[a-z]+/) {
            c = line; sub(/^Run[ \t]+pipeline-/, "", c); sub(/[^a-z].*$/, "", c)
            nextcmd = c
            nextkind = "run-" c
        } else if (line == "Await human-direct merge confirmation in this reviewer session.") {
            nextcmd = ""                        # not a dispatch command
            nextkind = "merge-wait"
        } else {
            nextcmd = ""                        # terminal / awaiting-human / no command
            nextkind = "other"
        }
        capturing = 0; next_done = 1
    }
    next
}

END {
    if (hcount == 0) { print "SEQ=; STATUS=; FROM=; TO=; NEXT=; NEXT_KIND=; PARSE_ERR=no-entries"; exit }
    if (hdr_bad) {
        print "# parse-tail.awk WARN: malformed header on tail entry (seq/status/to incomplete)" > "/dev/stderr"
        printf "SEQ=%s; STATUS=%s; FROM=%s; TO=%s; NEXT=%s; NEXT_KIND=%s; PARSE_ERR=malformed-header\n", \
            seq, status, from, to, nextcmd, nextkind
    } else {
        printf "SEQ=%s; STATUS=%s; FROM=%s; TO=%s; NEXT=%s; NEXT_KIND=%s\n", \
            seq, status, from, to, nextcmd, nextkind
    }
}
