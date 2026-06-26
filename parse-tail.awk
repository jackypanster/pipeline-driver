# parse-tail.awk — extract the live position from a pipeline journal.md tail.
#
# Emits four shell-evalable assignments for the LAST entry of an append-only
# journal: SEQ, STATUS, FROM, NEXT.  Usage:
#     eval "$(awk -f parse-tail.awk path/to/journal.md)"
#     # -> SEQ=10; STATUS=completed; FROM=impl; NEXT=impl
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
# Robustness decisions:
#   (validated against a real pipeline journal — see test/fixtures/sample-journal.md
#    for a format-faithful synthetic copy.)
#   - Anchor ONLY on ASCII: "## seq=", ">>> NEXT", "--- handoff ---", "Run pipeline-".
#     We never parse the Unicode field separator " · " (U+00B7), the arrow "→"
#     (U+2192), or the genesis "∅" (U+2205) — except a single byte-literal index()
#     for FROM, which is non-load-bearing (see below).
#   - The next-command is read from the FIRST non-empty line after ">>> NEXT", and
#     ">>> NEXT" is only armed AFTER the entry's "--- handoff ---" delimiter — so a
#     stray ">>> NEXT" inside the free-form done:/output: prose cannot hijack it,
#     and the lowercase "run pipeline-<after>" decoy body lines are never read.
#   - STATUS is matched as the keyword immediately preceding " · by=" so a status
#     word that also appears inside the free-form by=<tag> cannot shadow it.
#   - FROM is best-effort (used only to halt on a review->impl rejection); if it
#     mis-parses, the worst case is the driver auto-advances a review bounce, which
#     is still bounded by attempts->blocked and the no-progress guard.

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

    # from-stage: the lowercase token immediately before the "→" byte sequence.
    from = ""
    ap = index($0, "\342\206\222")            # U+2192 RIGHTWARDS ARROW
    if (ap > 0) {
        pre = substr($0, 1, ap - 1)
        sub(/[^a-z]*$/, "", pre)              # drop trailing non-lowercase
        sub(/.*[^a-z]/, "", pre)              # keep the trailing lowercase run
        from = pre
    }

    in_handoff = 0; capturing = 0; next_done = 0; nextcmd = ""
    next
}

/^--- handoff ---[ \t]*$/ { in_handoff = 1; next }

# Arm the next-command capture only inside the handoff, on the first >>> NEXT.
in_handoff == 1 && next_done == 0 && /^>>> NEXT[ \t]*$/ { capturing = 1; next }

capturing == 1 {
    if ($0 ~ /[^ \t]/) {                       # first NON-EMPTY line after >>> NEXT
        if ($0 ~ /^Run[ \t]+pipeline-[a-z]+/) {
            c = $0; sub(/^Run[ \t]+pipeline-/, "", c); sub(/[^a-z].*$/, "", c)
            nextcmd = c
        } else {
            nextcmd = ""                        # terminal / awaiting-human / no command
        }
        capturing = 0; next_done = 1
    }
    next
}

END {
    if (hcount == 0) { print "SEQ=; STATUS=; FROM=; NEXT=; PARSE_ERR=no-entries"; exit }
    if (seq == "" || status == "")
        print "# parse-tail.awk WARN: incomplete header parse (seq/status)" > "/dev/stderr"
    printf "SEQ=%s; STATUS=%s; FROM=%s; NEXT=%s\n", seq, status, from, nextcmd
}
