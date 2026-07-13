# Review 03 — changes requested

PR: `#9` (`feat/drive-setup`)
Review tip: `a76f838d3d12259aeb763f2a1022a5a14ee0d7e3`
Base: `main`

## Gates

- Freeze gate: PASS — `git diff a0148cdc359192b64a68aaebce7ca5d2e205bc8c
  a76f838d3d12259aeb763f2a1022a5a14ee0d7e3 -- test/setup-plumbing.sh
  test/setup-defaults.sh test/setup-pboard.sh test/setup-target.sh test/setup-safety.sh`
  was empty.
- Card guard: PASS — cards 01–04 were all `status: review` on `origin/main`.
- Full verify: PASS from an isolated archive of the PR head — `bash -n drive.sh` and the exact
  `current.json.full-verify` suite passed (11/29/7/6/10/15/7/34/3/4/3/4/5).
- CI: CodeRabbit reported success at the reviewed head.
- Scope cut: PASS — the executable external installer bodies and runtime picker removed by ADR
  0004 are absent. Remaining name references are comments documenting the cut.
- Semantic verdict: CHANGES REQUESTED. The narrowed core still violates its explicit EOF and
  no-symlink-write guarantees, despite the frozen tests and full suite being green.

## Findings

1. **HIGH — interactive EOF/cancel still writes defaults and exits successfully.**
   `drive.sh:340-351` captures every `ask_*` result with command substitution. Bash runs those
   helpers in subshells, so their `setup_abort=1` assignments at `drive.sh:204`, `:217`, and `:233`
   never reach `setup()`'s local at `drive.sh:427`. The fzf path at `drive.sh:228-229` separately
   swallows cancellation and selects the default. A real-PTY probe supplied all answers except the
   final one, sent Ctrl-D at `TUI skills dir`, and observed exit 0 plus a newly created
   `drive.defaults`. Make prompt failure/cancel propagate in the parent shell, stop the current step
   before writing, and return non-zero; add a real PTY regression that would fail on this head.

2. **HIGH — the backup path bypasses the target symlink guard and overwrites outside the repo.**
   `drive.sh:403-414` checks `.pipeline` and `roles.yaml`, but not `roles.yaml.bak`. With a regular
   stale `roles.yaml` and `roles.yaml.bak -> ../../victim`, `cp "$rf" "$rf.bak"` followed the link,
   replaced the external victim with the stale roles content, and setup exited 0. Refuse or safely
   replace every backup destination without following links, and freeze this exact escape. The
   sibling backup/write path at `drive.sh:378-379` also follows a symlinked `drive.defaults` or
   `drive.defaults.bak`; apply the same no-follow policy to every generated artifact, not only the
   final roles path.

3. **MEDIUM — `_atomic_write` opens a predictable, non-exclusive temporary path.**
   `drive.sh:250-258` constructs `.setup-aw.$$.${RANDOM}.tmp` and writes it with ordinary shell
   redirection. In a destination directory writable by another process/user, a pre-created temp
   symlink redirects `cat > "$tmp"` before the final-destination guards run. Use an exclusive
   same-directory temp creation primitive such as `mktemp`, verify a regular temp, clean it on all
   failures/signals, and fail closed if metadata copy or rename fails.

## Required disposition

Card 01 owns the shared setup safety helpers and is already at `attempts: 2`. This semantic rejection
increments it to 3, so it must become `blocked` and route to `pipeline-hunt`, not another blind impl
retry. Hunt should address the common design fault across all three artifact writers: stateful prompt
helpers cannot communicate through command substitutions, and the write transaction protects only
the final destination while leaving backup/temp paths as symlink-following sinks.
