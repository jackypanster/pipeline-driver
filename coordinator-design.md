# Git-Driven Agent Coordinator Architecture

Status: **Partially superseded — see Section 25 (v1.3 outcome)**

The read-only surface (`doctor`/`status`, PR #13) and the cross-repository `pipeline` contract
(control.json / dispatch envelope / stale guard / atomic review outcome, pipeline PR #44) are merged
and REMAIN NORMATIVE for any dispatcher. The deterministic bash dispatch half (`watch`/`resume`,
Sections 8, 12–18) is NOT being implemented — coordinated mode v1 is a CC-as-coordinator playbook
instead (Section 25 records why). Sections describing watch/resume are retained as design history and
as requirements input for any future deterministic dispatcher.

Approved: 2026-07-16

Revision: v1.2 (2026-07-16) — v1.1 trimmed three duplicate-protection mechanisms; the PR #12 review
found one load-bearing, and v1.2 restores it. Kept trims: the dispatch envelope is plain fields (a
hashed dispatch identifier adds nothing over the field-by-field stage guard), and the operational
audit is a plain append-only log (event-sourcing correlation fields and startup whole-file validation
are dropped; a failed append stays fatal). Restored: the two-phase `pending`/`sent` delivery ledger,
`DELIVERY_AMBIGUOUS`, and `resume --pending retry|mark-sent` — a durable pre-send record is the only
thing that lets a restart distinguish "never delivered" from "delivered and the stage ended without a
handoff" (Section 13); without it a restart can silently redispatch over a masked
`AGENT_ENDED_WITHOUT_HANDOFF`, or queue a duplicate send into a not-yet-processing pane. Journal
authority, the route allowlist, fail-fast, `control.json` authorization, atomic review outcome, and
the human-direct merge gate are unchanged throughout. Section 24 records the known v1 limitations.

Audience: implementation agents, reviewers, and operators

Implementation repositories: `pipeline-driver` and `pipeline`

## 1. Purpose

This document is the normative design for an optional, deterministic coordinator that advances a
`pipeline` feature across Claude Code (CC), Pi, and Codex. It is written for a cold agent: do not assume
chat history, shared memory, or knowledge beyond the repositories and Git state named here.

The coordinator replaces manual handoff typing, not human judgment and not stage work. It observes the
remote Git state, validates a finite-state transition, and uses Herdr to type the next stage command into
the correct long-lived agent pane. The stage agent pulls Git, rebuilds context, performs its own work,
and commits the next authoritative journal entry.

This is a new, feature-level opt-in operating mode. Until the implementation described here and the
corresponding `pipeline` contract changes land, `drive.sh` remains impl-only and the repository's current
human-relay restrictions remain in force.

## 2. Decisions

The following decisions are frozen for the first implementation:

1. The remote target repository's `.pipeline/<feature>/journal.md` tail is the only business-state
   authority. `.pipeline/current.json` is a cache and may never overrule the journal.
2. The coordinator is deterministic Bash plus `jq`. It is not a fourth LLM agent and MUST NOT make a
   semantic decision.
3. One coordinator watches one target repository. The existing one-feature-in-flight contract remains.
4. CC, Pi, and Codex each run in a long-lived Herdr pane backed by an independent clone of the target
   repository. They do not share a working tree.
5. Herdr is a lightweight command transport. It is not the workflow state store, message queue, event
   log, completion signal, or Pub/Sub authority.
6. `drive.sh` remains the impl-loop primitive. `coordinate.sh` owns cross-stage routing and delegates an
   impl span to `drive.sh` rather than duplicating its card loop.
7. The operator starts `pipeline-prd` in CC. Once PRD commits the first authorized journal entry, the
   coordinator owns normal handoffs until the final merge gate or a fail-fast stop.
8. Only a direct operator message in the same Codex session that emitted the approval gate may confirm
   merge. The coordinator MUST NOT relay, synthesize, or infer that confirmation.
9. Card `attempts` is the retry identity and budget. One impl failure or one changes-requested review
   round increments it once. Multiple findings in one review round still increment it once. At
   `attempts >= 3`, the card becomes `blocked` and routes normally to CC for `pipeline-hunt`.
10. Contract-valid `failed`, changes-requested, and `blocked -> hunt` outcomes are business transitions,
    not coordinator failures. System, protocol, transport, audit, and state-integrity errors fail fast.

## 3. Goals and non-goals

### Goals

- Remove manual CC -> Pi -> Codex command relays while keeping Git as the durable handoff.
- Recover deterministically after a coordinator restart without silently duplicating stage work.
- Reject stale, malformed, ambiguous, or unauthorized state before any new command is delivered.
- Make every observation, decision, delivery, halt, and human resume operationally traceable.
- Preserve the existing freeze gate, write sets, retry budget, hunt routing, semantic review, and direct
  human merge confirmation.
- Keep the channel replaceable: a future transport may replace Herdr without changing workflow state.

### Non-goals

- No model-based scheduler, task decomposition, semantic approval, review judgment, or root-cause work.
- No message broker, database, Pub/Sub subscription, distributed consensus, or multi-repository daemon.
- No parallel features in one repository and no parallel stages in one feature.
- No automatic merge, automatic merge-confirm relay, or unattended recovery from a fatal condition.
- No cryptographic audit-log tamper proofing. Git supplies durable business history; local logs supply
  operational diagnosis.
- No implementation in this documentation change.

## 4. Component responsibilities

| Component | MUST do | MUST NOT do |
|---|---|---|
| Remote Git + journal | Persist artifacts, transitions, attempts, outputs, and handoffs | Depend on a live pane or coordinator memory |
| `coordinate.sh` | Fetch, parse, validate, deduplicate, route, audit, halt, and resume | Write product artifacts, judge quality, merge, or edit the target journal |
| `drive.sh` | Execute the existing bounded impl card loop | Expand into a whole-pipeline scheduler |
| Herdr adapter | Resolve an authorized pane and atomically submit text plus Enter | Store workflow state or decide what runs next |
| CC pane | Run PRD, architecture, task, and hunt skills | Implement cards or approve its own work |
| Pi pane | Run `pipeline-impl` through the existing driver contract | Edit frozen spec paths, review, or merge |
| Codex pane | Run independent `pipeline-review` and emit the direct merge gate | Accept a coordinator-relayed merge confirmation |
| Operator | Start PRD, answer exceptional HITL questions, resolve fatal stops, confirm merge | Be required for normal stage-to-stage typing |

The coordinator MUST remain replaceable. No stage skill may depend on coordinator-local files; every
stage rebuilds its business context from Git.

## 5. Repository and pane topology

The watcher and three role clones MUST resolve to the same normalized remote identity and trunk branch.
Each role clone has a stable absolute path and a unique Herdr pane whose `cwd` is that clone or a
descendant of it.

| Role | Normal stages | Clone requirement | Pane selection |
|---|---|---|---|
| CC | `arch`, `task`, `hunt` (and operator-started `prd`) | Independent clone | Unique cwd match; optional pinned pane ID |
| Pi | `impl` | Independent clone | Unique cwd match; optional pinned pane ID |
| Codex | `review` | Independent clone | Unique cwd match; optional pinned pane ID |

A pinned pane ID overrides cwd discovery but MUST still resolve to the configured role clone and MUST
not be the coordinator's own pane. Zero matches, multiple matches, a self-pane, an unauthorized agent
status source, or a remote mismatch is fatal. The coordinator never creates or destroys panes in v1.

## 6. Feature-level authorization

Coordinated mode is authorized by a tracked file created with the PRD:

`.pipeline/<feature>/control.json`

```json
{
  "schema_version": 1,
  "mode": "coordinated",
  "merge_gate": "human-direct"
}
```

Rules:

- `schema_version` MUST equal `1`.
- `mode` MUST be `human` or `coordinated`.
- `merge_gate` MUST equal `human-direct`; no other merge policy is valid.
- Absence is equivalent to human mode: the watcher observes but does not dispatch.
- `pipeline-prd` creates this file only when the operator explicitly requested coordinated mode in the
  initial PRD session. Git history is the authorization audit.
- A malformed file is fatal. A coordinated feature whose file disappears or changes after its first
  dispatch is fatal (`AUTOMATION_AUTH_CHANGED`); the watcher does not interpret that as a pause.
- The coordinator MUST read the file from the observed remote trunk commit, not from a working tree.
- Stage agents MUST preserve the file and MUST NOT modify it.

## 7. Authoritative route table

The coordinator parses the last complete journal entry, including `from`, `to`, run status, and the
first handoff line after `>>> NEXT`. The `Run pipeline-<stage>` handoff is the dispatch target; the
header transition, status, cards, and feature state are mandatory validation evidence. Do not equate
the header arrow mechanically with the next command: existing journals use the transition to describe
the stage result while the handoff names the next cold node.

The business routes approved for coordinated mode are:

| Logical route | Exact NEXT kind | Required journal evidence | Target/action |
|---|---|---|---|
| `prd -> arch` | `Run pipeline-arch` | completed PRD entry; `to=prd` | CC: architecture |
| `arch -> task` | `Run pipeline-task` | completed architecture entry; `to=arch` | CC: task decomposition/freeze |
| `task -> impl` | `Run pipeline-impl` | completed task entry; `to=task`, or a valid impl retry/continuation below | Pi: start `drive.sh` impl span |
| `impl -> impl` | `Run pipeline-impl` | `impl -> impl · completed|failed`; actionable todo card | Pi: continue or informed-retry |
| `review -> impl` | `Run pipeline-impl` | `review -> impl · failed`; exactly one named actionable card | Pi: restart `drive.sh` |
| `impl -> review` | `Run pipeline-review` | `impl -> review · completed`; every card is review | Codex: semantic review |
| `impl -> hunt` | `Run pipeline-hunt` | `impl -> hunt · blocked`; named blocked card | CC: root-cause diagnosis |
| `review -> hunt` | `Run pipeline-hunt` | `review -> hunt · blocked`; named blocked card or integration report | CC: root-cause diagnosis |
| `hunt -> task` | `Run pipeline-task` | `hunt -> task · completed`; named re-split/re-freeze target | CC: task/re-freeze |
| `hunt -> impl` | `Run pipeline-impl` | `hunt -> impl · completed`; diagnosed card reset to `todo, attempts: 0` | Pi: fresh informed budget |
| approved review | exact human-merge wait marker | `review -> review · completed` | none: enter `WAITING_HUMAN_MERGE` |
| completed feature | terminal handoff | `review -> done · completed`; all cards done | none: complete and return to idle |

Legacy journals may contain a first-card `task -> impl · completed` entry. It is valid only when its
NEXT and card state agree with the same impl continuation/review rules; the new contract SHOULD emit the
stage-specific forms above consistently. `parse-tail.awk` must be extended to expose `TO` and `NEXT_KIND`
rather than routing from its current `FROM`/`NEXT` subset alone.

Any transition/status/NEXT/card-state combination outside this allowlist is fatal. The coordinator MUST
NOT infer a route from prose, `current.json.stage`, agent output, or pane title. It may read cards only to
validate the mechanically named target and retry budget, never to choose a semantic route.

### 7.1 Atomic review outcome

Coordinated mode requires the review outcome to be atomically visible in Git:

- Approved: commit the review artifact and one `review -> review · completed` journal entry whose first
  handoff line is exactly:

  `Await human-direct merge confirmation in this reviewer session.`

- Changes requested: commit the review artifact, offending-card status/attempt update, and exactly one
  `review -> impl · failed` or `review -> hunt · blocked` journal entry with a normal `Run pipeline-*`
  handoff.

The reviewer MUST NOT expose an intermediate "verdict written; disposition follows" commit in
coordinated mode. Without this rule, the watcher could observe a review result that is neither routable
nor a valid merge wait. Human-relay mode may remain backward compatible, but coordinated mode is strict.

## 8. Coordinator lifecycle

The process has these internal states:

| State | Meaning | Allowed exit |
|---|---|---|
| `IDLE` | No coordinated feature is currently actionable | Observe a new remote commit |
| `VALIDATING` | Preflight or pre-dispatch checks are running | `IDLE`, `DISPATCHING`, or `FATAL` |
| `DISPATCHING` | Ledger is `pending`; Herdr send is in progress | `WAITING` or `FATAL` |
| `WAITING` | Delivery is `sent`; waiting for a newer journal commit | New valid transition or `FATAL` |
| `WAITING_HUMAN_MERGE` | Codex emitted the exact direct-human gate | `review -> done`, rejection route, or `FATAL` |
| `FATAL` | No further dispatch is permitted | Non-zero process exit only |

Normal loop:

1. Acquire the per-repository single-watcher lock.
2. Run full preflight.
3. Fetch the configured remote trunk ref.
4. Read `current.json`, `control.json`, the journal tail, task cards needed for validation, and the
   observed trunk commit using `git show`; do not rely on a checked-out worktree.
5. If the commit is unchanged and ledger state is consistent, continue waiting.
6. Validate the state against the route table and derive an immutable dispatch envelope.
7. Fetch once more before sending. If the ref changed, discard the stale decision and reconcile the new
   commit. A valid concurrent advance is not an error; an illegal new state is fatal.
8. Atomically persist `pending`, send through Herdr, then atomically persist `sent`.
9. Observe Git and the authoritative Herdr agent lifecycle until the journal advances, an exact human
   merge wait appears, or a fatal condition occurs.

No-change polling is normal. A failed fetch, invalid lifecycle sample, pane disappearance, stage timeout,
or agent completion without the promised journal handoff is fatal on its first occurrence.

## 9. Dispatch envelope and stage guard

Every command delivered by the coordinator MUST carry:

```text
repo=<absolute role clone path>
branch=<trunk branch>
feature=<feature slug>
expected_seq=<journal sequence observed by coordinator>
expected_commit=<full observed trunk commit>
```

The dispatch identity is the plain tuple `(feature, expected_seq, expected_commit)`; it is already
unique per dispatch, and the stage guard below verifies every field individually, so no derived hash
identifier exists. Logs and `status` output display a dispatch as `<feature>@seq<N>/<short-commit>`;
the envelope itself always carries the full commit hash.

Before any write, every coordinated stage skill MUST:

1. Fetch the configured remote trunk.
2. Verify the remote identity, branch, feature, full commit, journal seq, and expected NEXT stage exactly.
3. Verify `control.json` still authorizes coordinated mode.
4. Refuse stale or duplicate work without writing Git, print `STALE_DISPATCH` with the mismatched field,
   and stop.

This guard is a required cross-repository `pipeline` contract change. A natural-language suggestion to
"check Git first" is not a substitute.

## 10. Herdr transport contract

The coordinator reuses the reviewed Herdr CLI integration from
[`pipeline-driver` PR #11](https://github.com/jackypanster/pipeline-driver/pull/11). That PR is an
implementation prerequisite; this document deliberately remains based on `main` so the design is not
coupled to unmerged code.

For each dispatch the adapter MUST:

- use Herdr CLI verbs, not raw socket access and not `events.subscribe`;
- resolve the role pane by pinned ID or unique authorized cwd match;
- exclude the current coordinator pane;
- prove the agent lifecycle status source is authoritative before trusting idle/done/busy;
- wait at most the configured readiness budget for the target to become dispatchable;
- submit the complete command and Enter atomically with `herdr pane run`;
- never use pane output as workflow truth;
- never automatically reset or recreate a pane in coordinator v1.

Herdr command acceptance proves delivery to the pane, not stage completion. Only a newer valid Git
journal entry proves completion.

## 11. Configuration interface

`coordinate.sh` reads one shell configuration file. It MUST validate every value before sourcing any
optional executable and MUST never `eval` a configured command.

The repository will provide `coordinate.config.example` with these public fields:

```bash
OBSERVER_WORKDIR=/absolute/path/to/observer-clone
BRANCH=main

CC_WORKDIR=/absolute/path/to/cc-clone
PI_WORKDIR=/absolute/path/to/pi-clone
CODEX_WORKDIR=/absolute/path/to/codex-clone

# Optional runtime-issued pins; cwd discovery is used when absent.
# CC_PANE_ID=
# PI_PANE_ID=
# CODEX_PANE_ID=

CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='$pipeline-review'

POLL_SECS=30
PANE_READY_TIMEOUT_MS=60000
STAGE_TIMEOUT_SECS=2700

# Executable path only. The sole argument is the absolute halt.json path.
# ON_HALT_EXEC=/absolute/path/to/notifier
# STATE_DIR=/absolute/path/to/pipeline-driver-state
```

Validation rules:

- All workdirs MUST be absolute, existing Git clones with the same normalized remote and branch.
- Command prefixes MUST be non-empty single-line strings; the coordinator appends the escaped envelope.
- Pane IDs, when supplied, MUST be single-line opaque identifiers and are revalidated against cwd.
- Numeric timeouts MUST be positive base-10 integers within documented upper bounds.
- `ON_HALT_EXEC`, when set, MUST be an absolute executable regular file, not a symlink. It is invoked as
  an argv vector with no shell expansion and a bounded timeout.
- State files MUST be outside the target repository and created with directory mode `0700` and file mode
  `0600`.

## 12. Command-line interface

The future public commands are:

```text
coordinate.sh doctor --config <path>
coordinate.sh watch --config <path>
coordinate.sh status --config <path>
coordinate.sh resume --config <path> --reason <text> [--pending retry|mark-sent]
```

### `doctor`

Read-only full preflight. It reports dependencies, remote identity, branch, control/journal parse,
role-clone agreement, pane resolution, lifecycle authority, state-directory permissions, ledger
integrity, lock state, and halt state. Any missing prerequisite exits non-zero.

### `watch`

Acquire the lock and run the reconcile loop. If an unresolved `halt.json` exists, exit non-zero and tell
the operator to use `resume`; plain `watch` cannot bypass a halt.

### `status`

Read only local state and the last observed Git identifiers. Print one concise human summary plus a JSON
form suitable for agents. It never contacts a model and never changes ledger state.

### `resume`

Require a non-empty human reason, rerun full preflight, record the human resume event, and resume only
after the original guard is satisfied. If ledger state is ambiguous `pending`, require exactly one:

- `--pending retry`: the operator inspected the pane and authorizes redelivery;
- `--pending mark-sent`: the operator inspected the pane and confirms delivery occurred.

The two flags encode a finding only the pane transcript can settle: an idle pane over an unchanged
journal and an unconsumed seq is EITHER a send that never landed OR a stage that ran and ended without
its promised handoff — the stale-dispatch guard cannot tell them apart (it refuses only consumed
seqs), and guessing either way masks a real failure. The choice, reason, prior fatal event, and
resulting state MUST be audited. Coordinator code never selects either option automatically.

## 13. Local delivery state

The default state root is `${XDG_STATE_HOME:-$HOME/.local/state}/pipeline-driver`, overridable by
`STATE_DIR`. A stable repo key is derived from normalized remote identity. Each feature owns:

```text
<state-root>/<repo-key>/<feature>/
  ledger.json
  events.jsonl
  halt.json        # present only while unresolved
  lock/            # atomic single-watcher lock directory
```

`ledger.json` records the observed Git state and the current dispatch: feature, journal seq, full
commit, target role/pane, command name (not full prompt), and delivery state `pending`, `sent`, or
`waiting`. Updates use an exclusive same-directory temporary file followed by atomic rename.
Predictable temp names and symlink-following writes are forbidden.

Delivery sequence:

1. Append `dispatch_pending` to the audit log.
2. Atomically write ledger state `pending`.
3. Execute `herdr pane run`.
4. On confirmed CLI success, atomically write `sent` and append `dispatch_sent`.
5. While the journal commit is unchanged, do not redeliver.

A crash after step 2 and before step 4 is intentionally ambiguous. On restart it produces
`DELIVERY_AMBIGUOUS`, writes a halt snapshot, and requires the human `resume --pending` choice
(Section 12). The write-ahead `pending` record is load-bearing, not ceremony (PR #12 review finding):
the stage stale-dispatch guard refuses only CONSUMED seqs, so it cannot protect the two
delivered-but-unrecorded windows. (a) The command was delivered and the stage later ended idle with no
journal handoff: a record-less restart would see idle + unchanged Git + an unconsumed seq, pass both
readiness and the guard, and silently redispatch over what live observation would have failed as
`AGENT_ENDED_WITHOUT_HANDOFF`. (b) The command was delivered but the pane has not yet started
processing (it still reads idle): a record-less restart would queue a second send into the same pane.
In both windows only the durable `pending` mark forces the halt-and-inspect path instead of a masked
failure or a duplicate.

## 14. Fail-fast contract

At the first fatal condition the process MUST perform, in order:

1. Stop all new dispatches.
2. Append a structured `fatal` event when the audit sink remains writable.
3. Atomically write `halt.json` with the same actionable diagnosis.
4. Print the error code, location, sanitized inputs, direct cause, and next action to stderr.
5. Invoke the bounded optional halt hook. Hook failure is reported but never masks the original error.
6. Release safe resources and exit non-zero. No supervisor may be configured to auto-restart it.

Every error MUST include:

- `where`: component and operation;
- `input`: non-secret repo, feature, seq, commit, role, and pane context;
- `reason`: the concrete direct cause;
- `next_action`: what the human should inspect or fix;
- `resume_guard`: what must be true before resume.

Stable fatal codes include:

| Category | Codes |
|---|---|
| Configuration | `CONFIG_INVALID`, `DEPENDENCY_MISSING`, `WORKDIR_INVALID`, `REMOTE_MISMATCH` |
| Git | `GIT_FETCH_FAILED`, `REMOTE_REF_MISSING`, `GIT_OBJECT_UNREADABLE` |
| Protocol | `CONTROL_MALFORMED`, `AUTOMATION_AUTH_CHANGED`, `JOURNAL_MALFORMED`, `JOURNAL_SEQ_INVALID`, `TRANSITION_ILLEGAL`, `NEXT_INVALID`, `CARD_STATE_INVALID` |
| Local state | `LOCK_HELD`, `LOCK_STALE`, `LEDGER_CORRUPT`, `DELIVERY_AMBIGUOUS`, `AUDIT_WRITE_FAILED` |
| Pane/transport | `PANE_NOT_FOUND`, `PANE_AMBIGUOUS`, `PANE_SELF`, `PANE_UNAUTHORIZED`, `PANE_NOT_READY_TIMEOUT`, `HERDR_SEND_FAILED` |
| Execution | `AGENT_STATUS_INVALID`, `AGENT_ENDED_WITHOUT_HANDOFF`, `STAGE_TIMEOUT` |

An audit-write failure is itself fatal. If both the audit log and `halt.json` are unwritable, the
minimum fallback is a sanitized stderr message and non-zero exit; the process MUST NOT continue
unobserved.

## 15. Business failures are not fatal

The coordinator validates and routes these outcomes without intervention:

- Impl failure with `attempts < 3`: card returns to `todo`; route Pi again with the new journal seq.
- Review changes-requested with `attempts < 3`: offending card returns to `todo`; route Pi.
- Any card reaching `attempts >= 3`: card becomes `blocked`; route CC to `pipeline-hunt`.
- Hunt may route to task for re-split/re-freeze or reset a diagnosed card to `todo, attempts: 0` and
  route to impl with a fresh informed budget.

The counter is card-level. It does not fingerprint individual findings and does not add once per finding.
Missing attribution, a counter jump, a review rejection that leaves no actionable card, or disagreement
between the journal and card state is a protocol fatal rather than a guessed route.

## 16. Operational audit

Git journal and coordinator audit have different jobs:

- `journal.md` is the durable business audit: stages, artifacts, attempts, outcomes, and handoffs.
- `events.jsonl` is the local operational audit: observations, validations, dispatch delivery, waits,
  fatal stops, and human resumes.

Each JSONL event carries these fields, present where applicable to the event type:

```text
timestamp, event
remote_identity, branch, feature
journal_commit, journal_seq, transition, stage_status
action, target_role, pane_id, result, duration_ms
error_code, error_context, next_action
```

Event types include `watch_started`, `observed`, `validated`, `dispatch_pending`, `dispatch_sent`,
`waiting`, `business_transition`, `waiting_human_merge`, `fatal`, `resume`, `completed`, and
`watch_stopped`.

Rules:

- One compact JSON object per line; append only. There is exactly one sequential writer, so wall-clock
  timestamps order events; no event sequence number or correlation/causation chain exists.
- The log is diagnostic output, not workflow input: the coordinator never reads it back to make a
  decision, and startup does not validate historical content. A failed append is fatal
  (`AUDIT_WRITE_FAILED`).
- Never log credentials, auth environment values, complete prompts, complete commands, complete pane
  output, source-file bodies, or unrestricted stderr.
- Store only the command name, identifiers, timings, and a bounded sanitized stderr excerpt.
- Preserve logs per workflow without automatic rotation in v1. Cleanup is a separate explicit operator
  action, not coordinator behavior.
- `halt.json` is a current diagnostic snapshot, not the audit history. It carries the same diagnosis
  as the fatal audit event.

## 17. Human merge gate

When the exact approved-review marker is observed, the coordinator:

1. Records `waiting_human_merge`.
2. Marks ledger state `waiting`.
3. Performs no Herdr send and has no merge-confirm command path.
4. Continues read-only Git observation.

The operator replies directly in the same Codex session using the exact token accepted by
`pipeline-review`. Codex performs the merge and appends `review -> done`. If that session is lost, the
gate is disarmed and review must run again; the coordinator cannot restore or impersonate the session.

## 18. Signals, timeouts, and exceptional HITL

- `POLL_SECS` controls normal no-change Git polling; no change is not an error.
- `PANE_READY_TIMEOUT_MS` bounds waiting to deliver before the stage begins.
- `STAGE_TIMEOUT_SECS` bounds a delivered stage that produces neither a newer journal entry nor a valid
  human-merge wait.
- An authoritative `blocked`/error agent status or an idle/done agent with no promised handoff fails
  immediately; the process does not wait for the stage timeout.
- If CC asks a legitimate product/architecture question and ends its turn without a journal handoff,
  the watcher still fails closed as `AGENT_ENDED_WITHOUT_HANDOFF`. The operator answers in CC, lets CC
  finish and commit, then explicitly resumes. The coordinator does not inspect prose to distinguish a
  question from an incomplete stage.
- `SIGINT`/`SIGTERM` records `watch_stopped` when possible and exits. If interrupted in `pending`, the
  next start detects delivery ambiguity and requires human resolution.

## 19. Security and write safety

- The watcher reads target Git only. Stage agents remain the only writers of target artifacts/journal.
- Shell runs with strict error handling. Expected non-zero outcomes are handled explicitly; errors are
  never swallowed.
- Configured command prefixes are data, not shell programs. Construct argv safely and never `eval` them.
- Local state writes reject symlink destinations and symlinked parent components, use exclusive random
  same-directory temp files, set restrictive permissions, and atomically rename.
- The lock is acquired atomically. A stale lock is fatal and is removed only during an explicit resume
  after verifying the recorded PID is not alive.
- The halt hook receives only the absolute `halt.json` path. It has no implicit access to prompts or
  tokens and cannot authorize resume.
- Git commit IDs are full hashes in envelopes and audit records; abbreviated hashes are display-only.

## 20. Cross-repository implementation contract

Implementation spans two repositories and must land as separately reviewable changes.

### `pipeline` first

Update `CONTRACT.md`, `DESIGN.md`, README, and the relevant stage skills to:

- define `control.json` and feature-level coordinated-mode authorization;
- let `pipeline-prd` create it only from explicit operator intent;
- accept the dispatch envelope on `arch`, `task`, `impl`, `review`, and `hunt`;
- perform the mandatory pre-write stale-dispatch guard;
- make review outcomes atomic in coordinated mode;
- emit the exact human-direct merge wait marker;
- preserve human-relay mode and the direct-human merge invariant.

### `pipeline-driver` second

After the pipeline contract lands and Herdr transport PR #11 is merged or deliberately rebased into the
implementation branch, add:

- `coordinate.sh` and `coordinate.config.example`;
- shared, tested journal parsing that exposes `from`, `to`, status, NEXT kind, and terminal wait kind;
- per-repo watcher locking and Git reconciliation;
- role/pane resolution and Herdr dispatch;
- ledger, JSONL audit, halt hook, doctor, status, and resume;
- delegation of impl spans to the existing `drive.sh` without changing its standalone impl-only scope;
- end-to-end validation with a real remote, independent clones, and real Herdr panes.

The currently active `.pipeline/drive-setup` feature in `pipeline-driver` MUST NOT be displaced or joined
by a second `.pipeline` feature. Coordinator implementation must be a toolchain meta-PR with no new
`.pipeline` state, or wait until `drive-setup` is resolved.

## 21. Implementation sequence for CC

1. Read this document, `pipeline/CONTRACT.md`, `pipeline/DESIGN.md`, `pipeline-driver/README.md`, and
   Herdr transport PR #11. Do not reinterpret frozen decisions.
2. Implement and review the `pipeline` contract/skill change first.
3. Rebase the driver implementation on a commit containing the Herdr transport.
4. Add coordinator configuration and read-only `doctor` before any dispatch behavior.
5. Add strict journal/control parsing and the route table.
6. Add local lock, ledger, audit, fatal, status, and resume semantics.
7. Add Herdr delivery last; no send is allowed until all preflight and pre-dispatch guards pass.
8. Integrate `drive.sh` as the impl span without relaxing its standalone halt/merge guarantees.
9. Exercise every fatal seam and crash window, then run the real three-pane flow.
10. Keep the two repository diffs independent and reviewable; do not merge either automatically.

## 22. Acceptance scenarios

The implementation is not complete until all scenarios below are demonstrated:

1. Manual CC PRD creates an authorized feature; watcher routes PRD -> arch -> task in CC.
2. Task completion starts the existing Pi impl loop; multiple cards advance from Git only.
3. Final impl completion dispatches Codex review exactly once.
4. One review rejection increments the offending card once and routes Pi; multiple findings do not
   consume multiple attempts.
5. The third card-level failure/rejection routes CC hunt as a normal business transition.
6. Hunt routes to task or impl with correct state and, where applicable, a reset retry budget.
7. Approved review enters `WAITING_HUMAN_MERGE`; coordinator cannot send a merge token.
8. Direct operator confirmation in Codex produces `review -> done`; watcher returns to idle.
9. Restart after `sent` does not redeliver while the journal is unchanged.
10. Restart with ambiguous `pending` halts as `DELIVERY_AMBIGUOUS` and requires an explicit
    `--pending retry` or `--pending mark-sent`; the coordinator never resolves the ambiguity alone.
11. Real-pane window (a): kill the coordinator after Herdr acceptance but before the `sent` record,
    let the stage end idle WITHOUT a journal handoff, restart — the coordinator halts on the
    `pending` record and does NOT silently redispatch the unconsumed seq.
12. Real-pane window (b): kill the coordinator after Herdr acceptance while the pane still reads idle
    (delivery accepted, processing not started), restart — the coordinator halts on the `pending`
    record; no second send is queued into the pane.
13. Malformed control/journal, illegal transition, bad counter, remote mismatch, ambiguous pane,
    unauthorized agent status, fetch/send failure, timeout, stale lock, and audit-append failure each
    produce one actionable fatal record and no subsequent send.
14. A Git ref change before send causes safe re-observation; the stale decision is never delivered.
15. Human-relay features without coordinated authorization are observed but never dispatched.
16. Audit and halt artifacts contain the identifying Git/feature context and sanitized errors but no
    tokens, prompt bodies, pane transcript, or source bodies.
17. Real integration uses the real remote, three independent clones, and real Herdr panes; mock-only
    evidence is insufficient.

## 23. Compatibility and rollout

- This design is additive and opt-in. Existing human-relay and standalone `drive.sh` flows remain valid.
- The coordinator must reject coordinated features until both repositories support schema version 1.
- No automatic migration writes `control.json` into existing features.
- A rollback removes or stops the watcher; it does not rewrite Git history. The feature remains
  resumable by normal human relay from the journal tail.
- The implementation PRs must update existing prose that says a whole-pipeline scheduler is forbidden:
  the prohibition remains the default, while this approved deterministic, feature-authorized mode is
  the explicit exception. Do not leave contradictory instructions for agents.

## 24. Known v1 limitations

1. Stage autonomy between journal commits is assumed. Every legitimate stage question that ends a turn
   without a journal handoff halts the coordinator as `AGENT_ENDED_WITHOUT_HANDOFF` and costs a human
   `resume`. `prd` is operator-started and outside coordination, and the impl/review spans have proven
   autonomous in real runs, but if real coordinated runs show frequent legitimate questions in
   `arch`/`task`, v2 must design a first-class question path rather than relaxing the fail-closed rule.
2. Herdr agent lifecycle authority is proven only for the Pi impl pane
   ([PR #11](https://github.com/jackypanster/pipeline-driver/pull/11)). `doctor` MUST prove lifecycle
   authority for the CC and Codex panes before the first dispatch; if it cannot, coordinated mode is
   not viable on that runtime and implementation stops rather than trusting pane heuristics.

## 25. v1.3 outcome — the dispatch half pivots to a CC-as-coordinator playbook

Decision (operator, 2026-07-16): `watch`/`resume` are NOT implemented in bash. The dispatch half of
coordinated mode v1 is a **Claude Code session executing a reviewed playbook skill**
(`pipeline-coordinate`, in the `pipeline` repository), using the same Herdr transport verbs
(`pane run` / `agent explain`) this document specifies. Three findings from the implementation
attempt ([PR #14](https://github.com/jackypanster/pipeline-driver/pull/14), closed unmerged) drove
the pivot:

1. **Frozen decision 6 is structurally unimplementable as written.** Delegating impl spans to the
   existing `drive.sh` requires a headless path through its interactive GATE 1 trust gate — the one
   surface every party agreed never to relax. The alternative (per-card dispatch by the coordinator)
   was viable, but by then finding 2 dominated.
2. **Coordination is semi-semantic.** Decision 2 ("the coordinator MUST NOT make a semantic
   decision") forces every judgment — is the implementer's output acceptable, what should a fix
   handoff say, is a review round closed — into machine-parseable protocol. The 46 review findings
   across PRs #13/#14 were overwhelmingly the cost of making bash safe against inputs a reasoning
   coordinator simply reads. A CC session handles those cases natively and demonstrably better (this
   architecture's own PRs were coordinated exactly that way, end to end).
3. **The unattended premise was already void.** The merge gate requires a live human in the reviewer
   session (Section 17), so end-to-end unattended operation was never achievable; an attended CC
   coordinator gives up nothing the design could actually deliver.

What remains normative from this document for the playbook coordinator: the role/pane topology (§5),
`control.json` authorization (§6), the route evidence table (§7 — as reading guidance, not a parser
spec), the dispatch envelope + stage stale guard (§9, merged in `pipeline` #44), the Herdr transport
contract (§10), the human merge gate (§17), and the three-roles/three-models separation with the
operator as final gate. `doctor`/`status` (#13) are the playbook's session preflight. `drive.sh` is
unchanged and remains the standalone impl-loop tool. A future deterministic dispatcher may revisit
Sections 8/12–18 with this section as its first requirements input.
