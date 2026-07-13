# Review 02 — changes requested

PR: `#9` (`feat/drive-setup`)
Review tip: `0e474f3f65fd84b953706b93c0a8a266f6b09a24`
Base: `main`

## Gates

- Freeze gate: PASS — `git diff 59ad1d8069f0f75f258b30e93ff1e6cf473515f4
  0e474f3f65fd84b953706b93c0a8a266f6b09a24 -- test/setup-plumbing.sh
  test/setup-defaults.sh test/setup-pboard.sh test/setup-target.sh test/setup-safety.sh
  test/setup-external.sh` was empty.
- Card guard: PASS — cards 01–05 were all `status: review` on `origin/main`.
- Full verify: PASS on a detached PR-head worktree — `bash -n drive.sh` and the exact
  `current.json.full-verify` suite passed (11/29/7/6/10/15/7/34/3/4/3/3/4/4).
- CI: CodeRabbit reported success at the reviewed head.
- Semantic verdict: CHANGES REQUESTED. Review-read safety and installed-runtime paths still
  contain merge blockers that the frozen tests do not exercise.

## Prior review status

Review-01's basic serialization, unmatched-single-marker, normal 0600-mode, non-TTY,
`SETUP_DO_DEPS`, and no-op-step cases are fixed and their new frozen tests pass. The findings
below are narrower malformed-state, partial-failure, and real-install-path failures exposed by
the required semantic/safety-sink review.

## Findings

1. **HIGH — malformed-but-count-balanced pboard markers still delete user content.**
   `drive.sh:365-372` validates only equal opener/closer counts. A file ordered as closer,
   user content, opener, user content passes the guard; the awk filter enters the final opener
   with no later closer and deletes everything after it. A direct probe confirmed
   `keep-after-danger` disappeared while setup exited 0. Require exactly one correctly ordered
   pair (or validate every non-overlapping pair) and refuse/backup every malformed layout.

2. **HIGH — target initialization follows repository-controlled symlinks outside the repo.**
   `drive.sh:481-490` checks and writes `$target/.pipeline/roles.yaml` through normal `-f`,
   `cat`, `cp`, and redirection operations. A target repository containing
   `.pipeline/roles.yaml -> ../../victim` caused setup to replace the external victim file and
   exit 0. Reject symlinks in the destination chain, resolve the destination under the selected
   target, and atomically install a regular file without following links.

3. **HIGH — a failed dashboard build still runs the global link step.** `drive.sh:350-354`
   records `npm ci && npm run build` failure with `s_miss` but then continues into `npm link`.
   A stubbed probe logged `npm ci` returning 1 followed by `npm link`, so a stale/broken build
   can be exposed globally. Return/skip link after build failure; link only the successfully
   built output.

4. **HIGH — runtime attachment silently nests links inside existing real directories.**
   `drive.sh:328-331` assumes `ln -sfn` replaces any destination. When a runtime already has a
   real `pipeline-impl/` directory, `ln` succeeds by creating
   `pipeline-impl/pipeline-impl -> canonical/pipeline-impl`; the top-level registration remains
   the stale directory and setup exits 0. Detect directories/non-canonical links and refuse or
   migrate them with an explicit backup; then verify each installed runtime resolves the intended
   top-level symlink.

5. **MEDIUM — interactive prompt EOF is still treated as consent.**
   `drive.sh:203-244` uses `read ... || true` and fzf fallbacks that select defaults. In a real
   PTY, Ctrl-D at the prompts still generated `drive.defaults` and exited 0. Distinguish explicit
   empty Enter (accept default) from EOF/error/cancel, abort before later mutations, and return
   non-zero on prompt failure.

6. **MEDIUM — the shell rc replacement is not failure-atomic.** `drive.sh:377-395` preserves
   mode by truncating the live rc and writing the replacement into the same inode. A signal,
   process death, ENOSPC, or write error after `> "$rc"` leaves a partial rc with no rollback.
   Render and sync a same-directory temporary file, copy the original metadata, then atomically
   rename; retain a recoverable backup when replacement cannot complete.

7. **MEDIUM — the documented interactive runtime selection and grok path are absent.**
   `drive.sh:237-247` defines `ask_multi` but no caller uses it; `drive.sh:316-323` reads only an
   externally supplied `SETUP_RUNTIMES`, so an interactive run never offers the PRD-required fzf
   runtime picker. Supplying the documented `grok` runtime is classified as unknown and exits 1,
   despite ADR 0003 requiring grok's impl-only attachment. Route runtime selection through the
   ask seam and implement the documented grok behavior.

8. **LOW — the public run-all command omits the re-frozen safety suites.** `README.md:194`
   says all tests must pass but lists neither `test/setup-safety.sh` nor
   `test/setup-external.sh`, while `current.json.full-verify` correctly includes both. Update the
   public command so users exercise the same safety gate as review.

## Required disposition

The current frozen tests cannot catch the malformed-order, symlink, partial-build, existing-dir,
or PTY-cancel failures. Re-route to `pipeline-task` to re-freeze the whole feature, explicitly
extending `test/setup-safety.sh`, `test/setup-target.sh`, and `test/setup-external.sh` (and the
README run-all contract). Card 01 is the named retry target because it owns the cross-cutting
setup safety helpers and README; preserve cards 02–05 until the new shared spec is recorded.
