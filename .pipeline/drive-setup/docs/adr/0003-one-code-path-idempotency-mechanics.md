# ADR 0003 — One code path for interactive+headless; concrete idempotency mechanics

Status: accepted · Date: 2026-07-12 · Feature: drive-setup

## Context

Two hard requirements collide: the wizard must be **fzf-graphical and friendly** for a human, and it
must be **hermetically testable + idempotent** for the freeze gate and re-runs. A test cannot drive a
real TUI. If interactive and non-interactive were separate code paths, the frozen test would exercise a
*fork*, not the real flow — the exact bug the spec-rev protocol exists to prevent.

## Decision

**Interactivity is isolated to four helpers** — `ask_value / ask_confirm / ask_choice / ask_multi` —
each resolving `SETUP_<KEY>` env → default (headless) → fzf/`read` (TTY). Every step function calls only
these; `SETUP_YES=1`/`--yes` flips them all to headless. The step *logic* is identical in both modes, so
the freeze test drives the real path.

**Idempotency / overwrite mechanics (each a testable invariant):**

- **Generated config files** (`drive.defaults`, target `roles.yaml`): render new content to a string;
  identical to the existing file ⇒ **no write, no backup**; different ⇒ `cp` existing to `<file>.bak`
  (single, overwritten each change), then write. → two identical runs: second makes no `.bak`, file
  byte-identical.
- **`pboard` block**: fenced by `# >>> pipeline pboard >>>` … `# <<< pipeline pboard <<<` in
  `${SETUP_SHELL_RC:-$HOME/.zshrc}`. Write = drop any existing fenced block (sed range delete) then
  append the fresh one. → two runs: exactly one block. An unmarked legacy `pboard()` is left untouched
  with a note (setup edits only its own markers).
- **Symlink attach**: `ln -sfn` (force + no-dereference) ⇒ re-point without error or duplication.
- **roles.yaml**: copy the pipeline repo's `roles.yaml`, rewrite impl slot `<autonomous-coding-skill>`
  → `goal-driven-implementation`; assert the result carries no tool/runtime/LLM token (contract).

**Sub-decisions (resolving PRD ⚠️ assumptions):**

- **grok = impl-only** by default (`SETUP_GROK_IMPL_ONLY=1`): grok attaches only `pipeline-impl` +
  `goal-driven-implementation`. Grounded in observed machine state (grok's skill dir holds only the
  impl skill) + operator convention. Overridable.
- **Backups**: single `.bak`, on-change-only (above). Rejected timestamped `.bak.N` — cruft on a
  re-runnable installer.
- **rc file**: `${SETUP_SHELL_RC:-$HOME/.zshrc}`, zsh default (user shell is zsh; `pboard()` already at
  `~/.zshrc:196`). No `$SHELL` auto-detect — a zsh-first toolchain must not silently write a bash rc.
  The override doubles as the pboard-block test's hermetic seam.
- **`SETUP_REFRESH_SOURCES=0`** default: setup never `git reset --hard` a source repo unprompted; the
  "overwrite" mandate is about generated CONFIG, not destroying local source checkouts.

## Consequences

- The frozen `test/setup.sh` pins `DRIVE_DEFAULTS`, `HOME`, `SETUP_SHELL_RC` and asserts the four pure
  file-gen behaviors + exit semantics, with no network and no real fzf/npm/git/orca.
- Interactive polish (fzf widgets) is coder-owned (impl-paths), covered by "review reads", never frozen.

## Alternatives rejected

- **Separate `--test`/interactive code paths** — the freeze test would validate a path users never run.
  Rejected in favor of the single `ask_*` seam.
