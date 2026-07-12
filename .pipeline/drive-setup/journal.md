# Run journal — feature `drive-setup`

## seq=1 · 2026-07-12T14:13:18Z · prd→arch · completed · by=claude-opus-4-8 (cc)
done:   Seeded `.pipeline/` on pipeline-driver (first feature-pipeline run on this sibling repo, an
        operator-confirmed per-feature choice) and wrote the PRD for `drive.sh setup` — an fzf-driven,
        idempotent, overwrite-safe install/config wizard reachable only as a `drive.sh` subcommand,
        with a non-interactive env-driven seam so the freeze gate can test it. Every decision is
        provenance-tagged; `doctor` is the sole success signal.
output: .pipeline/drive-setup/PRD.md · .pipeline/current.json · .pipeline/roles.yaml
--- handoff ---
>>> NEXT
Run pipeline-arch on a FRESH session (assume you know nothing — rebuild from the repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=none
Model: frontier SOTA required — operator assigns the bot; the pipeline can't verify the model.
First: git pull --rebase; load repo config (no .env in this repo — skip per CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — the normative protocol (read FIRST)
  - .pipeline/drive-setup/PRD.md   — what: the setup wizard, success criteria, scope, tagged decisions
  - drive.sh                       — the file being extended; study how the `doctor` subcommand is
                                     dispatched (case @48, guards @50/@69, doctor() @144-301, dispatch @304)
                                     and structured — `setup` mirrors it
  - drive.defaults.example         — the exact field set + comments the wizard's step 5 must emit
  - drive.config.example / review-drive.config.example — the layering model (global defaults < per-feature)
  - test/defaults-doctor.sh        — the hermetic-test model the frozen red test will follow
  - ../pipeline/README.md §Install + §Canonical layout — the install shape setup automates
Your task (concrete, numbered):
  1. Walk the design tree of `drive.sh setup` against the existing drive.sh with grill-with-docs. Pin
     the component boundaries: (a) subcommand dispatch + config-guard bypass; (b) the interactive fzf
     layer vs the non-interactive env-driven seam (SETUP_* / --yes) — they must answer the SAME
     question set through one code path so the freeze test exercises the real flow, not a fork;
     (c) the 7 install steps as individually-skippable units; (d) `doctor` as the terminal verifier.
  2. Decide the non-interactive interface precisely: which SETUP_* env vars / flags map to which
     wizard answer, and how "skip this step" is expressed non-interactively. This is the contract the
     frozen red test binds to — name it exactly in arch.md so task can freeze it.
  3. Resolve the ⚠️ assumptions the PRD left for arch: grok=impl-only default; single `.bak` vs
     timestamped backups; `~/.zshrc` hard-coded vs `$SHELL`-detected rc file.
  4. Specify the idempotency + overwrite mechanics concretely: marker-delimited `pboard` block
     (`# >>> pipeline pboard >>>` … `# <<< pipeline pboard <<<`), `ln -sfn`, `cp` overwrite, `.bak`
     backup-before-write — each stated as a testable invariant.
  5. Emit arch.md + CONTEXT.md (glossary: canonical layout, slot vs runtime, transport, YOLO grant) +
     ADRs for: (i) full-feature-pipeline vs meta-PR on a sibling repo; (ii) the honest-degrade rule
     (un-automatable step ⇒ print remediation + leave a doctor blocking, never fake success).
Feature gotchas (project-specific traps the next node MUST know):
  - `roles.yaml` must NEVER carry a tool/runtime/LLM name (CONTRACT invariant) — the runtime split
    (claude/pi/codex) lives ONLY in drive.defaults, never in the roles.yaml setup writes.
  - `setup` runs BEFORE any drive.config exists — the config-required guards at drive.sh:50 and :69
    must skip for SUBCMD=setup exactly as they already do for doctor, or setup dies on a missing config.
  - `REVIEW_SLASH_CMD='$pipeline-review'` MUST stay single-quoted in generated config (codex ≥0.144
    $-prefix; unquoted bash expands it to empty).
  - The impl slot's real installed name is `goal-driven-implementation`; never emit the
    `<autonomous-coding-skill>` placeholder or a phantom per-runtime twin name.
  - `doctor` is ground truth: the wizard must not declare success on its own; any step it can't
    automate prints exact remediation and leaves a doctor blocking (honest-degrade).
  - This is the FIRST `.pipeline/` state on pipeline-driver; metadata commits straight to trunk (main)
    per CONTRACT — the reviewable code diff (drive.sh, README, test/setup.sh) goes on feat/drive-setup.
Done when: arch.md + CONTEXT.md + ADRs land, the non-interactive interface is named exactly, and all
three ⚠️ assumptions are resolved. On success: set current.json.stage=arch, append a journal entry,
then run pipeline-task.
On failure: attempts++; >=3 ⇒ blocked ⇒ run pipeline-hunt.
<<< END

## seq=2 · 2026-07-12T14:21:04Z · arch→task · completed · by=claude-opus-4-8 (cc)
done:   Walked drive.sh setup against the real drive.sh. Pinned it as a THIRD subcommand mirroring
        doctor(); named the exact non-interactive interface (SETUP_* env + 4 ask_* helpers, ONE code
        path) the freeze test binds to; found the hermetic seam (setup writes $DEFAULTS, DRIVE_DEFAULTS
        overrides it — same as defaults-doctor.sh). Resolved all 3 ⚠️ assumptions by code + grounded
        defaults (no human grill). 3 ADRs: full-pipeline-on-sibling, honest-degrade, one-path+idempotency.
output: .pipeline/drive-setup/arch.md · CONTEXT.md · docs/adr/{0001,0002,0003}.md
--- handoff ---
>>> NEXT
Run pipeline-task on a FRESH session (assume you know nothing — rebuild from the repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=none
Model: frontier SOTA required — operator assigns the bot; the pipeline can't verify the model.
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    esp. §Test ownership: ONE freeze commit for the whole feature = shared spec-rev; card-scoped verify)
  - .pipeline/drive-setup/arch.md      — the shape, the SETUP_* interface table, the 7 steps as
    testable units, drive.sh integration anchors, the decomposition guidance (C1-C4)
  - .pipeline/drive-setup/CONTEXT.md   — glossary (ask_* seam, honest-degrade, $DEFAULTS/DRIVE_DEFAULTS)
  - .pipeline/drive-setup/docs/adr/*   — 0002 (doctor = sole success signal) + 0003 (idempotency
    mechanics) are the invariants the red tests must pin
  - drive.sh (doctor() @144-303, dispatch @304)  — the structure setup() mirrors; impl-paths target
  - test/defaults-doctor.sh            — COPY THIS MOLD for the frozen tests (mktemp, stubbed PATH,
    DRIVE_DEFAULTS pin, ok()/bad() counters, no network)
Your task (concrete, numbered):
  1. Decompose arch into atomic, each-independently-landable cards. Suggested split (arch §Decomposition):
     C1 plumbing (subcommand dispatch + config-guard bypass + usage + setup() that runs enabled steps
     and terminates on doctor); C2 defaults gen (step 5) + the ask_*/headless seam; C3 pboard marker
     block (step 4b); C4 target roles.yaml (step 6). External-tool steps (1,2,3,4a) ride C1 with
     review-reads coverage. Merge/split as you see fit — keep each card's test card-scoped.
  2. Freeze ALL cards' red tests in ONE commit (the feature's single spec-rev), touching ONLY
     spec-paths. For card-scoped verify use DEDICATED per-card test files (test/setup-plumbing.sh,
     test/setup-defaults.sh, test/setup-pboard.sh, test/setup-target.sh) — CONTRACT:98 "dedicated test
     file" option — so each card's verify runs only its slice while siblings stay red. Tests MUST
     compile and FAIL here (setup subcommand doesn't exist yet). Bind them to the SETUP_* interface and
     the DRIVE_DEFAULTS/HOME/SETUP_SHELL_RC hermetic pins exactly as arch specifies.
  3. Record commit (metadata only, never spec-paths): each card's frontmatter — status: todo,
     attempts: 0, the card-scoped verify cmd (e.g. `bash test/setup-defaults.sh`), spec-paths (its test
     file), impl-paths (drive.sh + README.md for the docs card), the SHARED spec-rev from step 2, and a
     `## Freeze coverage` section (frozen = pure file-gen + exit semantics; review-must-read = fzf
     interactive flow + npm/git/orca/symlink/brew calls).
  4. Set current.json.full-verify = ["bash -n drive.sh", "<README:194 run-all line> && bash the new
     per-card test files"]. Set current.json.stage=task. Append a journal entry, commit once, push.
Feature gotchas (project-specific traps the next node MUST know):
  - ONE freeze commit for the whole feature (shared spec-rev). NOT per-card — several cards may share
    test scaffolding; a per-card spec-rev would false-reject a sibling at the freeze gate.
  - spec-paths (test/setup-*.sh) ∩ impl-paths (drive.sh, README.md) = ∅. impl (pi) writes ZERO tests —
    it makes the frozen tests green by writing setup() in drive.sh only.
  - Card-scoped verify, never full-suite: trunk's suite goes RED from this freeze until the impl merge
    (accepted: no CI gate on trunk + one feature in flight).
  - The tests must pin DRIVE_DEFAULTS + HOME + SETUP_SHELL_RC to a temp dir and stub PATH — no network,
    no real fzf/npm/git/orca. Assert generated CONTENT + idempotency (run twice) + `.bak`-on-change-only
    + roles.yaml carries NO tool/runtime name + setup exit == doctor rc.
  - Impl runs on pi (orca transport). The impl-slot skill is goal-driven-implementation.
Done when: all cards written with the shared spec-rev, the freeze commit's tests compile + FAIL,
full-verify recorded. On success: set current.json.stage=task, append journal, then GATE 1 (read the
frozen red test, echo its spec-rev) and dispatch pipeline-impl to pi.
On failure: attempts++; >=3 ⇒ blocked ⇒ run pipeline-hunt.
<<< END

## seq=3 · 2026-07-12T14:29:56Z · task→impl · completed · by=claude-opus-4-8 (cc)
done:   Decomposed drive-setup into 4 atomic cards (C1 plumbing / C2 defaults-gen+seam / C3 pboard
        block / C4 target roles.yaml). Froze all 4 red tests in ONE commit (shared spec-rev
        4ac12ec) as dedicated per-card files test/setup-*.sh — verified bash -n clean AND genuinely
        RED now (setup subcommand absent). Recorded cards + full-verify. impl (pi) makes them green by
        writing setup() in drive.sh only.
output: .pipeline/drive-setup/tasks/{01,02,03,04}.md · current.json (stage=task, full-verify) · freeze commit 4ac12ec
--- handoff ---
>>> NEXT
Run pipeline-impl on a FRESH session (assume you know nothing — rebuild from the repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=none
Model: capable-local OK (impl only) — operator assigns the bot (pi, orca transport); the pipeline can't verify the model.
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    esp. §Test ownership: you make the frozen test green via impl-paths + src ONLY, NEVER edit spec-paths)
  - .pipeline/drive-setup/tasks/01.md … 04.md — the 4 cards; pick the OLDEST `todo` first
  - .pipeline/drive-setup/arch.md — the SETUP_* interface table + drive.sh integration anchors (the map)
  - .pipeline/drive-setup/CONTEXT.md + docs/adr/0002,0003 — honest-degrade + idempotency invariants
  - drive.sh (doctor() @144-303, dispatch @304) — the structure setup() mirrors; YOUR impl target
GATE 1 (frozen spec): the feature's single spec-rev is 4ac12ec905adab2da59666447e8a264245fc3cd3
  (the freeze commit adding test/setup-*.sh). Read those tests — they ARE the spec you implement to.
Your task (concrete, numbered):
  1. Cut `feat/drive-setup` from `main` (all 4 cards land on this ONE branch; impl-paths = drive.sh,
     + README.md for card 01).
  2. Pick the oldest `todo` card. Make its `verify` green by writing setup() in drive.sh (+ README for
     C1) — editing ONLY impl-paths. Do NOT touch any test/setup-*.sh (freeze gate — a spec edit is a
     review reject). Run the card's `verify`; when green, flip the card `status: todo→review` (or per
     the driver loop), commit on the branch.
  3. Repeat for cards 02, 03, 04 in order on the same branch — each new card's setup() code builds on
     the prior. When all 4 verifies are green, open ONE PR feat/drive-setup → main.
  4. impl writes ZERO spec tests; white-box helper tests, if any, go under impl-paths (drive.sh inline)
     only.
Feature gotchas (project-specific traps the next node MUST know):
  - `SETUP_DO_PBOARD` is a SEPARATE toggle from `SETUP_DO_DASHBOARD` (arch splits step 4 into 4a
    build/link + 4b pboard block) — the frozen tests set them independently; implement both.
  - Emit `REVIEW_SLASH_CMD='$pipeline-review'` SINGLE-QUOTED in the generated drive.defaults (codex
    ≥0.144 $-prefix; unquoted bash expands it to empty).
  - The impl-slot skill's real name is `goal-driven-implementation`; the target roles.yaml must carry
    that on the impl line (never the `<autonomous-coding-skill>` placeholder or a runtime twin name).
  - Honest-degrade (ADR 0002): setup NEVER declares success on its own — it terminates on `doctor` and
    returns its rc; an un-automatable step prints a `fix:` remediation line and sets setup_bad.
  - Config-guard bypass: the WORKDIR/BRANCH/FEATURE guards (drive.sh:69-73) must skip for SUBCMD=setup,
    exactly like they already do for doctor — else setup dies on a missing drive.config.
  - Idempotency: `.bak`-on-change-only (no churn on identical re-run); marker-delimited pboard block;
    `cp` overwrite / `ln -sfn`. All pinned by the frozen tests.
Done when: all 4 cards' `verify` green on feat/drive-setup + the PR is open. On success: cards →review,
run pipeline-review (codex) — freeze gate (git diff 4ac12ec..HEAD -- test/setup-*.sh MUST be empty) +
full-verify green + semantic review + HUMAN merge confirm.
On failure: attempts++; >=3 ⇒ blocked ⇒ run pipeline-hunt.
<<< END

## seq=4 · 2026-07-12T14:56:42Z · impl→review · completed · by=pi-impl
done:   Card C1 (plumbing) green on feat/drive-setup. Added `drive.sh setup` as a real
        subcommand peer of doctor: dispatch + --yes/-y headless activation; config-guard
        bypass (setup CREATES config, so the config-not-found + WORKDIR/BRANCH/FEATURE
        guards skip for SUBCMD=setup, and CONF is forced empty so the operator's real
        ./drive.config is never sourced — keeps the wizard hermetic and feature-agnostic);
        a setup() skeleton that runs the 7 steps each gated by SETUP_DO_<STEP> (default on)
        with gated no-op stubs for C2/C3/C4 to fill; and the doctor terminal (ADR 0002 —
        setup ends on doctor, final rc = DO_DOCTOR ? (doctor_rc | setup_bad>0) : (setup_bad>0?1:0),
        never its own success). Usage header + a README §Setup wizard section added; the
        README run-all line now lists the 4 setup tests. Honest-degrade wired (s_miss ->
        setup_bad) for the bodies C2/C3/C4 land.
verify: bash -n drive.sh (clean) + bash test/setup-plumbing.sh -> passed=3 failed=0
        (dispatch / doctor-terminal-healthy / honest-degrade-bare). Existing 8-test suite
        unchanged (run/hook/preflight/e2e/e2e-orca/defaults-doctor/board-relay/review-drive
        all PASS) — no regression to doctor or the impl loop.
output: feat/drive-setup @ 342871c (drive.sh + README.md, impl-paths only; spec-paths
        test/setup-*.sh untouched — freeze gate diff 4ac12ec..HEAD -- test/ is empty) ·
        PR #9 (feat/drive-setup -> main) · main: tasks/01.md status:review + current.json
        stage:impl + this entry (one commit)
--- handoff ---
>>> NEXT
Run pipeline-impl on a FRESH session (assume you know nothing — rebuild from repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=#9
Model: capable-local OK (impl only) — operator assigns the bot (pi, orca transport).
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    esp. §Test ownership: make the frozen test green via impl-paths + src ONLY, NEVER edit spec-paths)
  - .pipeline/drive-setup/tasks/02.md — the NEXT card (oldest todo): defaults gen + ask_* seam
  - .pipeline/drive-setup/tasks/03.md, 04.md — the remaining todo cards (pboard, target)
  - .pipeline/drive-setup/arch.md — the SETUP_* interface table + the ask_* resolution rule + step-5
    anchors; the C1 plumbing now in drive.sh is the skeleton you build on
  - .pipeline/drive-setup/CONTEXT.md + docs/adr/0002,0003 — honest-degrade + idempotency invariants
  - drive.sh (setup() + setup_do_step + the 7 step stubs, immediately above doctor()) — YOUR target;
    fill setup_defaults + the ask_value/ask_confirm/ask_choice/ask_multi helpers it depends on
  - test/setup-defaults.sh — the frozen test that is YOUR spec (card-scoped verify)
GATE 1 (frozen spec): the feature's single spec-rev is still 4ac12ec905adab2da59666447e8a264245fc3cd3
  (shared across all 4 cards). Read test/setup-defaults.sh — it IS the spec for card 02.
State of the branch: feat/drive-setup is OPEN (PR #9) with C1 landed. git checkout feat/drive-setup &&
git pull --rebase origin main to pick up trunk metadata, then build C2 ON TOP of C1 (same branch, same
PR — all 4 cards accumulate on feat/drive-setup). Do NOT cut a new branch.
Your task (concrete, numbered):
  1. On feat/drive-setup, fill the ask_* seam (ask_value/ask_confirm/ask_choice/ask_multi: SETUP_<KEY>
     env -> default (headless, SETUP_YES=1) -> fzf/read (TTY); ONE path) and setup_defaults (writes
     $DEFAULTS from the drive.defaults.example template: IMPL_TRANSPORT IMPL_SLASH_CMD IMPL_MODEL
     REVIEW_TERMINAL_TITLE REVIEW_SLASH_CMD YOLO BOARD_OUT + sibling/skills paths; mkdir -p its dir;
     REVIEW_SLASH_CMD='$pipeline-review' SINGLE-QUOTED). Idempotent: render to string, no write + no
     .bak if identical, else cp -> .bak then write (ADR 0003).
  2. Editing ONLY impl-paths (drive.sh). Run the card's verify: `bash -n drive.sh && bash
     test/setup-defaults.sh` until passed=4 failed=0. NEVER touch test/setup-*.sh (freeze gate).
  3. When green: push feat/drive-setup (PR #9 auto-updates); on main flip tasks/02.md status:todo->review,
     append this journal (seq=5, impl->review completed), commit once, push. Then route to pipeline-impl
     for card 03 (pboard), then 04 (target) — same branch/PR. Only when all 4 are review -> pipeline-review.
Feature gotchas (project-specific traps the next node MUST know):
  - setup() already runs setup_defaults gated by SETUP_DO_DEFAULTS — just fill the function body (the
    skeleton dispatches it; the stub is currently `:`). setup_do_step PREFLIGHT/SOURCES/SKILLS/DASHBOARD/
    PBOARD/DEFAULTS/TARGET/DOCTOR already gate each step.
  - CONF is forced empty for setup (C1) — setup reads ONLY $DEFAULTS (DRIVE_DEFAULTS seam) for prefill,
    never a per-feature drive.config. drive.sh:62-64 sources $DEFAULTS before dispatch, so its values
    are already in scope as prefill.
  - The frozen test pins DRIVE_DEFAULTS to the output path and HOME to a temp dir; SETUP_<KEY> is the
    override (SETUP_IMPL_TRANSPORT, SETUP_YOLO, SETUP_REVIEW_TERMINAL_TITLE, ...). Note the SETUP_ prefix
    on the env vars vs. the bare keys written into the file (ask_value maps SETUP_YOLO -> YOLO=...).
  - Honest-degrade: the wizard never declares success; setup_bad++ on any un-automatable step, and setup
    ends on doctor when DO_DOCTOR=1 (already wired in C1).
Done when: card 02 verify green on feat/drive-setup + pushed + tasks/02.md -> review on main. On success:
route to pipeline-impl for card 03. When 03 AND 04 are also review (all 4 review) -> pipeline-review (codex):
freeze gate (git diff 4ac12ec..HEAD -- test/setup-*.sh empty) + full-verify green + semantic + HUMAN merge.
On failure: attempts++; >=3 -> blocked -> pipeline-hunt.
<<< END

## seq=5 · 2026-07-12T15:09:20Z · impl→review · completed · by=pi-impl
done:   Card C2 (defaults generation + ask_* / headless seam) green on feat/drive-setup.
        Implemented the four ask_* helpers (ask_value/ask_confirm/ask_choice/ask_multi:
        SETUP_<KEY> env -> caller DEFAULT in headless (SETUP_YES=1) -> fzf/read on a TTY;
        ONE code path, so headless is the real flow not a fork — ADR 0003) and filled
        setup_defaults: it resolves each field via ask_value (IMPL_TRANSPORT IMPL_SLASH_CMD
        IMPL_MODEL REVIEW_TERMINAL_TITLE REVIEW_SLASH_CMD YOLO BOARD_OUT + PIPELINE_REPO
        DASHBOARD_REPO SKILLS_DIR TUI_SKILLS_DIR) and writes $DEFAULTS from a deterministic
        template. REVIEW_SLASH_CMD is emitted SINGLE-QUOTED ('$pipeline-review') so bash
        does not expand $pipeline to empty on source (drive.defaults.example:80). Paths
        keep a literal $HOME (portable + byte-deterministic). mkdir -p the parent dir.
        Idempotent overwrite (ADR 0003): identical content -> no write, no .bak; changed
        -> cp existing to <file>.bak (single, overwritten), then write. The caller DEFAULT
        is the HARDCODED field default (not the sourced value) so a re-run with SETUP_<KEY>
        unset always lands the deterministic default — pinned by assertion 4.
verify: bash -n drive.sh (clean) + bash test/setup-defaults.sh -> passed=4 failed=0
        (values land + codex cmd single-quoted / idempotent no-.bak / .bak-on-change /
        env-override-beats-default). C1 still green (3/3); existing 8-test suite PASS.
output: feat/drive-setup @ bfc774a (drive.sh, impl-paths only; spec-paths untouched —
        freeze gate diff 4ac12ec..HEAD -- test/ empty) · PR #9 updated · main: tasks/02.md
        status:review + this entry (one commit; stage stays impl)
--- handoff ---
>>> NEXT
Run pipeline-impl on a FRESH session (assume you know nothing — rebuild from repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=#9
Model: capable-local OK (impl only) — operator assigns the bot (pi, orca transport).
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    impl-paths + src ONLY, NEVER edit spec-paths)
  - .pipeline/drive-setup/tasks/03.md — the NEXT card (oldest todo): pboard marker block
  - .pipeline/drive-setup/tasks/04.md — the last todo card (target roles.yaml)
  - .pipeline/drive-setup/arch.md — §idempotency invariants (pboard markers + own-only-your-markers)
  - .pipeline/drive-setup/CONTEXT.md + docs/adr/0003 — marker-delimited block rule
  - drive.sh (setup_pboard_block stub at line ~250, the step gated by SETUP_DO_PBOARD inside setup())
    — YOUR target; fill setup_pboard_block
  - test/setup-pboard.sh — the frozen test that is YOUR spec (card-scoped verify)
GATE 1 (frozen spec): the feature's single spec-rev is still 4ac12ec905adab2da59666447e8a264245fc3cd3
  (shared across all 4 cards). Read test/setup-pboard.sh — it IS the spec for card 03.
State of the branch: feat/drive-setup is OPEN (PR #9) with C1+C2 landed. git checkout feat/drive-setup
&& git pull --rebase origin main, then build C3 ON TOP (same branch, same PR). Do NOT cut a new branch.
Your task (concrete, numbered):
  1. On feat/drive-setup, fill setup_pboard_block: write the pboard() shell function into
     ${SETUP_SHELL_RC:-$HOME/.zshrc} inside a marker-delimited block
     '# >>> pipeline pboard >>>' ... '# <<< pipeline pboard <<<'. Idempotent write = delete any
     existing delimited block (sed range delete between the markers, inclusive) then append the fresh
     block. Own ONLY your markers: an unmarked legacy pboard() elsewhere in the rc is left untouched
     (ADR 0003). The rc file may not exist yet (test runs against a fresh path) — create it.
  2. Editing ONLY impl-paths (drive.sh). Run the card's verify: `bash -n drive.sh && bash
     test/setup-pboard.sh` until passed=3 failed=0. NEVER touch test/setup-*.sh (freeze gate).
  3. When green: push feat/drive-setup (PR #9 auto-updates); on main flip tasks/03.md status:todo->review,
     append this journal (seq=6, impl->review completed), commit once, push. Then route to pipeline-impl
     for card 04 (target). Only when 04 is ALSO review (all 4 review) -> pipeline-review.
Feature gotchas (project-specific traps the next node MUST know):
  - The rc path is ${SETUP_SHELL_RC:-$HOME/.zshrc} — the frozen test pins SETUP_SHELL_RC to a temp
    path that does NOT exist yet; setup_pboard_block must create it (and mkdir -p its dir if needed).
  - Idempotency is MARKER-based, not content-based: a re-run deletes the old marked block (sed range)
    and appends the new one -> still exactly ONE marker pair. Do NOT use .bak here (different from
    C2's file-overwrite rule) — the block is a region inside a larger file setup owns only part of.
  - setup() already calls setup_pboard_block gated by SETUP_DO_PBOARD (its own toggle, separate from
    SETUP_DO_DASHBOARD) — just fill the function body (currently ':'). The pboard() body that gets
    written should render/open the board, but its exact correctness is review-reads (the frozen test
    only checks the markers + that a pboard() exists inside them).
  - Leave the unmarked legacy line in place: assertion 3 pre-seeds an unmarked pboard() and asserts it
    survives the run (setup owns only its marked region).
Done when: card 03 verify green on feat/drive-setup + pushed + tasks/03.md -> review on main. On success:
route to pipeline-impl for card 04. When 04 is also review (all 4 review) -> pipeline-review (codex):
freeze gate (git diff 4ac12ec..HEAD -- test/setup-*.sh empty) + full-verify green + semantic + HUMAN merge.
On failure: attempts++; >=3 -> blocked -> pipeline-hunt.
<<< END

## seq=6 · 2026-07-12T15:14:46Z · impl→review · completed · by=pi-impl
done:   Card C3 (pboard marker-delimited block) green on feat/drive-setup. Filled
        setup_pboard_block: writes the pboard() shell function into
        ${SETUP_SHELL_RC:-$HOME/.zshrc} inside a marker-delimited block
        ('# >>> pipeline pboard >>>' ... '# <<< pipeline pboard <<<'). Idempotent +
        own-only-your-markers (ADR 0003): a re-run sed-range-deletes any existing marked
        block (inclusive, portable temp-file sed so BSD + GNU agree) then appends the fresh
        one -> still exactly ONE marker pair; unmarked lines (incl. a legacy pboard()) are
        left untouched. mkdir -p the rc's dir; the rc is created if absent. The pboard() body
        renders the dashboard via $DASHBOARD_REPO/dist/cli.js into BOARD_OUT and opens it
        (review-reads — not frozen).
verify: bash -n drive.sh (clean) + bash test/setup-pboard.sh -> passed=3 failed=0
        (one marker pair + pboard() inside / idempotent across re-runs / unmarked legacy line
        preserved). C1 (3/3) + C2 (4/4) still green; existing 8-test suite PASS.
output: feat/drive-setup @ 79cecb8 (drive.sh, impl-paths only; spec-paths untouched — freeze
        gate diff 4ac12ec..HEAD -- test/ empty) · PR #9 updated · main: tasks/03.md
        status:review + this entry (one commit; stage stays impl)
--- handoff ---
>>> NEXT
Run pipeline-impl on a FRESH session (assume you know nothing — rebuild from repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=#9
Model: capable-local OK (impl only) — operator assigns the bot (pi, orca transport).
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    impl-paths + src ONLY, NEVER edit spec-paths)
  - .pipeline/drive-setup/tasks/04.md — the LAST card (oldest+only todo): target repo roles.yaml init
  - .pipeline/drive-setup/arch.md — §idempotency invariants (roles.yaml .bak-on-change + the impl-slot
    rewrite <autonomous-coding-skill> -> goal-driven-implementation, tool-agnostic)
  - .pipeline/drive-setup/CONTEXT.md + docs/adr/0003 — file-gen idempotency (.bak-on-change-only)
  - drive.sh (setup_target stub, the step gated by SETUP_DO_TARGET inside setup()) — YOUR target
  - test/setup-target.sh — the frozen test that is YOUR spec (card-scoped verify)
GATE 1 (frozen spec): the feature's single spec-rev is still 4ac12ec905adab2da59666447e8a264245fc3cd3
  (shared across all 4 cards). Read test/setup-target.sh — it IS the spec for card 04.
State of the branch: feat/drive-setup is OPEN (PR #9) with C1+C2+C3 landed. git checkout feat/drive-setup
&& git pull --rebase origin main, then build C4 ON TOP (same branch, same PR). Do NOT cut a new branch.
Your task (concrete, numbered):
  1. On feat/drive-setup, fill setup_target (gated by SETUP_DO_TARGET; target path SETUP_TARGET_REPO,
     empty = skip the step): mkdir -p $TARGET/.pipeline; copy $SETUP_PIPELINE_REPO/roles.yaml ->
     $TARGET/.pipeline/roles.yaml, REWRITING the impl slot value '<autonomous-coding-skill>' ->
     'goal-driven-implementation'. Keep it tool-agnostic (NO runtime/LLM name on any slot — CONTRACT
     invariant). Overwrite policy = .bak-on-change-only (same as C2: identical -> no write/no .bak;
     changed -> cp existing to <file>.bak, then write).
  2. Editing ONLY impl-paths (drive.sh). Run the card's verify: `bash -n drive.sh && bash
     test/setup-target.sh` until passed=3 failed=0. NEVER touch test/setup-*.sh (freeze gate).
  3. When green: push feat/drive-setup (PR #9 auto-updates); on main flip tasks/04.md status:todo->review,
     append this journal (seq=7, impl->review completed), commit once, push. At that point ALL 4 cards
     are review -> route to pipeline-review (codex): freeze gate (git diff 4ac12ec..HEAD -- test/setup-*.sh
     empty) + full-verify green + semantic review + HUMAN merge.
Feature gotchas (project-specific traps the next node MUST know):
  - SETUP_PIPELINE_REPO is the SOURCE of the template roles.yaml (the frozen test stubs a fake pipeline
    repo at SETUP_PIPELINE_REPO whose roles.yaml still carries '<autonomous-coding-skill>'); SETUP_TARGET_REPO
    is the destination. Both are pinned by the frozen test.
  - The impl-slot rewrite is a literal substitution on the copied file: '<autonomous-coding-skill>' (the
    placeholder) -> 'goal-driven-implementation' (the real installed name). The assertion greps
    '^impl:[[:space:]]+goal-driven-implementation' and asserts the placeholder is GONE.
  - Tool-agnostic invariant (assertion 2): NO runtime/LLM name (claude|codex|grok|gpt|opus|sonnet|haiku|glm)
    may appear on any slot binding (prd/arch/task/impl/review/hunt/improve). The pipeline-repo template
    already satisfies this; do not introduce one during the copy/rewrite.
  - setup() already calls setup_target gated by SETUP_DO_TARGET — just fill the body (currently ':').
    Use C2's idempotent-overwrite idiom (render to string, compare, .bak-on-change) — do NOT roll your own.
  - Step 6 does NOT scaffold a per-feature drive.config (PRD-confirmed non-scope) — only roles.yaml.
Done when: card 04 verify green on feat/drive-setup + pushed + tasks/04.md -> review on main. Since 04 is
the LAST card, that makes all 4 review -> pipeline-review (codex): freeze gate + full-verify + semantic +
HUMAN merge confirm (the driver/impl NEVER merges).
On failure: attempts++; >=3 -> blocked -> pipeline-hunt.
<<< END

## seq=7 · 2026-07-12T16:12:47Z · impl→review · completed · by=pi-impl
done:   Card C4 (target repo .pipeline/roles.yaml init) green on feat/drive-setup. Filled
        setup_target: resolves SETUP_PIPELINE_REPO (source) + SETUP_TARGET_REPO (destination)
        through the ask_* seam (same ONE-path resolution as C2; empty dst -> skip the step),
        mkdir -p $dst/.pipeline, and writes $dst/.pipeline/roles.yaml from the pipeline repo's
        template with a LITERAL substitution of the impl-slot placeholder
        '<autonomous-coding-skill>' -> 'goal-driven-implementation' (sed 's/.../.../g', the
        ONLY rewrite). Tool-agnostic invariant held (CONTRACT): no runtime/LLM name introduced
        on any slot — the source template already satisfies it and the rewrite touches only the
        placeholder. Idempotent overwrite (ADR 0003, same idiom as setup_defaults): render to
        string, and if identical to the existing file -> no write, no .bak; changed -> cp existing
        to <file>.bak (single, overwritten) then write. Honest-degrade (ADR 0002): a missing
        source roles.yaml calls s_miss (setup_bad++) with a fix: line rather than fake success;
        setup still ends on doctor. Step 6 scaffolds roles.yaml only — NO per-feature drive.config
        (PRD-confirmed non-scope).
verify: bash -n drive.sh (clean) + bash test/setup-target.sh -> passed=3 failed=0
        (impl slot rewritten + placeholder gone / tool-agnostic grep-negative / .bak-on-change
        holds the stale prior version). C1 (3/3) + C2 (4/4) + C3 (3/3) still green; existing
        8-test suite PASS (run 11 / hook 29 / preflight 7 / e2e 6 / e2e-orca 10 /
        defaults-doctor 15 / board-relay 7 / review-drive 34) — no regression.
output: feat/drive-setup @ 4fe87f8 (drive.sh, impl-paths only; spec-paths untouched — freeze
        gate diff 4ac12ec..HEAD -- test/ empty) · PR #9 updated · main: tasks/04.md
        status:review + this entry (one commit; stage stays impl)
--- handoff ---
>>> NEXT
ALL 4 CARDS ARE NOW status:review. Route to pipeline-review (the driver/impl NEVER merges).
Run pipeline-review on a FRESH session (assume you know nothing — rebuild from repo + CONTRACT.md).
repo=https://github.com/jackypanster/pipeline-driver.git branch=main pr=#9
Model: frontier SOTA required (review is a reasoning slot) — operator assigns the bot; the
pipeline can't verify the model.
First: git pull --rebase; no .env in this repo (skip CONTRACT step 2).
Read for context (before acting):
  - https://github.com/jackypanster/pipeline/blob/main/CONTRACT.md — normative protocol (read FIRST;
    esp. the freeze gate is YOURS to enforce: git diff <spec-rev>..HEAD -- spec-paths MUST be empty;
    you merge ONLY on green + clean freeze + semantic review + HUMAN confirm)
  - .pipeline/current.json — feature=drive-setup, stage=impl, full-verify = bash -n + the 12-test
    run-all line (run/hook/preflight/e2e/e2e-orca/defaults-doctor/board-relay/review-drive +
    setup-plumbing/setup-defaults/setup-pboard/setup-target)
  - .pipeline/drive-setup/tasks/{01,02,03,04}.md — all four cards status:review (impl complete)
  - .pipeline/drive-setup/arch.md — §Idempotency invariants the freeze gate + semantic review bind to
  - .pipeline/drive-setup/CONTEXT.md + docs/adr/{0002,0003}.md — honest-degrade + idempotency
GATE 1 (frozen spec / freeze gate): the feature's single spec-rev is
  4ac12ec905adab2da59666447e8a264245fc3cd3. Enforce: git diff 4ac12ec..feat/drive-setup -- test/setup-*.sh
  MUST be empty (impl wrote ZERO tests — it only made them green via drive.sh). If non-empty -> REJECT.
GATE 2 (full-verify): on feat/drive-setup, run current.json.full-verify — all 12 tests + bash -n must
  pass. Already confirmed green by impl on 4fe87f8; re-run to re-prove on the merge commit.
Semantic review (review reads, not frozen): the external-tool steps setup_preflight/setup_sources/
  setup_skills/setup_dashboard_build are stubbed bodies riding C1's plumbing — confirm their gates,
  honest-degrade wiring, and the ask_* interactive path (fzf/read) are sound even though the hermetic
  tests only drive the headless path. Confirm the impl-slot rewrite is the ONLY mutation of the copied
  roles.yaml and no runtime/LLM name can leak for any source template.
Feature gotchas (project-specific traps the reviewer MUST know):
  - feat/drive-setup diverged from main at d43f783 and was NOT rebased onto main's metadata commits
    (spec-rev 4ac12ec never advanced, so the skill's rebase condition was never met). Merging
    feat/drive-setup -> main reconciles code (feat) with trunk metadata (main) cleanly — different
    files, no conflict expected. The freeze gate diffs against spec-rev 4ac12ec, NOT main's tip, so
    the divergence does not affect it.
  - The impl NEVER merges. You merge ONLY after: freeze gate empty + full-verify green + semantic
    review pass + HUMAN confirm. Report all four; halt for the human on the merge itself.
  - SETUP_DO_PBOARD (C3) is a SEPARATE toggle from SETUP_DO_DASHBOARD — both must stay independently
    gated. REVIEW_SLASH_CMD='$pipeline-review' must stay SINGLE-QUOTED in generated drive.defaults.
  - The impl slot's real installed name is goal-driven-implementation; the target roles.yaml must
    carry exactly that on the impl line (never the <autonomous-coding-skill> placeholder).
Done when: freeze gate empty + full-verify green + semantic review pass + HUMAN merge confirm. Advance
current.json.stage per the CONTRACT only after the merge lands (the driver/impl does not touch it here).
On failure (freeze dirty / full-verify red / semantic reject): per CONTRACT review-reject — do NOT
merge; report the gate that failed and the exact remediation.
<<< END

## seq=8 · 2026-07-12T16:24:49Z · impl→review · completed · by=codex-review
done:   review verdict written; awaiting human confirm
        Freeze gate empty; all cards review; exact full-verify green on PR head 4fe87f8.
        Semantic verdict is changes-requested; disposition follows in the next entry.
output: .pipeline/drive-setup/reviews/review-01.md
--- handoff ---
>>> NEXT
Do not merge PR #9. Read `.pipeline/drive-setup/reviews/review-01.md`; the semantic
review found blocking completeness and safety issues despite a clean freeze and green suite.
The rejection disposition and actionable re-spec handoff follow in the next journal entry.
<<< END
