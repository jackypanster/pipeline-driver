# Stop points — exactly where the driver yields to a human

The driver auto-advances **one** thing: the `pipeline-impl` multi-card loop. Every
other position is a HALT. These stops are **enumerable from the contract's state
machine**, not a vibes-based "am I confused?" judgment. This file is both the
driver's halt specification and a checklist for a human relaying by hand.

## The halt predicate (the whole brain)

```
CONTINUE  ⟺  NEXT == impl  AND  STATUS != blocked  AND  FROM != review  AND  LIVE_SPEC_REV == CONFIRMED_SPEC_REV
```

- `NEXT` — the stage named on the first non-empty line after the last `>>> NEXT`
  in the journal tail (`Run pipeline-<NEXT> ...`). Parsed by `parse-tail.awk`.
- `STATUS` — the journal entry header's run status (`completed|failed|blocked`).
- `FROM` — the journal entry header's from-stage. `FROM=review` with `NEXT=impl` is a
  review *rejection* (a human semantic decision); the driver HALTS so you see it first.
- `LIVE_SPEC_REV` — the shared `spec-rev` read from a task card on `origin/<BRANCH>`.
- `CONFIRMED_SPEC_REV` — the spec-rev the human echoed at GATE 1.

## Continue (the only auto-advanced case)

| tail | why it is safe to auto-advance |
|------|--------------------------------|
| `NEXT=impl`, `STATUS=completed` | a card went green; more `todo` cards remain → next card. No semantic artifact is produced-and-consumed without a human read: the spec was frozen and human-confirmed before the loop. |
| `NEXT=impl`, `STATUS=failed` | informed retry, attempts<3 (impl itself escalates to `hunt` at attempts≥3). Loud, deterministic failure — not a silent semantic error. Gated by `RETRY_ON_FAIL` + the consecutive-failure breaker. |

## Halt (everything else)

| tail | meaning | run next (human) |
|------|---------|------------------|
| `NEXT=review` | all cards in review — feature complete | `pipeline-review` (semantic review + **merge confirm**) |
| `NEXT=hunt` / `STATUS=blocked` | a card hit attempts≥3, or a cross-card integration incident | `pipeline-hunt` (root-cause) |
| `NEXT=` empty | terminal / "Awaiting the operator's go" / "feature complete" | read the journal tail — likely your merge confirm, or done |
| `NEXT=prd|arch|task` | a re-route to an interview/decomposition stage | that stage (frontier, human) |
| `FROM=review`, `NEXT=impl` | review **rejected** a card and bounced it back to impl (spec unchanged) | read `reviews/*`, then re-run the driver to resume the fix |
| `LIVE_SPEC_REV != CONFIRMED_SPEC_REV` | a re-freeze/append-card minted a **new** frozen spec | **GATE 1 again** — read the new test, re-confirm |
| card `status: in-progress` on remote | a prior impl run died mid-card | reset that card to `todo`, re-run the driver |
| impl child exits non-zero | a denied tool (e.g. attempted merge), a wall, or a crash | inspect output; manual `pipeline-impl` or `pipeline-hunt` |
| remote `seq` did not advance after a run | impl committed nothing, or did not push | inspect; the run made no pushed progress |

## The two human gates the driver never crosses

1. **GATE 1 — before the loop.** The human reads the frozen red test and echoes its
   `spec-rev`. The driver cannot start without it, and re-fires it on any re-freeze.
2. **GATE 2 — after the loop.** Only `pipeline-review` merges, and only after an
   explicit human confirm. The DURABLE merge gate is the driver HALTING before review
   plus you running the merge — the feature-PR merge has no clean server-side gate for a
   solo single-identity setup. Trunk **force-push/deletion** rules (drive.sh warns if
   absent) and the `permissions.deny` + `deny-merge.sh` hook are SEPARATE hardening that
   protect against trunk-clobber, not the merge; the hook is a best-effort client-side
   speed-bump (string matching is bypassable), not a security boundary.
