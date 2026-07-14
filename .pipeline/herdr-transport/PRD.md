# PRD — `IMPL_TRANSPORT=herdr`: drive the impl loop through a Herdr pane

Stage: prd · Feature: `herdr-transport` · Repo: `jackypanster/pipeline-driver` · Branch: `main`

> Filed as a queued TODO feature (prd stage only). Not scheduled; does not touch
> `.pipeline/current.json` (which points at the active `drive-setup` run).

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
- Command mapping (orca → herdr), all Herdr verbs code-verified against herdr.dev/docs this session:

  | orca (existing) | herdr (new) |
  |---|---|
  | `orca terminal list --json` (filter by `$WORKDIR`) | `herdr pane list --json` → filter `.foreground_cwd == $WORKDIR` |
  | `orca terminal wait --terminal <h> --for tui-idle --timeout-ms N` | `herdr wait agent-status <id> --status done --timeout-ms N` (opt. short-circuit on `blocked`) |
  | `orca terminal send --terminal <h> --text "…" --enter` | socket `pane.send_text` + `pane.send_keys enter` (CLI wrapper if present) |
  | `orca terminal read --terminal <h>` (tail) | `herdr pane read <id> --source recent --lines 20` |
  | `ORCA_TERMINAL_HANDLE` (`term_…`) | `HERDR_PANE_ID` (`w1:p1`) |

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
- **Command mapping to Herdr CLI/socket.** 📖 code-verified against herdr.dev/docs this session:
  `herdr pane read <id> --source recent --lines N`; `herdr wait agent-status <id> --status done|blocked`;
  send via socket `pane.send_text` + `pane.send_keys enter`; pane discovery via `pane.list`
  `foreground_cwd` field; socket at `~/.config/herdr/herdr.sock` (newline-delimited JSON).
- **Bonus over orca: catch `--status blocked` to halt fast** instead of burning `CARD_TIMEOUT` — Herdr
  distinguishes done/blocked natively (hook + screen-manifest). Optional; not required for parity.
- **Same rationale as the orca transport** — drive an interactive TUI to dodge the Zhipu
  headless-fingerprint block. 📖 code-verified — `drive.sh` header:38-40.
- **Build lane (full feature pipeline vs sibling-repo meta-PR) deferred** to when the feature is
  scheduled — not fixed at prd (mirrors the `drive-setup` PRD's explicit-choice pattern).

## Assumptions (unconfirmed defaults — challengeable at arch)

- ⚠️ Herdr exposes a stable send verb. If only the socket exists (no `herdr pane send-text` CLI),
  `run_impl_herdr` writes newline-delimited JSON to `~/.config/herdr/herdr.sock` via a small
  `herdr_send()` helper rather than shelling a CLI. Confirm the exact verb via `herdr pane --help` at
  arch/impl (a lift-the-live-value step, not a spike).
- ⚠️ Pane resolution by `foreground_cwd` may be unreliable when the agent forks child processes;
  default to a pinned `HERDR_PANE_ID` (as the KB note advises pinning `ORCA_TERMINAL_HANDLE`), with
  cwd-match as the disambiguator.

## Most fragile assumption (protect at arch)

The plan assumes **Herdr reliably reports `done`/`idle` for the specific coder TUI** (`pi`/`codex`/
`claude`) — a lifecycle hook or screen-manifest rule matches, so `herdr wait agent-status --status done`
fires instead of falling back to `default_known_agent_idle_fallback` (always-idle). If it does not, the
idle guard is a no-op and the driver could type a card into a busy TUI and **corrupt an in-flight
card**. Required degrade: when `wait agent-status` is unreliable for the chosen agent, the idle guard
falls back to a **settle delay + tail-quiescence** on `herdr pane read --source recent` (buffer
unchanged for N seconds = idle) — a deterministic guard independent of Herdr's agent-state model,
mirroring `parse-tail.awk`'s read-side tolerance.

## Provenance

- Design origin: `/think` session 2026-07-14 (Claude Code, Opus 4.8).
- Related KB notes: `86.116` (Herdr), `86.117` (Orca vs Herdr), `41.100`/`41.101` (pipeline two-track SOP).
- `drive.sh` anchors cited above verified against `origin/main` @ `f960793`.
