# ADR 0002 — `doctor` is the sole success signal; setup degrades honestly

Status: accepted · Date: 2026-07-12 · Feature: drive-setup

## Context

An installer that prints its own "✓ done" is the classic false-green: it reports success for steps it
only *attempted*. `drive.sh doctor` already exists as a thorough, per-line, exact-remediation verifier
(drive.sh:144-303) — the ground truth for whether the toolchain is actually usable.

## Decision

`setup` **never declares success on its own.** Its terminal step calls `doctor()` (when `DO_DOCTOR=1`)
and setup's exit status is doctor's. Any step setup cannot automate (missing system dep, failed clone,
un-writable dir) prints the exact remediation command (doctor `d_miss` style) and increments a
`setup_bad` counter, so setup's exit is non-zero even when doctor is skipped:

```
final_rc = DO_DOCTOR ? ( doctor_rc | (setup_bad>0) ) : (setup_bad>0 ? 1 : 0)
```

Steps that degrade also leave the machine in a state `doctor` will independently flag (e.g. a skipped
dashboard build ⇒ doctor's "unbuilt dashboard" MISS), so the two mechanisms reinforce.

## Consequences

- This is a **frozen invariant** of the feature: the red test asserts that `setup` with a forced-failing
  step exits non-zero and prints remediation, and that a clean headless run exits with doctor's rc.
- Protects the PRD's most-fragile assumption ("install == cp + symlink + build + config files"): when it
  breaks, setup becomes an honest guided checklist rather than a lying installer.

## Alternatives rejected

- **Setup prints its own success summary** — reintroduces false-green; a user trusts "installed" while
  doctor would block. Rejected.
- **Reinvent per-step verification inside setup** — duplicates doctor, drifts from it. Rejected; reuse
  doctor as the single source of truth.
