# pipeline-driver

An **optional, external** driver for the [`pipeline`](https://github.com/jackypanster/pipeline)
toolchain. It auto-advances the one repetitive span of the otherwise human-relayed
pipeline — the `pipeline-impl` multi-card loop — on a cheap model, and **halts at
every contract gate**. It is the write-side twin of the read-only `pipeline-dashboard`:
a sibling that sits **above an unchanged `CONTRACT.md`**, reads the same
`journal.md` state bus, and degrades to plain human-relay when absent.

It is **forbidden to be smart**. The scheduler is deterministic bash; all LLM work
happens inside the per-stage `claude` child. It holds **zero authoritative state** —
the target repo's `.pipeline/<feature>/journal.md` on the remote is the only truth.

## What it does / does not do

**Does:** loop `git fetch` → parse the journal tail → if the tail is the steady-state
`impl→impl` loop with an unchanged, human-confirmed frozen spec, run one
`pipeline-impl` card via `claude` on the configured tier → repeat. Pushes happen
through the normal shim; the driver only reads `origin/<BRANCH>`.

**Does not:** auto-run prd/arch/task/review/hunt; merge (a `permissions.deny` rule
**and** the `deny-merge.sh` PreToolUse hook physically block it); auto-advance past a
re-freeze (a changed `spec-rev` halts for a fresh human read); carry any cross-stage
memory into a child; touch `CONTRACT.md` invariants. See [stop-points.md](stop-points.md).

## The two human gates (never crossed)

1. **GATE 1 — before the loop.** You read the frozen red test and **echo its
   `spec-rev`** to start. Re-fires automatically on any re-freeze.
2. **GATE 2 — after the loop.** You run `pipeline-review` — semantic review + the
   explicit **merge confirm**. Only review merges.

## Files

| file | purpose |
|------|---------|
| `drive.sh` | the deterministic loop + the two-gate predicate |
| `parse-tail.awk` | journal-tail parser (ASCII-anchored; ignores the Unicode `·`/`→` separators) |
| `settings.driver.json` | `--settings` for each driven run: merge `deny` rules + the PreToolUse hook |
| `deny-merge.sh` | the guaranteed merge gate — parses the real Bash command, denies merge / trunk-clobber |
| `drive.config.example` | per-feature config (copy to `drive.config`) |
| `stop-points.md` | the enumerated halt specification + hand-relay checklist |
| `test/run.sh` | unit tests for the parser against a real vendored journal |

## Setup (one-time)

1. Clone next to `pipeline/` as a read-only consumer:
   `git clone <this> ~/workspace/pipeline-driver`.
2. Ensure the `pipeline-*` shims are installed in Claude Code
   (`~/.claude/skills/pipeline-impl/`).
3. **A1 — drive impl on Claude:** repoint the target repo's `.pipeline/roles.yaml`
   `impl` slot to a **Claude-installed** coder skill. The default
   `goal-driven-implementation` is Hermes-only and will STOP under `claude`; the
   driver pre-flights this and warns.
4. `cp drive.config.example drive.config` and edit `WORKDIR`, `BRANCH`, `FEATURE`,
   `IMPL_MODEL` (floor `haiku`; or a gateway model like GLM via `IMPL_BASE_URL` +
   `IMPL_AUTH_TOKEN_ENV`).
5. `bash test/run.sh` — the parser tests must pass.

## Per-feature flow

```
[human, frontier]  /pipeline-prd → /pipeline-arch → /pipeline-task     (interview/design — NOT driven)
[GATE 1, human]    read the frozen red test; ./drive.sh  → echo the spec-rev to authorize
[DRIVER, cheap]    loops pipeline-impl across all cards, pushing each, until HALT
[HALT outcomes]    review → GATE 2 | blocked → pipeline-hunt | re-freeze → re-read+restart | error → inspect
[GATE 2, human]    /pipeline-review → semantic review + explicit merge confirm   (the only merge)
```

Observe progress any time with the read-only dashboard:
`node ~/workspace/pipeline-dashboard/dist/cli.js <WORKDIR> --out board.html`.

## Failure / resume / rollback

- **Zero state → kill+restart is safe.** Restart `./drive.sh`; it re-folds the
  journal tail from `origin/<BRANCH>` and resumes the live position.
- **Mid-card kill** can strand a card `in-progress`; the driver detects this on the
  remote and HALTS, asking you to reset it to `todo` (not fully automatic).
- **Blast radius:** the driven impl cannot merge (deny rule + hook + only-review-merges),
  cannot touch the frozen spec (review's freeze gate), and the merge stays human-gated.
  The merge gate blocks the standard forge routes (`gh`/`gitee-cli`/`gh api`/`curl`/
  graphql) and trunk force-/delete-pushes; it is a gate, not a sandbox. On the normal
  forge path the worst a runaway driver does is push code commits to `feat/<feature>` —
  revertable.

## Relationship to the contract

This driver changes **no** `CONTRACT.md` invariant. The contract already licenses a
non-human orchestrator ("the journal makes the run … orchestratable by anyone — a
human or another LLM reads the tail to take over"). The only contract-repo change is
a one-line note that an optional external driver MAY auto-advance the impl loop and
HALTS at every gate.
