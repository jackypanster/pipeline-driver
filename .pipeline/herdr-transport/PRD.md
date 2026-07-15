# PRD — `IMPL_TRANSPORT=herdr`: drive the impl loop through a Herdr pane

Stage: prd · Feature: `herdr-transport` · Repo: `jackypanster/pipeline-driver` · Branch: `main`

> Filed 2026-07-14 as a queued TODO feature (prd stage only). Scheduled 2026-07-15 into the
> **meta-PR lane** (see Resolved decisions); still does not touch `.pipeline/current.json`
> (which stays on the parked `drive-setup` run).

## Problem

The driver's `orca` impl transport (`drive.sh:485` `run_impl_orca`) is today the only way to
auto-advance the impl loop against an **interactive coder TUI** (e.g. `pi` running GLM) instead of a
headless `claude` child — the transport that dodges the Zhipu coding-plan gateway's
headless-fingerprint block on `claude` (`drive.sh` header:38-40). But it binds that capability to
**Orca**, a heavyweight Electron ADE (embedded VS Code + Chromium + WebGL terminal). An operator who
wants the same "type the card into a live TUI, poll git for completion" loop on a **lightweight
substrate** has no option: it is Orca-or-headless. The intent is to use **Herdr** — a single Rust TUI
binary (agent-aware tmux) — as a peer substrate, shedding the IDE weight the pipeline never uses.

## Goal

Add a third impl transport `IMPL_TRANSPORT=herdr` that drives the impl loop by typing
`$IMPL_SLASH_CMD …` into a coding-agent TUI (`pi`/`codex`/`claude`) running inside a **Herdr pane**,
reusing the existing git-poll completion path verbatim. Adding it must **not** change the `claude`
(default) or `orca` transports; selecting it is a config switch and rollback is not-setting it.

## Success criteria (freezable spec surface)

Testable hermetically in the existing `test/*.sh` style (model: `test/e2e-orca.sh` — a stubbed `herdr`
on PATH, temp `HOME`/XDG, no network, no real Herdr runtime):

1. **Transport dispatch.** With `IMPL_TRANSPORT=herdr`, `run_impl` (`drive.sh:512`) routes to a new
   `run_impl_herdr`; the `claude` and `orca` branches are byte-unchanged.
2. **Preflight.** `drive.sh doctor` with `IMPL_TRANSPORT=herdr` checks `herdr` + `jq` on PATH with
   exact remediation (mirrors the `orca` doctor branch, `drive.sh:155-160`); an unknown transport still
   halts (`drive.sh:402`, extended to name `herdr`).
3. **Send + idle-guard order.** Against the `herdr` stub, one card issues, in order: an idle guard,
   then a text send of `$IMPL_SLASH_CMD repo=$WORKDIR branch=$BRANCH`, then ENTER — asserted from the
   stub's recorded argv, mirroring the orca send assertions.
4. **Completion signal unchanged.** `run_impl_herdr` returns success only when `remote_seq` on
   `origin/<BRANCH>` advances (the same git-poll loop as `run_impl_orca`, `drive.sh:501-509`), never on
   a terminal signal; a stubbed no-progress run dumps the pane tail and returns 1 within `CARD_TIMEOUT`.
5. **No regressions.** `bash -n drive.sh` clean; every existing `test/*.sh` passes; the new transport
   appears in the usage header (`drive.sh:38-39`) and README; `test/e2e-herdr.sh` is added to the
   README run-all line and to the `.pipeline/current.json` full-verify list.

## Scope

- `run_impl_herdr()` in `drive.sh` mirroring `run_impl_orca()` (`drive.sh:485`), plus
  `resolve_herdr_pane()` mirroring `resolve_orca_terminal()` (`drive.sh:311`).
- A `herdr)` branch in three `case "$IMPL_TRANSPORT"` sites: `run_impl` dispatch (`drive.sh:512`),
  transport preflight (`drive.sh:396`), and doctor (`drive.sh:155`).
