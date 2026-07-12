# arch — `drive.sh setup`

Stage: arch · Feature: `drive-setup` · Reads: [PRD.md](PRD.md) · ADRs: [docs/adr](docs/adr)

## Chosen shape

`setup` is a **third `drive.sh` subcommand**, structured as a peer of `doctor()` — same file, same
inline-function convention, same "sectioned output + a counter + terminal exit status" shape. It
generates config/attaches components by orchestrating commands that already work by hand, and it ends
by delegating to `doctor()` as the sole success signal (ADR 0002).

The load-bearing design move: **one code path serves interactive and non-interactive**, so the frozen
red test drives the *real* flow (ADR 0003). Interactivity is isolated to four `ask_*` helpers; every
answer also has an env override (`SETUP_*`) and a default, so `SETUP_YES=1` (or `--yes`) makes the
whole wizard run headless with zero fzf/read calls.

## drive.sh integration (code-verified anchors)

| where | current (code-verified) | change |
|---|---|---|
| `drive.sh:48` | `case "${1:-}" in doctor) SUBCMD=doctor; shift ;; esac` | add `setup) SUBCMD=setup; shift ;;` |
| `drive.sh:50-52` | config-not-found guard skips only for `doctor` | also skip for `setup` (use `case "$SUBCMD" in doctor\|setup) ;; *) …guard… ;; esac`) |
| `drive.sh:62-64` | `DEFAULTS=${DRIVE_DEFAULTS:-…/drive.defaults}`; sourced if present | **reuse verbatim** — setup WRITES to `$DEFAULTS` and READS the already-sourced values as prefill; `DRIVE_DEFAULTS` is the hermetic test seam |
| `drive.sh:69-73` | required-key guard (`WORKDIR/BRANCH/FEATURE`) skips for `doctor` | also skip for `setup` (same `case` as above) |
| `drive.sh:144-303` | `doctor()` inline, `d_ok/d_miss/d_warn/d_info` locals, section headers, `printf 'doctor: %d blocking…'`, `[ "$bad" -eq 0 ]` exit | add `setup()` **immediately above** `doctor()`, mirroring its shape |
| `drive.sh:304` | `if [ "$SUBCMD" = "doctor" ]; then doctor; exit $?; fi` | add `if [ "$SUBCMD" = "setup" ]; then setup; exit $?; fi` beside it |
| `drive.sh:25-29` | usage header lists `[config]` and `doctor` | add a `setup` usage line |

No other drive.sh logic is touched; the impl-loop path (lines 305+) is unchanged.

## The non-interactive interface (the freeze contract — task binds the red test to THIS)

**Activation:** `SETUP_YES=1` env **or** `--yes`/`-y` on the command line ⇒ non-interactive: no fzf,
no `read`; every answer resolves to its `SETUP_*` override if set, else its default.

**Unified answer helpers (ONE path, interactive + headless):**

- `ask_value  KEY PROMPT DEFAULT`            → `${SETUP_<KEY>:-}` if set · else DEFAULT (headless) · else `read -e -i DEFAULT` / fzf (TTY)
- `ask_confirm KEY PROMPT DEFAULT{0|1}`      → same resolution, boolean
- `ask_choice KEY PROMPT DEFAULT OPT…`       → fzf single-select on a TTY; env/DEFAULT otherwise
- `ask_multi  KEY PROMPT DEFAULT_CSV OPT…`   → fzf `--multi` on a TTY; env/DEFAULT_CSV otherwise

fzf is probed once (`command -v fzf`); absent ⇒ `ask_choice/ask_multi` fall back to `select`, `ask_value`
to `read -e -i`. Headless mode never calls any of them.

**Answer keys → `SETUP_*` env var → default:**

