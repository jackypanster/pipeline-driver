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
  scheduler** (see the pipeline `DESIGN.md` rationale); this repo carries the only two sanctioned
  exceptions, each a bounded span with a human read at both ends: `drive.sh` (the `impl` multi-card
  loop) and `review-drive.sh` (the review↔fix rounds of a TOOLCHAIN-repo PR — operator policy
  2026-07-12, see §review-drive). If you are tempted to orchestrate the whole pipeline, don't — that was
  evaluated and rejected because semantic errors compound silently between auto-advanced stages with no
  human read. The meta-PR loop is different in kind, not an exemption from that rationale: it is
  ADVERSARIAL (the reviewer's job each round is to catch the fixer's errors, so nothing advances
  unchecked), its failure mode is non-convergence, and that is bounded by the round cap, the
  no-progress halt, and the human merge gate. It never drives the feature pipeline's `review` stage.
- **GATE 1 is a read-then-bind gate; who reads is the operator's risk-tier call.** Default: a human
  at a terminal reads the frozen red test and echoes its `spec-rev`. Operator policy (2026-07-08):
  choosing the drive paradigm for a LOW-RISK feature (read-only/ergonomics) is itself the ex-ante
  trust grant, so the coordinating agent MAY type the spec-rev after reading the spec it froze
  (e.g. via `orca terminal send` into the driver's terminal). DANGEROUS features (trading
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
- **orca** — types the impl stage command (`IMPL_SLASH_CMD`, default `/pipeline-impl`)
  into a live Orca-managed TUI terminal (e.g. pi running GLM) with `orca terminal
  send`, then polls `origin/<BRANCH>` until the journal seq advances or
  `CARD_TIMEOUT`. The command syntax is the TUI agent's: pi registers skills as
  `/skill:<name>`, so set `IMPL_SLASH_CMD=/skill:pipeline-impl` there.
  For coding-plan models whose gateway rejects
  headless Claude Code (observed: bigmodel.cn answers a fake-529 to the
  `cc_entrypoint=sdk-cli` billing marker), the interactive TUI is the compliant
  channel — the driver only automates the typing a human would do into it.

Orca-transport deltas to know: there is **no child exit code** — the only completion
signal is the remote journal (a stuck TUI = `CARD_TIMEOUT` halt, with the terminal tail
printed); the deny-merge `--settings` hook does **not** travel into the TUI agent (the
durable gates — halt-before-review, human merge, trunk rules — hold regardless); the
TUI is a **long session**, not a cold node per card (`ORCA_RESET_CMD` approximates cold
starts); it needs `jq`, a running Orca runtime, and a TUI agent that has the
`pipeline-impl` shim + the roles.yaml impl skill installed with permissions to finish a
card unattended. While a driven loop runs, keep other agents out of that worktree.
Terminal discovery: **pin `ORCA_TERMINAL_HANDLE`** — TUI agents rename their own tab on
startup, so title matching goes stale (field-tested on the first trial run); the driver
also unsets any INHERITED `ORCA_TERMINAL_HANDLE` before reading config, because Orca
injects it into every terminal it manages — including the one running the driver.

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
| `review-drive.sh` | the deterministic meta-PR review↔fix loop (§review-drive) |
| `review-drive.config.example` | per-run config for it: the two terminal handles + tuning |
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
| `test/e2e-orca.sh` | hermetic e2e for the orca transport (stub `orca` plays the TUI coder) |
| `test/preflight.sh` | regression tests for `clobber-guard.sh` (both / only-one / empty) |
| `test/defaults-doctor.sh` | hermetic tests for the defaults layer + `drive.sh doctor` |
| `test/board-relay.sh` | hermetic tests for `BOARD_OUT` auto-refresh + the one-key review relay |
| `test/review-drive.sh` | hermetic e2e for the meta-PR loop (stub `gh` + stub `orca` play GitHub/codex/pi) |

## Setup (one-time)

1. Clone next to `pipeline/` as a read-only consumer:
   `git clone <this> ~/workspace/pipeline-driver`. The driver runs in place — no install step.
2. Ensure the `pipeline-*` shims + the impl-slot skill resolve on the runtime that runs
   impl (claude transport: Claude Code's skill dir; orca transport: the TUI agent's skill
   dir). Follow the pipeline repo README §Install → *Canonical multi-runtime layout* —
   one shared physical copy (`~/.agents/skills`), each runtime attached by symlink/wrapper.
3. **A1 — drive impl on Claude (claude transport only):** repoint the target repo's
   `.pipeline/roles.yaml` `impl` slot to a **Claude-installed** coder skill. The default
   `goal-driven-implementation` is Hermes-only and will STOP under `claude`; the
   driver pre-flights this and warns. (The orca transport drives the TUI agent's own
   runtime, where its native impl skill resolves — no repoint needed there.)
4. One-time: `mkdir -p ~/.config/pipeline-driver && cp drive.defaults.example
   ~/.config/pipeline-driver/drive.defaults`, then set your stable preferences there
   (transport, `IMPL_MODEL` floor `haiku` / gateway via `IMPL_BASE_URL` +
   `IMPL_AUTH_TOKEN_ENV`, tuning, `YOLO`). Per feature: `cp drive.config.example
   drive.config` and set just `WORKDIR`, `BRANCH`, `FEATURE` (+ the per-run
   `ORCA_TERMINAL_HANDLE` on the orca transport) — drive.config wins on conflict.
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
6. `bash test/run.sh && bash test/hook.sh && bash test/preflight.sh && bash test/e2e.sh && bash test/e2e-orca.sh && bash test/defaults-doctor.sh && bash test/board-relay.sh && bash test/review-drive.sh && bash test/setup-plumbing.sh && bash test/setup-defaults.sh && bash test/setup-pboard.sh && bash test/setup-target.sh` — all must pass.
7. `./drive.sh doctor` — install/config diagnosis for the pipeline + dashboard + driver trio
   (deps, sibling repos, dashboard build, skills attachment, config files, live Orca terminals
   to pin handles from). Every MISS prints the exact remediation command; it installs nothing
   and touches no network. Re-run until `0 blocking`.

### Setup wizard (`./drive.sh setup`)

`./drive.sh setup` is the automated form of the one-time checklist above — an fzf-driven,
idempotent, overwrite-safe install/config wizard for the trio. It is a peer of `doctor`
(reachable only as a `drive.sh` subcommand), and it **ends on `doctor` as the sole success
signal**: setup never prints its own "done", so it can never report a false green. Any step
it cannot automate prints the exact `fix:` remediation and counts as blocking.

- **Headless / CI:** `SETUP_YES=1` (or `--yes` / `-y`) runs the whole wizard with no fzf /
  no `read`; every answer resolves to its `SETUP_<KEY>` env override if set, else its default.
  One code path serves interactive and headless, so headless is the real flow, not a fork.
- **Skip a step:** `SETUP_DO_<STEP>=0` for any of `DEPS SOURCES SKILLS DASHBOARD PBOARD
  DEFAULTS TARGET DOCTOR` (default `1` for each). Run a no-op dry check with
  `SETUP_YES=1 SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 \
  SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=1 ./drive.sh setup`.
- **Idempotent:** generated config (`drive.defaults`, a target repo's `.pipeline/roles.yaml`)
  is rendered to memory first; if identical to the existing file it is a no-op (no write, no
  `.bak`); if different, the prior file is copied to `<file>.bak` once, then the new one is
  written. The `pboard()` shell block is fenced by `# >>> pipeline pboard >>>` …
  `# <<< pipeline pboard <<<` and replaces only its own marked region.
- **What it never does:** declare success on its own, `git reset --hard` a source repo
  unprompted (`SETUP_REFRESH_SOURCES=0` default), or scaffold a per-feature `drive.config`
  (that is a per-feature act — see *Per-feature flow*). After it runs, re-run `./drive.sh doctor`
  until `0 blocking`.

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
`BOARD_OUT` and the driver keeps that file fresh for you (§Board & review relay).

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

## Board & review relay

**Board auto-refresh.** Non-empty `BOARD_OUT` makes the driver re-render the read-only
dashboard (needs `node` + a built `DASHBOARD_REPO`) after GATE 1, after every advanced
card, and on every halt — keep it open in a browser and the board is always current.
Best-effort side effect: a render failure warns once and never halts the loop.

**One-key review relay.** With `REVIEW_TERMINAL_HANDLE` (preferred; pin per run) or a
unique `REVIEW_TERMINAL_TITLE` configured, the `NEXT=review` halt prints its banner
first, then OFFERS:
`review relay — send "/pipeline-review repo=… branch=…" to terminal …? [y/N]`. You read
the halt, you press `y`, `orca terminal send` does the typing into the review TUI (e.g.
codex; the review shim rebuilds all state from the journal tail per the CONTRACT). This
automates the TYPING of the hand-relay, not the decision: default is N, unconfigured =
silent no-op, and it is NOT a review scheduler — the halt still fires, the review stage
and the GATE 2 human merge confirm are untouched.

## review-drive.sh — the meta-PR review↔fix loop

The 8-round review of pipeline PR #39 was relayed by hand: each codex verdict pasted to
the fixer, each fix pasted back for re-review. `review-drive.sh` automates exactly that
shuttle for **toolchain-repo PRs** and nothing else — enforced in code, not just
documented: the PR's repo must match `REVIEW_REPO_RE` (default: `jackypanster/pipeline`
and the `-driver`/`-dashboard`/`-dispatch` siblings) and fork (cross-repository) PRs are
refused at preflight. The lane it serves is the **canonical meta-PR gate**
(pipeline CONTRACT.md §Self-improvement): `pipeline-improve` opens the PR,
**`pipeline-review` in meta-PR mode** reviews it — semantic only: real improvement, no
weakening, every hard rule and frozen invariant preserved — and the merge is the
**human-confirm + reviewer-only squash-merge**; the proposer never merges. The siblings
run the same convention for their own PRs (this repo's entire PR history included). The
loop automates the TYPING between verdicts, never a review judgment and never the
merge: the review dispatch invokes that meta-PR-mode review (set `REVIEW_SLASH_CMD`,
e.g. codex `$pipeline-review`, to prefix it with your runtime's skill command), the
verdict lands on the PR, and `approved` halts for the human-confirm. It never drives
the feature pipeline's `review` stage (that is the 5-stage state machine inside a
target repo, untouched here). The authorization for this second bounded span lives in
the **canonical design itself** — pipeline PR #40, which amends `DESIGN.md`
§Constraints AND extends `CONTRACT.md` §Self-improvement + the `pipeline-review`
meta-PR predicate, so the lane is mechanically REACHABLE for sibling-repo and
doc-only proposals — not unilaterally in this repo; this PR's merge follows that one.

```
            ┌──────────────────────────────┐
            │   the GitHub PR (state bus)  │
            │  head SHA · comments · state │
            └───────▲──────────▲───────────┘
      gh read+post  │          │  gh read · push · evidence comment
        ┌───────────┴──┐    ┌──┴───────────┐
        │ reviewer TUI │    │  fixer TUI   │
        │   (codex)    │    │    (pi)      │
        └───────▲──────┘    └──────▲───────┘
   orca send    │                  │   orca send
   "review PR#N │                  │  "PR#N head X rejected —
    at head X"  └ review-drive.sh ─┘   read the review via gh, fix"
                 (deterministic bash: polls gh, types one-line
                  dispatches, counts rounds — never forwards text)
```

Same iron rules as `drive.sh`: deterministic bash, forbidden to be smart, zero local
state, and TUI screen text is never a completion signal. The two TUIs never talk to
each other and the driver never forwards review TEXT — each side reads the PR itself
via `gh`; orca only types a one-line dispatch (a pointer: PR URL + head SHA + comment
URL), and the review dispatch's **first token is the canonical skill invocation**
(`REVIEW_SLASH_CMD`, required non-empty, default `/pipeline-review`; codex ≥0.144
wants `$pipeline-review`) — the relayed review must BE `pipeline-review` in meta-PR
mode, never generic prose. Verdicts travel as machine-readable protocol lines in
plain PR comments — `verdict:` / `reviewed-head:` / `reviewed-base:` / `findings:` /
`review-nonce:` from the reviewer, `fixed:` / `fix-nonce:` from the fixer — because
both sides share one GitHub account, which cannot approve/request-changes on its own
PR. Protocol comments are **authenticated twice over**: only comments authored by the
gh-authenticated login (override: `PROTOCOL_AUTHOR`) parse at all — a drive-by
`verdict: approved` is inert text — and within the shared account the ROLES are
separated by per-dispatch **nonces**, typed only into that role's terminal and echoed
back in the comment: the fixer never sees the review nonce so it cannot forge a
verdict, the reviewer never sees the fix nonce so it cannot forge a fix, and no stale
comment steers the LIVE loop. SHA echoes bind **exactly** — full 40 characters,
string equality, never a prefix: a verdict must name BOTH the head and the base tip
it reviewed (`reviewed-base:` mismatch halts like a head mismatch), and a fix is
accepted only when its echoed sha IS the live head. Each review round additionally
pins the live **base OID** at dispatch: a base that moves mid-review halts the round.

Kill+restart **resumes fail-closed**: a prior session's nonces are unknowable, so
same-author verdict history is folded ONLY into quantities a forged or nonce-less
comment can **tighten** — the round budget, the no-progress streak, and the digest —
and never into approval or phase. A restart therefore always **re-reviews** the live
head/base with a fresh nonce: a historical `approved` (any head, with or without a
nonce) cannot terminate a new session, and an unfixed rejection is re-stated by a
fresh review rather than trusted as a fix instruction. And because the fixer is the
terminal that receives WRITE-and-push instructions, its identity is **proven, not
assumed**: both pinned handles must be live+writable in the current orca listing, and
the fixer's `worktreePath` must be a git checkout whose `origin` IS the PR's repo —
re-proven before EVERY fix dispatch to be sitting on the PR's topic branch, **clean**
(no uncommitted or untracked state to leak into pushed commits), and with `HEAD`
**equal to the round's live PR head** (a stale checkout would build the fix on the
wrong base). Anything unprovable fails closed before a single character is typed.

Per round: dispatch the review → poll `gh` until a verdict comment lands on the CURRENT
head (new comments are detected by a comment-INDEX baseline, immune to local↔GitHub
clock skew) → `approved` halts for YOUR merge → otherwise dispatch the fix → poll until
the head advances **fast-forward** (a diverged compare = force-push/rebase = halt) AND a
`fixed:` evidence comment lands → next round. Convergence guards, all deterministic:

- `MAX_ROUNDS=5` — pipeline PR #39 needed 8 rounds WITH a human curating each one and a
  mid-course strategy pivot; an unattended loop past ~5 is more likely ping-pong or
  reviewer scope-growth than progress, and a PR that genuinely needs more deserves a
  human read mid-way. Early halt is information, not friction.
- no-progress halt — `findings:` failed to **provably** decrease for 2 consecutive
  reviews. A decrease is proven only between two LIVE nonce-bound verdicts: a
  missing or unparseable count, and any comparison against an unauthenticated
  historical value, count as no progress — so neither protocol drift nor forged
  history can smuggle convergence (history can only GROW the streak, never reset
  it). Biased fail-closed on purpose: a genuinely-deepening review (PR #39 rounds
  7→8) also trips it, and that too is a moment a human should look.
- `HUNT_AFTER=3` — from that fix dispatch on, the fix prompt switches to root-cause
  mode (reproduce + confirm cause + state the restored invariant before patching): the
  move that actually closed PR #39.

Every halt prints a per-round digest (verdict, findings count, head, comment URL) — the
PR thread is the only memory, so the human enters with full context. The full halt
table lives in stop-points.md §review-drive.

**Merge safety, precisely** (same posture as §Merge safety above): the durable gate is
control flow — the loop contains no merge call, `approved` halts for the operator, and
a PR merged/closed behind its back halts on detection. The dispatch prompts forbid
merging, but a prompt is a speed-bump, not a boundary: the TUI agents run under the
operator's own `gh` auth, so the hard lines remain the trunk rulesets (§Setup step 5)
and the operator reading the PR before performing the merge.

Run: pin the two handles in `review-drive.config` (copy the example; the reviewer
terminal shares `REVIEW_TERMINAL_HANDLE` with the one-key relay), then
`./review-drive.sh <pr-number-or-url>` and type the PR number at the start gate.
Deps: `gh` (authed), `jq`, `orca`, both TUIs live in Orca terminals.

## Failure / resume / rollback

**drive.sh** (journal/card machinery — does NOT apply to review-drive):

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

**review-drive.sh** (no journal, no cards, no frozen spec, no `deny-merge.sh` — its
state bus and guards are the PR itself):

- **Zero state → kill+restart RESUMES fail-closed.** Same-author verdict history is
  folded only into the round budget, no-progress streak and digest (quantities a
  forged comment can only tighten); approval and phase are never taken from history —
  the restart re-reviews the live head/base with a fresh nonce (§review-drive).
- **Mid-round kill** leaves at most a dispatched TUI still working; on restart the
  resume scan either counts its verdict (budget) or the fresh review supersedes it.
  Nothing is stranded — the PR is the only memory.
- **Blast radius:** worst case is commits on the PR topic branch plus PR comments —
  both revertable; trunk is never touched. The loop contains no merge call; a merge
  behind its back halts on detection; the durable lines are the protocol
  authentication, the trunk rulesets, and the human-confirm before the reviewer's
  squash-merge (§review-drive *Merge safety, precisely*).

## Relationship to the contract

This driver changes **no** `CONTRACT.md` invariant — `CONTRACT.md` itself is untouched.
The contract already licenses a non-human orchestrator ("the journal makes the run …
orchestratable by anyone — a human or another LLM reads the tail to take over"). The only
change in the contract repo is a one-line note **in `DESIGN.md` §Constraints** (commit
`ef4fa97`) that an optional external driver MAY auto-advance the impl loop and HALTS at
every gate.
