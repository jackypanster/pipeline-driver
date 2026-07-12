# Review 01 — changes requested

PR: `#9` (`feat/drive-setup`)
Review tip: `4fe87f8e7f51b8a9f1a7876c86e32b62d34017d8`
Base: `main`

## Gates

- Freeze gate: PASS — `git diff 4ac12ec905adab2da59666447e8a264245fc3cd3
  4fe87f8e7f51b8a9f1a7876c86e32b62d34017d8 -- test/setup-plumbing.sh
  test/setup-defaults.sh test/setup-pboard.sh test/setup-target.sh` was empty.
- Card guard: PASS — cards 01–04 were all `status: review` at review start.
- Full verify: PASS on the detached PR head — `bash -n drive.sh` and the exact
  `current.json.full-verify` suite passed (11/29/7/6/10/15/7/34/3/4/3/3).
- Semantic verdict: CHANGES REQUESTED. The green tests do not cover several required and
  safety-critical paths below.

## Findings

1. **P1 — required installer steps are no-op stubs.** `drive.sh:245-248` defines
   `setup_preflight`, `setup_sources`, `setup_skills`, and `setup_dashboard_build` as `:`.
   On a fresh machine, enabling these steps prints four headings, performs no install or
   remediation, and exits 0 when doctor is disabled. This is incomplete against PRD Scope
   steps 1–4a and README's claim that setup is the automated one-time checklist. Implement
   the dep/remediation, source, skill attachment, and dashboard build/link flows, or call
   `s_miss` for work that cannot be automated.

2. **P1 — generated defaults serialize input as executable, unescaped shell.**
   `drive.sh:301-315` interpolates `SETUP_*` values directly into a file sourced at
   `drive.sh:84`. A `BOARD_OUT` containing spaces made the next source attempt to execute
   `with`; a newline in `REVIEW_TERMINAL_TITLE` injected a new assignment. A quote in
   `REVIEW_SLASH_CMD` can break out of its single quotes and execute a command. Serialize
   every value with robust shell quoting (or use a non-executable format/parser), validate
   enumerated fields, and freeze regressions for spaces, quotes, and newlines.

3. **P1 — an unmatched pboard opening marker deletes user content through EOF.**
   `drive.sh:257-258` commits a sed range deletion even when no closing marker exists. A
   probe with an unmatched opening marker removed the following `keep-after` line, with no
   backup. Validate a balanced, unique marker pair and refuse/back up malformed state; build
   the complete replacement before atomically installing it.

4. **P1 — rewriting the shell rc widens its permissions.** `drive.sh:257-258` creates a new
   temp file under the process umask and moves it over the rc. A mode-0600 rc became 0644,
   potentially exposing secrets to other local users. Preserve the original mode and other
   practical metadata when replacing an existing file.

5. **P1 — prompt failures silently accept defaults and mutate files.**
   `drive.sh:198-200,210-212,225-227` turns `read` failure/EOF into the default answer.
   With stdin redirected from `/dev/null` and no `SETUP_YES`, setup exited 0 and wrote both
   `.zshrc` and `drive.defaults`. The system Bash 3.2 also rejects `read -i`, and that error
   is swallowed into the same mutation path. Require a TTY unless `--yes` is explicit, do
   not interpret prompt errors as consent, and use a Bash-3.2-compatible prompt or declare
   and enforce a newer Bash runtime.

6. **P2 — the documented dependency-step toggle does not control the code.** README
   `:211-214` and all setup tests use `SETUP_DO_DEPS`, while `drive.sh:361` checks
   `SETUP_DO_PREFLIGHT`. The documented dry run therefore still runs preflight. Pick one
   public key (the frozen architecture says `DO_DEPS`) and use it consistently.

## Required disposition

The existing frozen tests are too narrow to prevent the unsafe behaviors above, and no card
owns implementation of PRD steps 1–4a. Re-route to `pipeline-task`: extend/re-freeze the
feature spec (shared `spec-rev`) and assign the missing external-step implementation plus
regressions for quoting, malformed markers, metadata preservation, and non-TTY/Bash behavior.
Card 01 is the named retry target because it owns setup orchestration and the public README;
its implementation may continue only after the re-freeze is recorded and the feature branch
is rebased onto the advanced trunk spec.