| KEY (`SETUP_<KEY>`) | controls | default |
|---|---|---|
| `PIPELINE_REPO` | pipeline skills source | `$HOME/workspace/pipeline` |
| `DASHBOARD_REPO` | dashboard source | `$HOME/workspace/pipeline-dashboard` |
| `SKILLS_DIR` | canonical skills dir | `$HOME/.agents/skills` |
| `TUI_SKILLS_DIR` | orca/pi runtime skill dir | `$HOME/.pi/agent/skills` |
| `SHELL_RC` | rc file for the `pboard` block | `$HOME/.zshrc` (ADR: zsh-first) |
| `DO_DEPS` `DO_SOURCES` `DO_SKILLS` `DO_DASHBOARD` `DO_DEFAULTS` `DO_TARGET` `DO_DOCTOR` | per-step on/off | `1` (each step individually skippable) |
| `REFRESH_SOURCES` | `git fetch && reset --hard origin/main` on the 3 source repos | `0` (never destroy local state unptompted — ADR) |
| `RUNTIMES` | CSV of runtimes to attach {`claude,codex,grok,pi`} | auto: the subset whose skill dir already exists |
| `GROK_IMPL_ONLY` | grok gets only the impl slot | `1` (ADR: operator convention + observed state) |
| `DASHBOARD_LINK` | run `npm link` after build | `1` |
| `IMPL_TRANSPORT` | drive.defaults | `orca` |
| `IMPL_SLASH_CMD` | drive.defaults | `/skill:pipeline-impl` |
| `IMPL_MODEL` | drive.defaults (claude transport) | `haiku` |
| `REVIEW_TERMINAL_TITLE` | drive.defaults | `codex` |
| `REVIEW_SLASH_CMD` | drive.defaults | `$pipeline-review` (emitted single-quoted — code-verified drive.defaults.example:80) |
| `YOLO` | drive.defaults | `0` |
| `BOARD_OUT` | drive.defaults | `` (empty = off) |
| `TARGET_REPO` | step-6 target repo path | `` (empty = skip step 6) |

Interactive prefill for the drive.defaults values comes from the **already-sourced** current values
(drive.sh:62-64 sources `$DEFAULTS` before dispatch) — so re-running setup shows your last choices.

## Component boundaries — 7 steps as individually-testable units

Each step is a function guarded by its `DO_<STEP>` toggle. **File-generating steps are pure and frozen;
external-tool steps are stubbed or skipped in the test and covered by "review reads" (Freeze coverage).**

