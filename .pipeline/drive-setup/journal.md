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
