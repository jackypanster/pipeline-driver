# Stop points — exactly where the drivers yield to a human

`drive.sh` auto-advances **one** thing: the `pipeline-impl` multi-card loop. Every
other position is a HALT. These stops are **enumerable from the contract's state
machine**, not a vibes-based "am I confused?" judgment. This file is both the
driver's halt specification and a checklist for a human relaying by hand.
(`review-drive.sh`, the meta-PR loop, has its own halt table at the end.)

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
| impl child exits non-zero (claude transport) | a denied tool (e.g. attempted merge), a wall, or a crash | inspect output; manual `pipeline-impl` or `pipeline-hunt` |
| no journal progress within `CARD_TIMEOUT` (orca transport) | the TUI stalled — permission prompt, crash, wedged run (the driver prints the terminal tail) | inspect the impl terminal in Orca; manual `pipeline-impl` or `pipeline-hunt` |
| remote `seq` did not advance after a run | impl committed nothing, or did not push | inspect; the run made no pushed progress |

## The two gates the driver never crosses

1. **GATE 1 — before the loop.** The frozen red test is read and its `spec-rev` echoed;
   the driver cannot start without it, and re-fires it on any re-freeze. Who performs
   the read is the operator's risk-tier policy (README §For agents): default a human,
   delegable to the coordinating agent only for explicitly low-risk drive-mode features.
2. **GATE 2 — after the loop.** Only `pipeline-review` merges, and only after an
   explicit human confirm. The durable merge gate is the driver HALTING before review
   plus you performing the merge; everything else (trunk rulesets, the `permissions.deny`
   rules, the `deny-merge.sh` hook) is hardening, not a boundary. Normative merge-safety
   model: README §Merge safety.

## review-drive.sh — the meta-PR loop's halt table

`review-drive.sh` auto-advances **one** other thing: the review↔fix rounds of a single
TOOLCHAIN-repo PR (README §review-drive). It starts behind its own gate (type the PR
number after reading the banner) and every exit is one of these:

| event | meaning | run next (human) |
|-------|---------|------------------|
| `verdict: approved` | the reviewer signed off | read the PR, **merge it yourself** (the loop never merges); then `pipeline-update` |
| round cap (`MAX_ROUNDS`, default 5) | review N still requests changes | read the digest + thread; continue by hand or re-run for another window |
| no progress: `findings:` did not decrease for 2 consecutive reviews | ping-pong or scope growth | read the last two reviews, decide the direction |
| no verdict comment within `REVIEW_TIMEOUT` | reviewer TUI stalled or stopped posting to the PR (the loop is blind to TUI text by design) | inspect the reviewer terminal (tail printed) |
| no pushed fix + `fixed:` comment within `FIX_TIMEOUT` | fixer TUI stalled, or pushed without evidence | inspect the fixer terminal (tail printed) |
| `reviewed-head` echo ≠ the round's head | stale or misdirected review | read the mismatched comment first |
| head moved during a review round | someone else is pushing to the PR | find out who; re-run when quiet |
| head history rewritten during a fix (compare ≠ fast-forward) | force-push/rebase | fresh human read of the branch, then restart |
| PR merged / closed / conflicts with base mid-loop | a human-level event outside the loop | act on the PR itself |
| reviewer and fixer resolve to the same terminal / unresolvable terminal | config error | pin two distinct live handles |

Protocol lines (why comments, not GitHub reviews: one account cannot
approve/request-changes on its own PR): reviewer comments carry `verdict:` +
`reviewed-head:` + `findings:`; fixer comments carry `fixed: <sha>`. All parsing is
grep/jq-deterministic — no LLM in the scheduler.
