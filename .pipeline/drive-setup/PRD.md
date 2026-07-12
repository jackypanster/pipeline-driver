# PRD — `drive.sh setup`: the pipeline toolchain install/config wizard

Stage: prd · Feature: `drive-setup` · Repo: `jackypanster/pipeline-driver` · Branch: `main`

## Problem

Standing up the pipeline toolchain on a machine — or onboarding a new target git repo — is today a
manual, error-prone sequence spread across three repos and several config layers: canonical skills
copy + per-runtime symlink attach, `pipeline-dashboard` build + global bin + `pboard` shell function,
the driver's global `~/.config/pipeline-driver/drive.defaults`, and each target repo's
`.pipeline/roles.yaml`. A mistake in any layer surfaces late (a mid-run stop, a phantom slot name, an
impl runtime missing its skill). There is a good *verifier* already — `drive.sh doctor` — but no
guided *installer* that produces the state doctor checks.

## Goal

Add a `drive.sh setup` subcommand: one re-runnable, overwrite-safe, fzf-driven wizard that installs
every pipeline toolchain component and writes every config layer, then ends by running `doctor` as the
sole success signal. An operator can point it at any git repo and get a working, doctor-green pipeline
install without hand-editing files or remembering the canonical layout.

## Success criteria (the freezable spec surface)

Testable hermetically in the existing `test/*.sh` style (model: `test/defaults-doctor.sh` — pinned
paths, stripped PATH, temp `HOME`/XDG, no network), driving setup in **non-interactive mode**:

1. **Config generation.** `drive.sh setup` non-interactive into a temp `HOME` produces a
   `~/.config/pipeline-driver/drive.defaults` whose chosen fields match the inputs: `IMPL_TRANSPORT`,
   `IMPL_SLASH_CMD`, `REVIEW_TERMINAL_TITLE`, `REVIEW_SLASH_CMD` (single-quoted `$pipeline-review` for
   codex), `YOLO`, `BOARD_OUT`, and the sibling-repo/`SKILLS_DIR` paths.
2. **Idempotent re-run.** Running setup twice with the same inputs leaves `drive.defaults`
   byte-identical on the second run; `~/.zshrc` carries **exactly one** marker-delimited `pboard`
   block; runtime skill symlinks re-point without error or duplication.
3. **Overwrite safety.** An existing `drive.defaults` / target `roles.yaml` is backed up to `.bak`
   before being overwritten.
4. **roles.yaml correctness + tool-agnosticism.** A target repo's `.pipeline/roles.yaml` written by
   setup has the impl slot = `goal-driven-implementation` (no `<autonomous-coding-skill>` placeholder)
   and contains **no** tool/runtime/LLM name anywhere (contract invariant).
5. **doctor is the only success signal.** Setup invokes `drive.sh doctor` at the end; its exit
   reflects doctor's blocking count. Setup never prints "installed OK" independent of doctor, and any
   step it cannot automate prints exact remediation and leaves a doctor blocking (no faked success).
6. **No regressions.** `bash -n drive.sh` is clean; every existing `test/*.sh` still passes; the new
   subcommand appears in the usage header and README.

## Scope

- A `setup` subcommand inside `drive.sh`, dispatched exactly like the existing `doctor` subcommand.
- An interactive fzf wizard (degrading to `read -e -i` / `select` when fzf is absent) **and** a
  non-interactive env-driven mode (`SETUP_*` vars / `--yes`) that answers the same questions without a
  TTY — the seam the freeze test drives.
- Seven wizard steps (each individually skippable, whole wizard re-runnable/overwrite-safe):
  1. **Preflight** — self-locate `PIPELINE_REPO` / `DASHBOARD_REPO` / `DRIVER_REPO` (self) /
     `SKILLS_DIR` (canonical `~/.agents/skills`) with prefilled defaults; check system deps
     (`git node npm gh jq fzf orca`), offer `brew install` or print remediation for any missing.
  2. **Source repos** — clone if missing / `git fetch && reset --hard origin/main` if present (the
     overwrite refresh) for `pipeline` / `pipeline-dashboard` / `pipeline-driver`; **delegated skills**
     (`think check hunt grill-me grill-with-docs goal-driven-implementation`) are only *verified* and
     their source printed if missing — never auto-cloned.
  3. **Skills** — `cp -r <pipeline>/skills/pipeline-* $SKILLS_DIR`; fzf multi-select runtimes
     {`claude codex grok pi`} and `ln -sfn` per-skill symlinks into each selected runtime's skill dir
     (`grok` defaults to the impl slot only).
  4. **Dashboard** — `npm ci && npm run build` + `npm link`; write the `pboard()` function into
     `~/.zshrc` inside a marker-delimited block (`# >>> pipeline pboard >>>` … `# <<< pipeline pboard <<<`)
     so re-runs replace, never duplicate.
  5. **Driver global defaults** — generate `~/.config/pipeline-driver/drive.defaults` from the
     `.example` template with fzf-chosen values: impl transport (orca/pi TUI or headless claude+model),
     review terminal (codex) + `REVIEW_SLASH_CMD`, YOLO toggle, `BOARD_OUT`; back up an existing file
     to `.bak` first.
  6. **Optional per-target-repo init** (loopable across repos) — fzf-pick a repo, `cp` the pipeline
     repo's `roles.yaml` into `<repo>/.pipeline/roles.yaml` with the impl slot placeholder replaced by
     `goal-driven-implementation`.
  7. **Verify** — run `doctor`; print a summary of what was installed / changed / skipped.

