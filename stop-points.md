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
  review *rejection* (a human semantic decision); the REJECTION GATE demands a typed
  read-ack (the rejection seq) before the fix loop resumes — EOF/mismatch HALTS.
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
| `FROM=review`, `NEXT=impl` | review **rejected** a card and bounced it back to impl (spec unchanged) | read `reviews/*`, then type the rejection seq at the **REJECTION GATE** (per-invocation, GATE-1-style; EOF/mismatch keeps the halt — the tail cannot advance until impl runs, so "re-run to resume" alone would re-halt forever) |
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
| `verdict: approved` (echoing the live head, the live base tip AND this dispatch's nonce) | the meta-PR review signed off | read the PR, then the meta-PR merge gate: **human-confirm + reviewer-only squash-merge** (the loop merges nothing, the proposer never merges); then `pipeline-update` |
| round cap (`MAX_ROUNDS`, default 5) — live or already consumed by the resumed thread | review N still requests changes; the budget is thread-bound, so a re-run halts here again | read the digest + thread; continue by hand, or deliberately raise `MAX_ROUNDS` in config for a new window |
| no progress: `findings:` did not **provably** decrease for 2 consecutive reviews (a decrease is proven only between two LIVE nonce-bound verdicts; missing/unparseable counts and comparisons against unauthenticated history count as no progress) | ping-pong, scope growth, protocol drift, or forged history | read the last two reviews, decide the direction |
| no verdict comment within `REVIEW_TIMEOUT` | reviewer TUI stalled or stopped posting to the PR (the loop is blind to TUI text by design; unauthenticated or nonce-less comments are inert) | inspect the reviewer terminal (tail printed) |
| no pushed fix + `fixed:` comment within `FIX_TIMEOUT` | fixer TUI stalled, pushed without evidence, or its `fixed:`/`fix-nonce:` echo never matched | inspect the fixer terminal (tail printed) |
| `reviewed-head` echo ≠ the round's head, or `reviewed-base` echo ≠ the round's base tip (full-40 string equality; a prefix never parses) | stale or misdirected review | read the mismatched comment first |
| head moved during a review round | someone else is pushing to the PR | find out who; re-run when quiet |
| base moved during a review round | the verdict would bind a stale merge-base | re-run when the repo is quiet; the next round reviews against the new base |
| head history rewritten during a fix (compare ≠ fast-forward) | force-push/rebase | fresh human read of the branch, then restart |
| PR merged / closed / conflicts with base mid-loop | a human-level event outside the loop | act on the PR itself |
| PR's repo outside `REVIEW_REPO_RE`, or a fork (cross-repository) PR | outside the sanctioned toolchain scope — refused at preflight, nothing dispatched | feature work goes through the 5-stage pipeline; fork PRs are reviewed by hand |
| fixer worktree unprovable — pinned handle not live, `worktreePath` missing, `origin` ≠ the PR's repo (preflight), or — re-proven before EVERY fix dispatch — not on the PR branch, not CLEAN, or `HEAD` ≠ the round's live PR head | write instructions must never reach an unrelated, dirty, or unsynced checkout | sync the fixer checkout (`git checkout <branch> && git pull`, stash/clean local noise); re-pin the handle from the live listing |
| shared/unresolvable terminals, non-numeric loop config, or empty `REVIEW_SLASH_CMD` | config error, refused at preflight (the relayed review must invoke `pipeline-review`, never generic prose) | pin two distinct live handles / fix the named value |

Resume never trusts history: prior same-author verdicts are folded FAIL-CLOSED into
the round budget, the no-progress streak and the digest — quantities a forged or
nonce-less comment can only tighten — and never into approval or phase (a prior
session's nonces are unknowable). A restart always re-reviews the live head/base
with a fresh nonce: a historical `approved` (any head) cannot terminate the new
session, and an unfixed rejection is superseded by the fresh review.

Protocol lines (why comments, not GitHub reviews: one account cannot
approve/request-changes on its own PR): reviewer comments carry `verdict:` +
`reviewed-head:` + `reviewed-base:` + `findings:` + `review-nonce:`; fixer comments
carry `fixed:` + `fix-nonce:`. Authentication is two-layer: only the
gh-authenticated login's comments (override: `PROTOCOL_AUTHOR`) parse at all, and
each dispatch's nonce — typed only into that role's terminal — must be echoed back,
so the roles cannot forge each other and nothing stale steers the live loop; anyone
else's comment is inert text, silently ignored rather than a halt. SHA echoes bind
by full-40 string equality. All parsing is grep/jq-deterministic — no LLM in the
scheduler.