| step | fn | kind | frozen? |
|---|---|---|---|
| 1 preflight | `setup_preflight` | dep probe (reuses doctor's dep style) → prints remediation for missing | review-reads |
| 2 sources | `setup_sources` | `git clone` / opt-in `fetch+reset` | review-reads (network) |
| 3 skills | `setup_skills` | `cp -r pipeline-* $SKILLS_DIR` + `ln -sfn` per runtime | review-reads (symlink attach), but the **grok-impl-only path selection** is a pure decision → frozen |
| 4a dashboard build | `setup_dashboard_build` | `npm ci && npm run build && npm link` | review-reads (npm) |
| 4b pboard block | `setup_pboard_block` | **pure file op** — marker-delimited block into `$SHELL_RC` | **FROZEN** |
| 5 defaults | `setup_defaults` | **pure file gen** — write `$DEFAULTS` from template | **FROZEN** (the core) |
| 6 target | `setup_target` | **pure file gen** — `$TARGET_REPO/.pipeline/roles.yaml` | **FROZEN** |
| 7 verify | `setup_doctor` | calls `doctor`; setup exit = its status | **FROZEN** (exit semantics) |

`setup()` runs the enabled steps in order, tracks a `setup_bad` counter for un-automatable steps
(honest-degrade), then: if `DO_DOCTOR` runs `doctor` and returns `doctor_rc | (setup_bad>0)`, else
returns `setup_bad>0 ? 1 : 0`.

## Idempotency & overwrite invariants (testable — ADR 0003)

- **drive.defaults / roles.yaml**: render the new content to a temp string; if identical to the
  existing file ⇒ **no write, no `.bak`** (idempotent no-op); if different ⇒ copy existing to `<file>.bak`
  (single, overwritten), then write. Test: two identical runs ⇒ second creates no `.bak`, file
  byte-identical.
- **pboard block**: delimited by `# >>> pipeline pboard >>>` … `# <<< pipeline pboard <<<`. Write =
  delete any existing delimited block (sed range), append the fresh block. Test: run twice ⇒ exactly one
  block; an unmarked legacy `pboard()` (code-verified present at `~/.zshrc:196`) is left in place with a
  one-line note (setup owns only its marked block — it never edits lines it did not write).
- **symlinks**: `ln -sfn` (force, no-deref) ⇒ re-point without error/dup.
- **roles.yaml**: copy the pipeline repo's `roles.yaml`, replace the impl-slot value
  `<autonomous-coding-skill>` → `goal-driven-implementation`; assert output contains no
  tool/runtime/LLM token (contract invariant — grep-negative in the test).

## Generated-config compatibility (reference-behavior check — all internal, code-verified)

The only "reference" setup depends on is drive.sh's OWN expected `drive.defaults` variable names. No
external/unexerciseable surface ⇒ no `⚠️ unverified` risk rows. Each generated field is consumed by a
code-verified drive.sh site:

| generated field | consumed by | tier |
|---|---|---|
| `IMPL_TRANSPORT` `IMPL_SLASH_CMD` `IMPL_MODEL` | drive.sh:74-83 + doctor:154 | ✅ code-verified |
| `REVIEW_TERMINAL_TITLE` `REVIEW_SLASH_CMD` | drive.sh:107-109 + doctor review-relay checks | ✅ code-verified |
| `YOLO` `BOARD_OUT` | drive.sh:91,102 + doctor | ✅ code-verified |
| `PIPELINE_REPO` `DASHBOARD_REPO` `SKILLS_DIR` `TUI_SKILLS_DIR` | drive.sh:93-98 + doctor | ✅ code-verified |

## Resolved ⚠️ assumptions (from PRD; settled here, not by editing PRD)

1. **grok = impl-only default.** 📖 code-verified machine state (grok skill dir holds only the impl
   pipeline skill). Resolve: `SETUP_GROK_IMPL_ONLY=1` default; grok attaches `pipeline-impl` +
   `goal-driven-implementation` only. Overridable. (ADR 0003 §skills.)
2. **Backup policy.** Resolve: single `<file>.bak`, written **only on a content change**. Rejected
   timestamped `.bak.N` (cruft on a re-runnable installer). Idempotent re-run ⇒ zero backups.
3. **rc file.** Resolve: `${SETUP_SHELL_RC:-$HOME/.zshrc}`; default zsh (📖 environment: user shell is
   zsh; `pboard()` already at `~/.zshrc:196`). No `$SHELL` auto-detect (a zsh-first toolchain must not
   silently write a bash rc). The override doubles as the pboard-block test's hermetic seam.

All three settled by code-verification + grounded defaults, per grill-with-docs "ask the human only on
genuine ambiguity code cannot resolve" — no human grill was required.

## Decomposition guidance for pipeline-task (not cards — task authors them)

A natural, each-independently-landable split (task decides final granularity):

- **C1 plumbing**: subcommand dispatch + config-guard bypass + usage + a `setup()` that runs only the
  enabled steps and terminates on `doctor`. Red test: `SETUP_YES=1 SETUP_DO_*=0 SETUP_DO_DOCTOR=1
  drive.sh setup` runs doctor and exits with its rc; `bash -n drive.sh` clean.
- **C2 defaults gen** (step 5 + the `ask_*`/non-interactive seam it needs): `$DEFAULTS` content from
  `SETUP_*`; idempotent; `.bak` on change only.
- **C3 pboard block** (step 4b): marker-delimited block into `$SETUP_SHELL_RC`; one block after two runs.
- **C4 target roles.yaml** (step 6): impl slot rewritten; no tool names; `.bak` on change.
- External-tool steps (1,2,3,4a) ride C1's plumbing with **review-reads** freeze coverage — a card may
  assert command *construction* (dry-run echo) but not execute npm/git/orca.

`## Freeze coverage` each card must record: **frozen** = the pure file-gen + exit semantics above;
**review must read** = the fzf interactive flow, and the npm/git/orca/symlink/brew side-effecting calls
(a hermetic test cannot exercise a real TUI or package manager). Impl-paths = `drive.sh` (+ `README.md`);
spec-paths = `test/setup.sh`; disjoint. `current.json.full-verify` = `["bash -n drive.sh",
"bash test/run.sh && bash test/hook.sh && bash test/preflight.sh && bash test/e2e.sh && bash
test/e2e-orca.sh && bash test/defaults-doctor.sh && bash test/board-relay.sh && bash test/review-drive.sh
&& bash test/setup.sh"]` (the README:194 run-all line + the new `test/setup.sh`).
