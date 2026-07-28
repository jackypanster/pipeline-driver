# pipeline-driver

An **optional, external** driver for the [`pipeline`](https://github.com/jackypanster/pipeline)
toolchain. It auto-advances the one repetitive span of the otherwise human-relayed
pipeline — the `pipeline-impl` multi-card loop — on a cheap model, and **halts at
every contract gate**. It is the **human-operated** write-side twin of the read-only `pipeline-dashboard`:
a sibling that sits **above an unchanged `CONTRACT.md`**, reads the same
`journal.md` state bus, and degrades to plain human-relay when absent.

It is **forbidden to be smart**. The scheduler is deterministic bash; all LLM work
happens inside the per-stage `claude` child. It holds **zero authoritative state** —
the target repo's `.pipeline/<feature>/journal.md` on the remote is the only truth.

## For agents (read this first)

You are an agent in or around a `pipeline`-driven repo. When to reach for this driver, and when not:

- **The drive paradigm is explicit-opt-in, never the default.** The operator's standing SOP
  (recorded in the pipeline repo README §Operating modes): normal human-relayed mode is the
  default for every feature; the driver is used only when the operator explicitly asks, for
  read-only / low-risk features, and the run keeps exactly ONE human touchpoint — the merge
  confirm (a CONTRACT frozen invariant, never delegated).
- **Use it for exactly one thing — the `impl` multi-card loop.** After `pipeline-task` freezes the spec,
  a feature has N cards, each made green by a separate `pipeline-impl` run and hand-relayed
  card→card→…→`pipeline-review`. That relay is the only repetitive span; this driver auto-advances it on
  a cheap model and stops.
- **Do NOT use it — or invent another scheduler — for anything else.** `prd`/`arch`/`task`/`review`/`hunt`
  are interview/semantic stages that stay human-relayed by design. The pipeline deliberately has **no
  scheduler** (see the pipeline `DESIGN.md` rationale); this repo carries exactly ONE sanctioned
  exception, a bounded span with a human read at both ends: `drive.sh`, the `impl` multi-card loop.
  If you are tempted to orchestrate the whole pipeline, don't — that was evaluated and rejected
  because semantic errors compound silently between auto-advanced stages with no human read.
  The other span DESIGN.md authorizes — the review↔fix relay of a toolchain-repo meta-PR — is
  **not a driver script**: it is the `pipeline-coordinate` playbook's Profile A, where a CC session
  dispatches the fixer and reviewer panes over Herdr and reads verdicts off the PR. The
  `review-drive.sh` implementation of that span was retired with the orca transport (one span, one
  implementation).
- **GATE 1 is a read-then-bind gate; who reads is the operator's risk-tier call.** Default: a human
  at a terminal reads the frozen red test and echoes its `spec-rev`. Operator policy (2026-07-08):
  choosing the drive paradigm for a LOW-RISK feature (read-only/ergonomics) is itself the ex-ante
  trust grant, so the coordinating agent MAY type the spec-rev after reading the spec it froze
  (e.g. via `herdr pane run` into the driver's pane). DANGEROUS features (trading
  write-path) never use the driver at all — they run the normal human-relayed pipeline. The
  sha-binding stays load-bearing either way: a mid-loop re-freeze still auto-halts. Record that
  standing grant machine-readably with `YOLO=1` in the global defaults file (§Defaults & YOLO) so
  it does not need re-stating in chat per run.
- **It never merges and cannot cross a gate.** It only ever runs `/pipeline-impl`; it HALTs at every
  gate (e.g. `NEXT=review`, a `blocked` card, a re-freeze — and others); the merge stays a human step in
  `pipeline-review`. See *Merge safety* and [stop-points.md](stop-points.md) for the exact halt list.

If the journal tail says `Run pipeline-impl` and the spec is frozen + human-read, the operator runs the
driver per *Setup* + *Per-feature flow* below. Otherwise, relay the stage by hand as usual.

## What it does / does not do

**Does:** after GATE 1 (a human at a terminal echoes the frozen `spec-rev` to authorize),
loop `git fetch` → parse the journal tail → if the tail is the steady-state
`impl→impl` loop with an unchanged, human-confirmed frozen spec, run one
`pipeline-impl` card via `claude` on the configured tier → repeat. Pushes happen
through the normal shim; the driver only reads `origin/<BRANCH>`.

**Does not:** auto-run prd/arch/task/review/hunt; **reach the merge step at all** — it
HALTS at `NEXT=review` and only ever runs `/pipeline-impl`, which by the contract never
merges (see *Merge safety* below); auto-advance past a re-freeze (a changed `spec-rev`
halts for a fresh human read); carry any cross-stage memory into a child; touch
`CONTRACT.md` invariants. See [stop-points.md](stop-points.md).

## Impl transports

The "run one card" primitive is pluggable (`IMPL_TRANSPORT` in `drive.config`); halt
semantics, GATE 1/2, the spec-rev protocol and every guard are transport-independent.

- **claude (default)** — a fresh headless `claude -p` cold child per card (no `--bare`: it would skip skill loading and OAuth on current Claude Code),
  model per `IMPL_MODEL` (optionally via an Anthropic-compatible gateway).
- **herdr** — types the impl stage command (`IMPL_SLASH_CMD`, default `/pipeline-impl`)
  into a coder TUI running in a [Herdr](https://herdr.dev) pane with `herdr pane run`
  (atomic text+Enter, the officially preferred submit), then polls `origin/<BRANCH>`
  until the journal seq advances or `CARD_TIMEOUT`. The command syntax is the TUI
  agent's: pi registers skills as `/skill:<name>`, so set
  `IMPL_SLASH_CMD=/skill:pipeline-impl` there. For coding-plan models whose gateway
  rejects headless Claude Code (observed: bigmodel.cn answers a fake-529 to the
  `cc_entrypoint=sdk-cli` billing marker), the interactive TUI is the compliant
  channel — the driver only automates the typing a human would do into it.
  The pre-send guard READS `agent_status` and proceeds on `done`/`idle` (Herdr's
  `done` = finished-unviewed never re-fires on an already-idle pane, so the driver
  never bare-waits on `done`), halts fast on `blocked`, and validates readiness AND
  detection authority from the SAME `agent explain` sample on every poll (lifecycle
  hook / MATCHED manifest rule, no fallback — a merely loaded manifest on an
  unrecognized screen is the always-idle fallback) — otherwise the transport **fails
  closed** instead of typing into a pane whose always-idle fallback cannot see a busy
  TUI. A reset is followed by a settle window (`HERDR_RESET_SETTLE_MS`) before the
  second guard, since `pane run` only acknowledges enqueueing. Pane discovery filters
  `herdr pane list` by pane `.cwd == WORKDIR` (or the `HERDR_PANE_CWD_MATCH`
  substring, e.g. a TUI opened in a subdir), targets only agent-bearing panes, and
  excludes the driver's own pane; pin with `HERDR_PANE_ID`. Needs `herdr` + `jq` +
  `perl` (monotonic deadlines + process-group kills). Spec:
  `.pipeline/herdr-transport/PRD.md`.

(An `orca` transport existed alongside `herdr` and was **retired** — Herdr replaced it
as the driven-TUI substrate, so a stale `IMPL_TRANSPORT=orca` is now a blocking doctor
MISS rather than a silent fallback.)

Driven-TUI (herdr) deltas to know: there is **no child exit code** — the only
completion signal is the remote journal (a stuck TUI = `CARD_TIMEOUT` halt, with the
pane tail printed); the deny-merge `--settings` hook does **not** travel into
the TUI agent (the durable gates — halt-before-review, human merge, trunk rules — hold
regardless); the TUI is a **long session**, not a cold node per card
(`HERDR_RESET_CMD` approximates a cold start — both sides of the reset
are guarded); it needs `jq`, `perl`, the substrate's runtime, and a TUI agent that has the
`pipeline-impl` shim + the roles.yaml impl skill installed with permissions to finish a
card unattended. While a driven loop runs, keep other agents out of that worktree.
Pane discovery: **pin `HERDR_PANE_ID`** per run — pane ids die with the pane, and TUI
agents rename their own tab on startup so title matching goes stale (field-tested on
the first trial run). Herdr injects `HERDR_PANE_ID` into every pane it manages —
including the one running the driver — so the driver captures and unsets the inherited
value, excludes its own pane from discovery, and rejects a pinned target equal to it.

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
3. **The feature-PR merge itself has no clean server-side gate — solo OR team.** "Require a
   pull request before merging" would *break* this pipeline **regardless of identity**: it
   commits metadata (incl. the frozen spec) straight to trunk, and require-PR blocks every
   non-bypass identity's direct push — so a bot OFF the bypass list cannot even push its
   metadata (the driver can't run), and a bot ON the bypass list can also merge. A distinct
   **bot identity** for a team only reduces blast radius (you can tell who did what); it does
   not buy a clean server-side merge gate. So the merge gate is always (1) above plus a human
   performing the merge in `pipeline-review`.
4. **`deny-merge.sh` hook + `permissions.deny` — best-effort speed-bump, NOT a boundary.**
   It regexes the command string, so a determined child can wrap the call (base64, a file,
   an interpreter) past it. It catches accidents and light wrappers, not adversaries.

Bottom line: the merge gate you can rely on is the driver halting before review (1) and
you performing the merge; the hook and trunk-clobber ruleset are hardening, not guarantees.

## The two gates (never crossed)

1. **GATE 1 — before the loop.** The frozen red test is read and its **`spec-rev`
   echoed** to start; re-fires automatically on any re-freeze. Who performs the read
   is the operator's risk-tier call (see *For agents*): default a human, delegable to
   the coordinating agent only for explicitly low-risk drive-mode features.
2. **GATE 2 — after the loop.** `pipeline-review` runs (any capable review bot) —
   semantic review + the explicit **HUMAN merge confirm, never delegated**. Only
   review merges.

## Files

| file | purpose |
|------|---------|
| `drive.sh` | the deterministic impl loop + the two-gate predicate |
| `parse-tail.awk` | journal-tail parser (ASCII-anchored; ignores the Unicode `·`/`→` separators) |
| `settings.driver.json` | `--settings` for each driven run: merge `deny` rules + the PreToolUse hook |
| `deny-merge.sh` | best-effort merge speed-bump (PreToolUse hook); parses the Bash command, denies direct/wrapped merge + trunk-clobber. NOT a boundary — see *Merge safety* |
| `clobber-guard.sh` | trunk-clobber preflight: stdin = branch-rules JSON, exit 0 iff both `non_fast_forward` + `deletion` present |
| `drive.config.example` | per-feature config (copy to `drive.config`): WORKDIR/BRANCH/FEATURE + per-run handle |
| `drive.defaults.example` | GLOBAL defaults (copy once to `~/.config/pipeline-driver/drive.defaults`): transport, tuning, `YOLO` |
| `stop-points.md` | the enumerated halt specification + hand-relay checklist |
| `test/run.sh` | parser unit tests against a format-faithful sample journal |
| `test/hook.sh` | merge-gate tests incl. the wrapper/refspec bypass cases |
| `test/e2e.sh` | hermetic end-to-end loop tests (stub `claude`) + every safety halt |
| `test/notify-hook.sh` | hermetic tests for the `NOTIFY_EXEC` walk-away hook (events, env, preflight validation, degradation) |
| `test/e2e-herdr.sh` | hermetic e2e for the herdr transport (stub `herdr`; guards, self-pane, fail-closed) |
| `test/preflight.sh` | regression tests for `clobber-guard.sh` (both / only-one / empty) |
| `test/defaults-doctor.sh` | hermetic tests for the defaults layer + `drive.sh doctor` |
| `test/board.sh` | hermetic tests for `BOARD_OUT` auto-refresh + the review halt shape |
| `coordinate.sh` | read-only `doctor` + `status` — the COMPLETE surface (the `watch`/`resume` dispatch half was rejected: PR #14 closed; pivot in design v1.3 §25); the cross-stage sibling of `drive.sh`, see §coordinate.sh |
| `coordinate.config.example` | per-repo config for it (copy to `coordinate.config`): observer + CC/Pi/Codex clones, command prefixes |
| `test/coordinate-*.sh` | hermetic suites for the coordinator: parse-tail, config validation, doctor, status, remote-identity, bounded-exec watchdog |

## Setup (one-time)

1. Clone next to `pipeline/` as a read-only consumer:
   `git clone <this> ~/workspace/pipeline-driver`. The driver runs in place — no install step.
2. Ensure the `pipeline-*` shims + the impl-slot skill resolve on the runtime that runs
   impl (claude transport: Claude Code's skill dir; herdr transport: the TUI
   agent's skill dir). Follow the pipeline repo README §Install → *Canonical multi-runtime layout* —
   one shared physical copy (`~/.agents/skills`), each runtime attached by symlink/wrapper.
3. **A1 — drive impl on Claude (claude transport only):** repoint the target repo's
   `.pipeline/roles.yaml` `impl` slot to a **Claude-installed** coder skill. The default
   `goal-driven-implementation` is Hermes-only and will STOP under `claude`; the
   driver pre-flights this and warns. (The herdr transport drives the TUI agent's
   own runtime, where its native impl skill resolves — no repoint needed there.)
4. One-time: `mkdir -p ~/.config/pipeline-driver && cp drive.defaults.example
   ~/.config/pipeline-driver/drive.defaults`, then set your stable preferences there
   (transport, `IMPL_MODEL` floor `haiku` / gateway via `IMPL_BASE_URL` +
   `IMPL_AUTH_TOKEN_ENV`, tuning, `YOLO`). Per feature: `cp drive.config.example
   drive.config` and set just `WORKDIR`, `BRANCH`, `FEATURE` (+ the per-run
   `HERDR_PANE_ID` on the herdr transport) — drive.config wins on conflict.
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
6. `bash test/run.sh && bash test/hook.sh && bash test/preflight.sh && bash test/e2e.sh && bash test/e2e-herdr.sh && bash test/defaults-doctor.sh && bash test/board.sh && bash test/notify-hook.sh && bash test/coordinate-parse.sh && bash test/coordinate-config.sh && bash test/coordinate-doctor.sh && bash test/coordinate-status.sh && bash test/coordinate-remote.sh && bash test/coordinate-watchdog.sh && bash test/coordinate-bindings.sh` — all must pass.
7. `./drive.sh doctor` — install/config diagnosis for the pipeline + dashboard + driver trio
   (deps, sibling repos, dashboard build, skills attachment, config files). Every MISS
   prints the exact remediation command; it installs nothing
   and touches no network. Re-run until `0 blocking`.

## Per-feature flow

```
[human, frontier]  /pipeline-prd → /pipeline-arch → /pipeline-task     (interview/design — NOT driven)
[GATE 1, human]    read the frozen red test; ./drive.sh  → echo the spec-rev to authorize
[DRIVER, cheap]    loops pipeline-impl across all cards, pushing each, until HALT
[HALT outcomes]    review → GATE 2 | blocked → pipeline-hunt | re-freeze → re-read+restart | error → inspect
[GATE 2, human]    /pipeline-review → semantic review + explicit merge confirm   (the only merge)
```

Observe progress any time with the read-only dashboard:
`node ~/workspace/pipeline-dashboard/dist/cli.js <WORKDIR> --out board.html` — or set
`BOARD_OUT` and the driver keeps that file fresh for you (§Board & walk-away notify).

## Defaults & YOLO

Config is layered: `~/.config/pipeline-driver/drive.defaults` (global, optional — override the
path with `$DRIVE_DEFAULTS`) is sourced first, `./drive.config` (per-feature) second and wins.
Stable machine-wide choices — transport, model tier, tuning, slot-binding documentation
(prd/arch/task on a frontier Claude, impl on the pi TUI, review on codex) — live in the defaults;
a feature needs only three lines.

`YOLO=1` in the defaults records the operator's **standing ex-ante grant** (the 2026-07-08
GATE 1 policy) machine-readably: for a LOW-RISK feature the coordinating agent may read the
frozen spec and echo the `spec-rev` — no per-run chat authorization. It changes NOTHING else:
starting `./drive.sh` stays an explicit per-feature act (drive is never the default mode), the
merge confirm stays human (frozen invariant), and DANGEROUS features never use the driver.

## Board & walk-away notify

**Walk-away notify hook.** Non-empty `NOTIFY_EXEC` (an absolute path to an executable
regular file; validated and ARMED at the very top of preflight, before any other
check that can halt — so a broken notifier halts BEFORE GATE 1 instead of silently
never pinging an operator who already left) is invoked best-effort at the same three
moments as `BOARD_OUT`: after GATE 1, after every advanced card, and on every halt.
The event name arrives in `$1` (`gate1`|`card`|`halt`), context in `DRIVE_*` env
(`DRIVE_EVENT`/`DRIVE_FEATURE`/`DRIVE_BRANCH`/`DRIVE_WORKDIR`/`DRIVE_TRANSPORT`/
`DRIVE_SEQ`/`DRIVE_STATUS`/`DRIVE_NEXT`, plus `DRIVE_HALT_REASON` +
`DRIVE_HALT_NEXT` on halts). Runtime failures warn once and never halt the loop.
The canonical adapter is `pipeline-dispatch/notify.sh`, which forwards the events to
Telegram via the local Hermes — the operator walks away and is called back only by
the 🛑 halt ping. Strictly ONE-WAY by design: nothing flows from the notifier back
into the driver, and no gate moves — GATE 1/2 semantics are byte-identical with the
hook on or off. (A human→driver remote-command lane is a separate future design,
deliberately NOT this hook.)

The notifier is **defense-in-depth, not a sandbox.** `NOTIFY_EXEC` is a TRUSTED
executable that runs as YOUR user with normal filesystem, process, and network
access — it is NOT OS-isolated, so only point it at a hook you trust. Three
measures limit accidental damage and accidental credential leakage:
- a hard per-invocation deadline (`NOTIFY_TIMEOUT_MS`, a validated positive integer,
  default 5000 ms; out of range is rejected at preflight) that kills the notifier's
  whole process group (TERM then KILL, via perl `setpgrp` — required, so a wedged or
  TERM-immune send degrades to a single warn and cannot suppress GATE 1, card
  progress, or the halt banner);
- stdin redirected from `/dev/null` (immediate EOF), so the hook cannot consume the
  GATE 1 / rejection-gate prompt or later operator input;
- and a **reduced environment** launched via `env -i`: the hook receives ONLY
  `PATH`/`HOME` + the `DRIVE_*` context, plus any names you list in
  `NOTIFY_ENV_ALLOW`. This means ambient *exported variables* — `GH_TOKEN`,
  `ANTHROPIC_*`, and the secret named by `IMPL_AUTH_TOKEN_ENV` — are NOT inherited
  unless you allow them. Note this is an environment allowlist only: because `HOME`
  and `DRIVE_WORKDIR` are forwarded and the hook runs as you, it can still read files
  under `HOME` (e.g. `~/.config/gh/hosts.yml`) or write the workdir — so it is a
  credential-leak guard, not a credential boundary. (deny by default; opt a variable
  in via `NOTIFY_ENV_ALLOW`.)

**Board auto-refresh.** Non-empty `BOARD_OUT` makes the driver re-render the read-only
dashboard (needs `node` + a built `DASHBOARD_REPO`) after GATE 1, after every advanced
card, and on every halt — keep it open in a browser and the board is always current.
Best-effort side effect: a render failure warns once and never halts the loop.

**Meta-PR review relay — not here.** The review↔fix shuttle for a toolchain-repo PR
lives in the `pipeline-coordinate` playbook (Profile A): a CC session dispatches the
fixer and reviewer panes over Herdr and reads verdicts off the PR itself. The driver
carries no second implementation of it — `review-drive.sh` and the one-key relay were
retired with the orca transport. At the `NEXT=review` halt the driver just prints its
banner and exits; the coordinator (or you) dispatches `pipeline-review` from there.

## coordinate.sh — cross-stage preflight + summary

`coordinate.sh` is the **cross-stage sibling of `drive.sh`** for a coordinated feature.
`drive.sh` owns the impl card loop; `coordinate.sh` holds **zero local state** and only
reads the target repo's `.pipeline/<feature>/` artifacts (and, for `doctor`, the role
panes). Its **complete** surface is two read-only commands: `doctor` (full preflight)
and `status` (summary). The dispatch half (`watch`/`resume`) was **deliberately
rejected** — bash dispatch cannot satisfy the design without breaking `drive.sh`'s
interactive trust gate. PR #14 was closed unmerged:
https://github.com/jackypanster/pipeline-driver/pull/14 . The pivot to coordinated-mode
dispatch (the CC-as-coordinator playbook) is recorded in the design doc v1.3 §25,
pinned at https://github.com/jackypanster/pipeline-driver/blob/19e8c954/coordinator-design.md
(PR #15 documented the pivot: https://github.com/jackypanster/pipeline-driver/pull/15 ).

**Setup:** `cp coordinate.config.example coordinate.config` and fill it per the file's
comments — one observer clone plus three role clones (`CC_WORKDIR`/`PI_WORKDIR`/
`CODEX_WORKDIR`) that all resolve to the SAME normalized remote identity and trunk
`BRANCH`, and the five stage command prefixes. Optional pane pins
(`CC_PANE_ID`/`PI_PANE_ID`/`CODEX_PANE_ID`) override discovery. Every value is validated
before use; command prefixes are data appended to a safely-constructed argv and are
never `eval`'d.

**`doctor --config <path>`** — read-only full preflight. It checks dependencies
(git/jq/herdr/perl), validates the whole config, confirms the four clones share one
normalized remote identity and are all on `BRANCH`, performs **one** `git fetch` in
the observer clone (the bounded-exec guard wraps only the two `herdr` reads —
`agent explain` and `pane list`), and — when an active coordinated feature is observed — parses
`control.json` and the journal tail. It then resolves each role pane via `herdr pane list`
(self pane **excluded**, distinct panes required) and proves lifecycle/manifest **authority**
for each (the always-idle fallback is rejected). It installs nothing and never mutates
target-repo state — the single fetch DOES update the observer clone's remote-tracking
refs / `FETCH_HEAD` (a local observer-clone side effect, not a target-repo write). Every
MISS prints the exact §14 tuple (code / where / input / reason / next_action) with its
remediation. A completed run ends with a summary line
`doctor: N blocking, M warning(s)` (non-zero exit if any blocking MISS fired); a malformed
config (e.g. `BRANCH` unset) can also abort earlier with a fatal error before the summary.

> Run `doctor` from a **non-role** shell. The tool captures its own `HERDR_PANE_ID` as
> "self" and excludes that pane from role resolution; running it inside a role pane makes
> that role unresolvable and fails `PANE_NOT_FOUND` by design.

**`status --config <path>`** — **no network**. It validates the config, reads the
observer's `HEAD:.pipeline/current.json`, and prints **exactly one** human line plus one
compact JSON object `{"feature": <slug|null>}`: `coordinate: feature=<slug> (from HEAD
current.json)` when an active feature is present, or `coordinate: idle (no active
feature)` with `{"feature": null}` otherwise. A malformed feature slug is rejected with
`CONFIG_INVALID` (it can never traverse a `git show` path or inject output). The
machine-bindings block goes to stderr so stdout keeps its one-line + one-object contract.

Both commands also print a **machine-bindings** block: the merged `drive.defaults` →
`coordinate.config` view of the optional `CC/IMPL/REVIEW _AGENT` + `_MODEL_EXPECT`
fields (which TUI drives each role pane, and the model expected in its footer). With a
`*_MODEL_EXPECT` set, `doctor` **fail-closed-verifies** it as a literal case-insensitive
substring of that pane's live footer (`MODEL_MISMATCH` otherwise) — three-roles-on-three-models
becomes a machine check instead of an eyeball of the pane footer.

## Failure / resume / rollback

**drive.sh** (journal/card machinery):

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

This driver changes **no** `CONTRACT.md` invariant — `CONTRACT.md` itself is untouched.
The contract already licenses a non-human orchestrator ("the journal makes the run …
orchestratable by anyone — a human or another LLM reads the tail to take over"). The only
change in the contract repo is a one-line note **in `DESIGN.md` §Constraints** (commit
`ef4fa97`) that an optional external driver MAY auto-advance the impl loop and HALTS at
every gate.
