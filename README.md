# pipeline-driver

Read-only **preflight + summary companion for coordinated mode** of the
[`pipeline`](https://github.com/jackypanster/pipeline) toolchain. One live tool:

```
coordinate.sh doctor --config <path>   # read-only full preflight (clones, remote identity, panes, authority, bindings)
coordinate.sh status --config <path>   # no-network one-line summary of the active feature
```

It holds **zero local state** and never dispatches: it only reads the target repo's
`.pipeline/<feature>/` artifacts (and, for `doctor`, the Herdr role panes). Dispatch is the
`pipeline-coordinate` playbook's job — a CC session drives the Pi (impl) and Codex (review)
panes over Herdr. The repo name is historical (see the archive section at the end).

## For agents (read this first)

- Run `coordinate.sh doctor` before dispatching a coordinated feature; re-run until `0 blocking`.
- Run it from a **non-role** shell: it captures its own `HERDR_PANE_ID` as "self" and excludes
  that pane, so running inside a role pane makes that role unresolvable (`PANE_NOT_FOUND`).
- It never writes target-repo state, never merges, never types into a pane. Do not add a
  dispatch half: bash `watch`/`resume` was evaluated and rejected — PR #14 closed unmerged
  (https://github.com/jackypanster/pipeline-driver/pull/14); the pivot to the CC-as-coordinator
  playbook is recorded in design v1.3 §25, pinned at
  https://github.com/jackypanster/pipeline-driver/blob/19e8c954/coordinator-design.md
  (PR #15: https://github.com/jackypanster/pipeline-driver/pull/15).
- Do not invent another scheduler. The merge confirm stays human in `pipeline-review`.

## Files

| file | purpose |
|------|---------|
| `coordinate.sh` | read-only `doctor` + `status` — the complete surface |
| `parse-tail.awk` | journal-tail parser used by `coordinate.sh` (ASCII-anchored; ignores the Unicode `·`/`→` separators) |
| `coordinate.config.example` | per-repo config (copy to `coordinate.config`): observer + CC/Pi/Codex clones, `BRANCH`, stage command prefixes, optional pane pins |
| `drive.defaults.example` | GLOBAL machine bindings (copy once to `~/.config/pipeline-driver/drive.defaults`): `CC/IMPL/REVIEW _AGENT` + `_MODEL_EXPECT` |
| `test/run.sh` | `parse-tail.awk` unit tests against a format-faithful sample journal |
| `test/coordinate-*.sh` | hermetic suites: parse-tail, config validation, doctor, status, remote identity, bounded-exec watchdog, bindings |
| `.pipeline/` | archived feature records (`drive-setup`, `herdr-transport`) — history, not current spec |

## Setup

1. Clone next to `pipeline/` as a read-only consumer: `git clone <this> ~/workspace/pipeline-driver`.
   Runs in place — no install step. Needs `git`, `jq`, `herdr`, `perl`.
2. Per repo: `cp coordinate.config.example coordinate.config` and fill it per its comments — one
   observer clone plus three role clones (`CC_WORKDIR`/`PI_WORKDIR`/`CODEX_WORKDIR`) that all
   resolve to the SAME normalized remote identity and trunk `BRANCH`, and the five stage command
   prefixes. Optional pins `CC_PANE_ID`/`PI_PANE_ID`/`CODEX_PANE_ID` override pane discovery.
   Every value is validated before use; command prefixes are data appended to a safely-built
   argv, never `eval`'d.
3. Optional, one-time per machine: `mkdir -p ~/.config/pipeline-driver && cp drive.defaults.example
   ~/.config/pipeline-driver/drive.defaults` and set the machine bindings (override the path with
   `$DRIVE_DEFAULTS`). Sourced first; `coordinate.config` wins on conflict. The file name is
   inherited from the retired drive.sh (tag `archive/drive-final`) and kept so existing installs keep working.
4. Verify: `for t in test/run.sh test/coordinate-*.sh; do bash "$t" || echo "FAIL $t"; done` — all must pass.
5. `./coordinate.sh doctor --config coordinate.config` — expect `doctor: 0 blocking`.

## Update

Read-only consumer clone, no build step — one guarded pull. Tracked files must be clean
(untracked `coordinate.config` is normal). `--ff-only` refuses a diverged history; on refusal
inspect by hand — **never reset, never stash blindly.**

```bash
git -C ~/workspace/pipeline-driver status --porcelain --untracked-files=no | grep -q . \
  && { echo "local edits to tracked files — inspect before updating" >&2; exit 1; }
git -C ~/workspace/pipeline-driver pull --ff-only
```

Then re-run §Setup steps 4–5. The `pipeline-*` shims update on their own track
(pipeline repo's `pipeline-update`, pipeline README §Update).

## `doctor --config <path>`

Read-only full preflight. Checks dependencies (git/jq/herdr/perl), validates the whole config,
confirms the four clones share one normalized remote identity and are all on `BRANCH`, performs
**one** `git fetch` in the observer clone (the bounded-exec guard wraps the two `herdr` reads —
`agent explain` and `pane list`), and — when an active coordinated feature is observed — parses
`control.json` and the journal tail. It resolves each role pane via `herdr pane list` (self pane
**excluded**, distinct panes required) and proves lifecycle/manifest **authority** for each (the
always-idle fallback is rejected). It installs nothing and never mutates target-repo state — the
single fetch DOES update the observer clone's remote-tracking refs / `FETCH_HEAD` (a local
side effect, not a target-repo write). Every MISS prints the §14 tuple (code / where / input /
reason / next_action). A completed run ends with `doctor: N blocking, M warning(s)` (non-zero
exit on any blocking MISS); a malformed config (e.g. `BRANCH` unset) can abort earlier with a
fatal error.

## `status --config <path>`

**No network.** Validates the config, reads the observer's `HEAD:.pipeline/current.json`, and
prints **exactly one** human line plus one compact JSON object: `coordinate: feature=<slug> (from
HEAD current.json)` + `{"feature":"<slug>"}`, or `coordinate: idle (no active feature)` +
`{"feature":null}`. A malformed slug is rejected with `CONFIG_INVALID` (it can never traverse a
`git show` path or inject output). The machine-bindings block goes to stderr so stdout keeps its
one-line + one-object contract.

## Machine bindings

Both commands print the merged `drive.defaults` → `coordinate.config` view of the optional
`CC/IMPL/REVIEW _AGENT` + `_MODEL_EXPECT` fields (which TUI drives each role pane, and the model
expected in its footer). With a `*_MODEL_EXPECT` set, `doctor` **fail-closed-verifies** it as a
literal case-insensitive substring of that pane's live footer (`MODEL_MISMATCH` otherwise) —
three roles on three models becomes a machine check. `IMPL_TRANSPORT` / `YOLO` are echoed if set,
informational only.

## Archived: drive.sh

`drive.sh` was an optional, deterministic bash driver that auto-advanced the `pipeline-impl`
multi-card loop unattended between GATE 1 (spec-rev read) and the `NEXT=review` halt, with
`claude` (headless) and `herdr` (driven TUI) impl transports, a merge speed-bump hook, a
trunk-clobber preflight, `drive.sh doctor`, board auto-refresh and a walk-away notify hook.

- **Retired 2026-09-24** (last real use 2026-07-22). Superseded by coordinated mode: the
  `pipeline-coordinate` playbook dispatches the role panes, and `coordinate.sh` is its preflight.
  The pipeline repo dropped drive mode from its docs in jackypanster/pipeline PR #80.
- **Full tree preserved at tag `archive/drive-final`**: `git checkout archive/drive-final`
  (drive.sh, stop-points.md, clobber-guard.sh, deny-merge.sh, settings.driver.json,
  drive.config.example, and their test suites).
- Kept from that era: `parse-tail.awk` (coordinate.sh uses it), the `drive.defaults` file
  name/path (coordinate.sh reads its bindings), and the `.pipeline/` feature records.
