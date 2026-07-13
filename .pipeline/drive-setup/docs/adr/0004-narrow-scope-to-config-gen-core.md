# ADR 0004 — Narrow `drive.sh setup` to the safe config-generation core

Status: accepted · Date: 2026-07-13 · Feature: drive-setup · Supersedes parts of PRD Scope + arch §steps

## Context

Two review rounds (reviews/review-01.md, review-02.md) both PASSED the freeze gate + full-verify but
were semantically rejected: an independent security-sink review kept surfacing deeper defects in the
**external installer steps** (sources clone/refresh, skills symlink attach, dashboard build/link) and
the **interactive fzf runtime picker / grok path** — `ln -sfn` nesting inside real dirs, `npm ci`
failure still linking, an unused `ask_multi`, grok classified unknown. These paths are a large,
partly-un-hermetically-testable attack surface; the rapid impl→review loop was not converging and card
01 reached `attempts=2` (one rejection from `blocked ⇒ hunt`). Operator decision (2026-07-13): narrow.

## Decision

`drive.sh setup` is scoped to a **safe configuration-generation wizard**. It generates three artifacts,
each hermetically hardened, then verifies with `doctor`:

1. `~/.config/pipeline-driver/drive.defaults` — injection-safe serialization.
2. a target repo's `.pipeline/roles.yaml` — regular-file write that **refuses to follow destination
   symlinks** (review-02 finding 2).
3. the `pboard` block in the shell rc — requires exactly ONE correctly-ordered marker pair (**refuses
   mis-ordered/malformed layouts**, review-02 finding 1), preserves rc mode.

The `ask_*` seam refuses on read-failure/EOF without `--yes` (review-02 finding 5). doctor is the sole
success signal (ADR 0002).

**Cut from this feature** (removed, not stubbed): dependency auto-remediation beyond doctor, source repo
clone/refresh, skills symlink attachment, dashboard build/link, the interactive fzf runtime picker, and
grok attachment. `test/setup-external.sh` and card 05 are removed.

## Consequences

- Skill install / dashboard build / source refresh remain **manual**, documented in the pipeline README
  §Install and diagnosed (not performed) by `doctor`. The wizard prints a pointer, never a fake success.
- The frozen surface is now fully hermetic and convergent: findings 1 and 2 are new red tests
  (setup-safety.sh, setup-target.sh); findings 5 (EOF) is covered by the existing non-TTY test; findings
  6 (rc write atomicity under mid-write failure) and 8 (README run-all list) are **review-reads** —
  impl requirements verified by reading, not freezable in a hermetic bash test.
- Reversible: the cut steps can return as a separate, deliberately-designed feature later.

## Alternatives rejected

- **Another full re-spec of all 8 findings + re-drive** — with card 01 at attempts=2 and findings 5/6/7
  partly un-freezable, high risk of a third rejection → `blocked` → `hunt`. Rejected for non-convergence.
- **Escalate to pipeline-hunt now** — valid, but the operator chose a direct scope reduction over a
  root-cause detour.
