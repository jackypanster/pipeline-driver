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
