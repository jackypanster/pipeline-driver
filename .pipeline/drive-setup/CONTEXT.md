# CONTEXT — `drive-setup` glossary & conventions

Domain language for the setup wizard. Grounds the terms arch/task/impl/review must share.

## Terms

- **setup subcommand** — `drive.sh setup`; a peer of `drive.sh doctor`, NOT a pipeline stage and NOT a
  standalone script. Reachable only as a `drive.sh` argument.
- **canonical layout** — the ONE physical skills dir `SKILLS_DIR` (`~/.agents/skills`); every runtime
  attaches to it by symlink. Sources (pipeline repo, skill collections) are update origins, never load
  paths. (pipeline README §Canonical layout.)
- **slot vs runtime** — a *slot* (prd/arch/task/impl/review/…) binds to a skill NAME in `roles.yaml`
  (tool-agnostic, contract invariant). A *runtime* (claude/codex/grok/pi) is the agent that executes a
  stage; the runtime↔stage assignment lives ONLY in `drive.defaults` and the operator's head — NEVER in
  `roles.yaml`.
- **transport** — how impl runs: `orca` (type `IMPL_SLASH_CMD` into a live pi/GLM TUI, poll the journal)
  or `claude` (headless `claude` child per card). Setup writes the choice into `drive.defaults`.
- **YOLO grant** — `YOLO=1` in `drive.defaults` = the operator's STANDING ex-ante grant that the
  coordinating agent may echo the frozen spec-rev at GATE 1 for LOW-RISK drive features. It does NOT
  auto-start drive and NEVER touches the merge confirm. Distinct from an agent app's permission-mode
  "YOLO" (e.g. codex/pi's own setting) — setup toggles the DRIVER grant only.
- **name-shim** — a wrapper skill whose frontmatter `name:` is the canonical slot name, body =
  "invoke the twin". Needed because runtimes register skills by frontmatter `name:`, not dir name
  (code-verified: defaults-doctor.sh test 12). The impl slot's canonical name is
  `goal-driven-implementation` everywhere.
- **marker-delimited block** — a region of a config file setup owns, fenced by
  `# >>> pipeline pboard >>>` … `# <<< pipeline pboard <<<`. Setup replaces only what is inside its
  markers; it never edits unmarked lines it did not author.
- **honest-degrade** — the rule (ADR 0002) that a step setup cannot automate prints exact remediation
  and leaves a `doctor` blocking, so setup never reports a false success. `doctor` is ground truth.
- **`ask_*` seam** — the four helpers (`ask_value/ask_confirm/ask_choice/ask_multi`) that isolate ALL
  interactivity. Each resolves `SETUP_<KEY>` env → default (headless) → fzf/read (TTY), so one code
  path serves both modes and the frozen test drives the real flow.
- **non-interactive / headless mode** — `SETUP_YES=1` or `--yes`: no fzf, no read; every answer from
  `SETUP_*`/defaults. The hermetic-test entry point; also the CI/idempotency path.
- **`$DEFAULTS` / `DRIVE_DEFAULTS`** — the resolved path setup writes drive.defaults to (drive.sh:62);
  `DRIVE_DEFAULTS` overrides it, which is how tests stay hermetic (code-verified: defaults-doctor.sh).

## Conventions carried from the repo (code-verified)

- Tests are hermetic bash (`test/*.sh`): `mktemp -d`, stubbed PATH under `$TMP/bin`, `DRIVE_DEFAULTS`
  pin, `ok()/bad()` counters, no network. New freeze test = `test/setup.sh`, same mold as
  `test/defaults-doctor.sh`; add it to the README:194 run-all line and `current.json.full-verify`.
- Subcommands are inline functions in `drive.sh` with `d_ok/d_miss/d_warn/d_info`-style local helpers,
  section-header `printf`, and a terminal exit status. `setup()` follows this.
- `drive.config` is git-ignored (`.gitignore`); `drive.defaults` lives outside the repo under
  `${XDG_CONFIG_HOME:-~/.config}/pipeline-driver/`.
