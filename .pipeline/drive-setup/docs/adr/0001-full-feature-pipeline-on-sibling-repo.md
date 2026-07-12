# ADR 0001 — Run `drive-setup` through the full feature pipeline on a sibling repo

Status: accepted · Date: 2026-07-12 · Feature: drive-setup

## Context

`CONTRACT.md` §Self-improvement (lines 315-321) states that the sibling toolchain repos
(`pipeline-driver`, `pipeline-dashboard`, `pipeline-dispatch`) **carry no `.pipeline/` state** and take
changes through the **meta-PR lane**: open a PR directly → `pipeline-review` does a **semantic-only**
review (no cards, no freeze gate, no full-suite) → human-confirm → reviewer-only squash-merge. That lane
is designed for small skill/doc diffs.

`drive.sh setup` is not a small diff: it is a substantial new feature with a genuine, freezable
correctness surface (deterministic config/file generation, idempotency, honest-degrade exit semantics).

## Decision

Run `drive-setup` through the **full feature pipeline** (prd → arch → task → freeze → impl → review),
seeding `.pipeline/` on `pipeline-driver` for the first time. Operator-confirmed as a deliberate
per-feature choice.

## Consequences

- `.pipeline/` metadata (current.json, roles.yaml, PRD/arch/CONTEXT/ADRs, cards, journal) commits
  straight to trunk (`main`) per CONTRACT §State authority; the reviewable code diff (drive.sh, README,
  test/setup.sh) rides `feat/drive-setup` via PR.
- `pipeline-review` runs the **normal feature review** for this PR — freeze-gate double-commit diff +
  full-suite green + semantic — NOT the semantic-only meta-PR review. The human merge-confirm is
  unchanged either way.
- This deviates from, but does not violate, the sibling-repo convention: the CONTRACT permits a fuller
  process; it does not forbid `.pipeline/` on a sibling repo. Frozen invariants (only-reviewer-merges,
  freeze gate, never-force-push, human-confirm) all still hold.
- Reversible: if abandoned, delete `.pipeline/` on pipeline-driver; nothing else depends on it.

## Alternatives rejected

- **Meta-PR lane** — lighter and contract-native, but forfeits the freeze gate on a feature whose whole
  risk is "does the generated config match, and is it idempotent" — exactly what a frozen test pins. Also
  forfeits the prd/arch/task/impl runtime split the operator wanted to dogfood.