- `HERDR_*` config vars mirroring the `ORCA_*` block (`drive.sh:79-86`): `HERDR_PANE_ID`,
  `HERDR_PANE_CWD_MATCH` (title/cwd disambiguator), `HERDR_IDLE_TIMEOUT_MS`, `HERDR_RESET_CMD`;
  `CARD_TIMEOUT` / `POLL_SECS` reused as-is.
- Command mapping (orca → herdr), all Herdr verbs **live-verified against herdr 0.7.3
  (socket protocol 16) on this machine, 2026-07-15** (`herdr pane --help` / `herdr wait --help`
  plus live read-only calls):

  | orca (existing) | herdr (new) |
  |---|---|
  | `orca terminal list --json` (filter by `$WORKDIR`) | `herdr pane list` (JSON is the only output — **no `--json` flag**; prints the socket envelope) → filter `.result.panes[]` by `.cwd == $WORKDIR` |
  | `orca terminal wait --terminal <h> --for tui-idle --timeout-ms N` | `herdr wait agent-status <id> --status done --timeout MS` (**flag is `--timeout`, not `--timeout-ms`**; opt. short-circuit on `blocked`) |
  | `orca terminal send --terminal <h> --text "…" --enter` | `herdr pane send-text <id> "…"` + `herdr pane send-keys <id> enter` (confirmed first-class CLI verbs — no socket needed) |
  | `orca terminal read --terminal <h>` (tail) | `herdr pane read <id> --source recent --lines 20` |
  | `ORCA_TERMINAL_HANDLE` (`term_…`) | `HERDR_PANE_ID` (`w1:p1`) |

  Discovery filters on `.cwd` (the pane's base cwd), NOT `.foreground_cwd` — live evidence: a
  claude pane showed `cwd=…/workspace/pipeline` while `foreground_cwd` pointed into a plugin
  cache dir its foreground child had chdir'd into.

- A frozen red test `test/e2e-herdr.sh` cloned from `test/e2e-orca.sh` with a `herdr` stub.
- README, usage-header, and `drive.config.example` additions.

## Non-scope

- No removal or edit of `run_impl_orca` / `run_impl_claude` — herdr is **additive**.
- No port of the review relay to Herdr (`review-drive.sh` keeps `orca terminal wait/send`); the driver
  halts at GATE 2 for the human merge regardless, so the relay is convenience — a separate feature.
- No Orca IDE / browser / worktree-management parity; shedding that weight is the point.
- No change to the two gates, spec-rev logic, git-poll completion, or any repo's `.pipeline/` run state.
- No tool/runtime/LLM name in `roles.yaml` (contract invariant); `herdr` is a `drive.sh` **transport**
  name, exactly like the existing `orca` / `claude`.

## Resolved decisions (provenance-tagged)

- **Additive third transport, not a replacement.** ✅ human-confirmed (this session — the approved
  `/think` plan; intent = "lightweight CLI replaces heavy IDE"). Enables A/B of Orca vs Herdr on one
  pipeline; rollback = unset `IMPL_TRANSPORT`.
- **Location = `pipeline-driver`, form = `.pipeline/herdr-transport/PRD.md`.** ✅ human-confirmed
  (this session).
- **Completion stays git-poll, transport-agnostic.** 📖 code-verified — `run_impl_orca`
  (`drive.sh:485-510`) types then polls `remote_seq` on `origin/<BRANCH>`; the terminal `wait` is only
  a pre-send idle guard, not the completion signal.
- **Command mapping to Herdr CLI.** 📖 live-verified 2026-07-15 against herdr 0.7.3 on this
  machine (see the Scope table): every needed method has a first-class CLI verb; discovery via
  `pane.list` `.cwd` field; socket at `~/.config/herdr/herdr.sock` (newline-delimited JSON,
  protocol 16 — `ping` round-trip confirmed via `nc -U`).
- **Transport surface = CLI verbs, not raw socket.** ✅ human-confirmed (2026-07-15 /think
  session). The CLI is a 1:1 wrapper over the socket — its output IS the socket response
  envelope — so nothing is lost by shelling it; raw socket would add an `nc -U`/`socat`
  dependency plus hand-rolled request-id/timeout/error handling in bash, and make the stubbed
  e2e harder (fake binary on PATH vs a background socket listener), for no capability the
  git-poll driver uses (no `events.subscribe`). The socket protocol stays the versioned
  compatibility contract (`herdr api schema`, protocol 16) — a doctor check target, not a
  transport surface.
- **Bonus over orca: catch `--status blocked` to halt fast** instead of burning `CARD_TIMEOUT` — Herdr
  distinguishes done/blocked natively (hook + screen-manifest). Optional; not required for parity.
- **Same rationale as the orca transport** — drive an interactive TUI to dodge the Zhipu
  headless-fingerprint block. 📖 code-verified — `drive.sh` header:38-40.
- **Build lane = meta-PR.** ✅ human-confirmed (2026-07-15 session, resolving the deferral):
  implement on a feature branch off `main` (~150-line mirror of `run_impl_orca` plus a cloned
  `test/e2e-herdr.sh`), reviewed + human-confirmed merge. NOT scheduled as the active pipeline
  feature — `.pipeline/current.json` stays on the parked `drive-setup` run. Rationale: a mirror
  of an already-reviewed pattern, with a live-verified verb surface and this frozen spec, gains
  little from full arch/task stages.

## Assumptions (were unconfirmed defaults — all resolved by live verification 2026-07-15)

- ✅ RESOLVED: `herdr pane send-text` / `herdr pane send-keys` exist as first-class CLI verbs
  (from `herdr pane --help`, herdr 0.7.3) — the socket-fallback `herdr_send()` helper is dropped
  from scope.
- ✅ RESOLVED: `foreground_cwd` drift is real (observed live — a foreground child had chdir'd
  into a plugin cache dir), but `pane.list` also carries the stable pane-level `.cwd`; discovery
  filters on `.cwd`, and a pinned `HERDR_PANE_ID` still wins over discovery (mirrors pinning
  `ORCA_TERMINAL_HANDLE`).

## Most fragile assumption (protect at arch)

The plan assumes **Herdr reliably reports `done`/`idle` for the specific coder TUI** (`pi`/`codex`/
`claude`) — a lifecycle hook or screen-manifest rule matches, so `herdr wait agent-status --status done`
fires instead of falling back to `default_known_agent_idle_fallback` (always-idle). If it does not, the
idle guard is a no-op and the driver could type a card into a busy TUI and **corrupt an in-flight
card**. Required degrade: when `wait agent-status` is unreliable for the chosen agent, the idle guard
falls back to a **settle delay + tail-quiescence** on `herdr pane read --source recent` (buffer
unchanged for N seconds = idle) — a deterministic guard independent of Herdr's agent-state model,
mirroring `parse-tail.awk`'s read-side tolerance.

Live evidence largely de-risking this (2026-07-15, herdr 0.7.3, this machine): detection is
hook-authoritative for the target TUIs — `herdr agent explain` on a live pi pane reports
`screen_detection_skip_reason: full_lifecycle_hook_authority`; four live panes simultaneously
showed pi=`done`/`idle`, claude=`working`, codex=`idle`; `herdr wait agent-status --status idle`
returned in ~0.1s with exit 0. The degrade path stays for agents without hook authority, and
`herdr wait output <id> --match <text> [--regex] [--timeout MS]` is a ready-made primitive for
the tail-quiescence guard.

## Provenance

- Design origin: `/think` session 2026-07-14 (Claude Code, Opus 4.8).
- Live verification backfill: `/think` session 2026-07-15 (Claude Code, Fable 5) — herdr 0.7.3,
  socket protocol 16; verb surface from `herdr pane|wait|agent --help`; socket `ping` +
  `pane.list` round-trips via `nc -U`; agent-state authority via `herdr agent explain`; lane +
  transport-surface decisions human-confirmed same session.
- Related KB notes: `86.116` (Herdr), `86.117` (Orca vs Herdr), `41.100`/`41.101` (pipeline two-track SOP).
- `drive.sh` anchors cited above verified against `origin/main` @ `f960793`.