## Non-scope

- No top-level `pipeline` dispatcher CLI (`pipeline setup/drive/dashboard/…`) — DESIGN.md's no-CLI rule.
- No standalone entry-point script — setup is reachable ONLY as `drive.sh setup`.
- No auto-clone of delegated-skill **external sources** (Waza / mattpocock / hermes) — verify + print
  remediation only.
- No edit to the `pipeline` repo, and no runtime/tool name written into any `roles.yaml`.
- No new service, daemon, or scheduler; setup is not a pipeline stage and touches no `.pipeline/`
  run state of the repos it configures beyond writing their `roles.yaml`.
- Step 6 does **not** scaffold a per-feature `drive.config` (left to run-time per the driver's
  per-run pin design).

## Resolved decisions (provenance-tagged)

- **Location = `pipeline-driver`, form = `drive.sh setup` subcommand.** ✅ human-confirmed — chosen over
  the `pipeline` repo (DESIGN.md:121-128 no-CLI rule rejects install CLIs there) and over a top-level
  dispatcher CLI.
- **Run this feature through the FULL feature pipeline** (seed `.pipeline/`, freeze a red test, pi
  impls, codex reviews) rather than the sibling-repo meta-PR lane. ✅ human-confirmed — a deliberate
  per-feature choice; deviates from but does not violate CONTRACT §Self-improvement's sibling-repo
  meta-PR convention (CONTRACT.md:315-321). The reviewer runs the normal feature review (freeze gate +
  full-suite + semantic), not semantic-only.
- **TUI = fzf, degrading to `read -e -i` / `select` when absent.** ✅ human-confirmed (fzf) ·
  📖 code-verified fzf is on PATH (`/opt/homebrew/bin/fzf`); gum/whiptail/dialog are not installed.
- **Non-interactive mode is built in** (`SETUP_*` env vars / `--yes`, bypassing fzf). ✅ human-confirmed
  — it is the seam the freeze test drives and the precondition for idempotency/CI.
- **Step 6 writes only global install + target `roles.yaml`; no per-feature `drive.config`.**
  ✅ human-confirmed.
- **Runtime split for THIS run: prd/arch/task = Claude Code, impl = pi, review = codex.**
  ✅ human-confirmed (pi + codex windows already launched).
- **`doctor` is the sole verification backend** — setup generates config; doctor is ground truth.
  📖 code-verified — `drive.sh doctor` (drive.sh:144-301) already checks deps / sibling repos / skills /
  config / target repo with exact per-line remediation; setup reuses it, does not reinvent checks.
- **drive.sh integration anchors** (mirroring the `doctor` subcommand). 📖 code-verified in `drive.sh`:
  subcommand `case` at line 48; config-required guards at lines 50 and 69 (must also skip for `setup`,
  since no `drive.config` exists yet — setup creates it); inline `setup()` next to `doctor()` near
  line 144 (matches the repo's inline-subcommand convention); dispatch before the main loop near
  line 304; usage header at lines 25-26.
- **Test harness = hermetic bash `test/*.sh`** with `ok()/bad()` counters, stubbed PATH, temp dirs, no
  network. 📖 code-verified — `test/defaults-doctor.sh` is the direct model; the new `test/setup.sh` is
  the frozen red test, added to the README run-all line (README.md:194).
- **Canonical single-copy skills layout** `~/.agents/skills/` + per-runtime symlinks. 📖 code-verified —
  machine state: claude/codex/pi carry 7 `pipeline-*` symlinks each into `~/.agents/skills`, grok
  carries 1 (impl slot only); pipeline README §Canonical layout.
- **`REVIEW_SLASH_CMD='$pipeline-review'` is single-quoted for codex** (≥0.144 invokes skills with a
  `$`-prefix; unquoted, bash expands `$pipeline` to empty). 📖 code-verified — drive.defaults.example:80.
- **`pboard` lives in `~/.zshrc`** and must be replaced in place, not appended. 📖 code-verified — an
  unmarked `pboard()` already exists at ~/.zshrc:196; setup wraps it in markers to make re-runs
  idempotent.
- **Dashboard build = `npm ci && npm run build` (→ `dist/cli.js`) + `npm link`.** 📖 code-verified —
  pipeline-dashboard/package.json (`build`: `tsc && chmod +x dist/cli.js`; bin `pipeline-dashboard`).

## Assumptions (unconfirmed defaults — challengeable at arch)

- ⚠️ **grok defaults to attaching only the impl slot** in step 3 (other runtimes get the full set). A
  chosen default from the operator's slot-assignment convention (grok = impl), overridable in the
  fzf multi-select — not an explicitly confirmed rule.
- ⚠️ **Backup policy = a single `.bak`** (overwritten each run) rather than timestamped `.bak.N`.
  Chosen for simplicity given the "overwrite freely" intent; arch may revisit.
- ⚠️ **`setup` runs against `~/.zshrc`** as the shell rc. The operator's shell is zsh
  (📖 environment), but a portable version could detect `$SHELL` / bash — deferred to arch.

## Most fragile assumption (protect at arch)

The plan assumes **install == cp + symlink + npm build + a few generated config files** — i.e. setup
is a thin orchestrator over commands that already work by hand and that `doctor` verifies. If a runtime
needs more than symlink registration, or a delegated-skill source cannot be reproducibly fetched, setup
must **degrade to a guided checklist**: print the exact remediation and leave a `doctor` blocking rather
than fake success. This degrade is a hard requirement, not a nicety — it is what keeps the wizard honest
when the assumption breaks.
