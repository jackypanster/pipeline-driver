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

**Does not:** auto-run prd/arch/task/review/hunt; **reach the merge step at all** — it
HALTS at `NEXT=review` and only ever runs `/pipeline-impl`, which by the contract never
merges (see *Merge safety* below); auto-advance past a re-freeze (a changed `spec-rev`
halts for a fresh human read); carry any cross-stage memory into a child; touch
`CONTRACT.md` invariants. See [stop-points.md](stop-points.md).

## Merge safety (read this before trusting it)

The driver must never let the autonomous loop merge the feature PR or clobber trunk.
Be precise about what is actually enforced:

1. **Control flow — primary, works everywhere.** The driver only ever runs
   `/pipeline-impl` and HALTS at `NEXT=review`, so the feature merge is never even
   attempted in normal operation. `pipeline-impl` by the contract does not merge.
2. **Trunk force-push / deletion protection — server-side, where your plan allows.**
   A branch ruleset blocking `non_fast_forward` + `deletion` on trunk closes the
   trunk-clobber threat server-side, and is **compatible** with the pipeline: normal
   fast-forward metadata pushes and the squash-merge still work; only force-push and
   deletion of trunk are blocked. See *Setup* for the one-command enable. NOTE: rulesets
   / branch protection require a **public** repo or **GitHub Pro/Org** — they are
   unavailable on a free-plan **private** repo.
3. **The feature-PR merge itself has no clean server-side gate for a solo, single-identity
   setup.** "Require a pull request before merging" would *break* this pipeline (it commits
   metadata — including the frozen spec — straight to trunk), and with the agent running
   under your own credentials it cannot tell "you merging" from "the agent merging." So for
   solo use the merge gate IS (1) above plus you doing the merge in `pipeline-review`. In a
   **team**, run impl under a distinct **bot identity** and require PR-merge approval with
   the human on the ruleset bypass list — then the bot cannot merge but you can.
4. **`deny-merge.sh` hook + `permissions.deny` — best-effort speed-bump, NOT a boundary.**
   It regexes the command string, so a determined child can wrap the call (base64, a file,
   an interpreter) past it. It catches accidents and light wrappers, not adversaries.

Bottom line: the merge gate you can rely on is the driver halting before review (1) and
you performing the merge; the hook and trunk-clobber ruleset are hardening, not guarantees.

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
| `deny-merge.sh` | best-effort merge speed-bump (PreToolUse hook); parses the Bash command, denies direct/wrapped merge + trunk-clobber. NOT a boundary — see *Merge safety* |
| `clobber-guard.sh` | trunk-clobber preflight: stdin = branch-rules JSON, exit 0 iff both `non_fast_forward` + `deletion` present |
| `drive.config.example` | per-feature config (copy to `drive.config`) |
| `stop-points.md` | the enumerated halt specification + hand-relay checklist |
| `test/run.sh` | parser unit tests against a format-faithful sample journal |
| `test/hook.sh` | merge-gate tests incl. the wrapper/refspec bypass cases |
| `test/e2e.sh` | hermetic end-to-end loop tests (stub `claude`) + every safety halt |
| `test/preflight.sh` | regression tests for `clobber-guard.sh` (both / only-one / empty) |

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
5. **Protect the target's trunk against force-push / deletion (server-side).** This is
   compatible with the pipeline (metadata fast-forwards + the squash-merge still work).
   Replace `OWNER/REPO` and `<trunk>`:
   ```bash
   gh api repos/OWNER/REPO/rulesets -X POST --input - <<'JSON'
   { "name": "protect-trunk-no-clobber", "target": "branch", "enforcement": "active",
     "conditions": { "ref_name": { "include": ["refs/heads/<trunk>"], "exclude": [] } },
     "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" } ] }
   JSON
   ```
   Requires a **public** repo or **GitHub Pro/Org** — a free-plan **private** repo returns
   403 (then trunk-clobber protection is unavailable; rely on the driver's never-force-push
   discipline). This does **not** gate the feature-PR merge — see *Merge safety* for why the
   merge gate is control-flow (solo) or a bot identity (team), not a `require-PR` rule.
6. `bash test/run.sh && bash test/hook.sh && bash test/preflight.sh && bash test/e2e.sh` — all must pass.

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
- **Blast radius:** the driver halts before review and never authorizes a merge (the
  merge is a human step in `pipeline-review`); the driven impl also cannot touch the
  frozen spec (review's freeze gate). The `deny-merge.sh` hook blocks
  the standard forge routes (`gh`/`gitee-cli`/`gh api`/`curl`/graphql) and trunk
  force-/delete-pushes best-effort (a wrapped command can bypass string matching — see
  *Merge safety*). On the normal forge path the worst a runaway driver does is push code
  commits to `feat/<feature>` — revertable.

## Relationship to the contract

This driver changes **no** `CONTRACT.md` invariant. The contract already licenses a
non-human orchestrator ("the journal makes the run … orchestratable by anyone — a
human or another LLM reads the tail to take over"). The only contract-repo change is
a one-line note that an optional external driver MAY auto-advance the impl loop and
HALTS at every gate.
