## seq=8 · 2026-06-23T07:56:31Z · impl→impl · failed · by=codex/gpt-5
done:   card 03 attempt 2 failed.
output: .pipeline/stats-report/tasks/03.md
--- handoff ---
>>> NEXT
Run pipeline-impl on the Hermes coder profile (goal-driven-implementation), FRESH session.
On failure: attempts++; >=3 ⇒ blocked ⇒ run pipeline-hunt.
<<< END

## seq=9 · 2026-06-23T08:05:00Z · impl→hunt · blocked · by=codex/gpt-5
done:   card 03 attempt 3 failed — attempts>=3, card blocked. Root-cause before any re-queue.
output: .pipeline/stats-report/tasks/03.md
--- handoff ---
>>> NEXT
Run pipeline-hunt on a FRESH session (assume you know nothing — rebuild from the repo + CONTRACT.md).
repo=https://github.com/acme/hello-cli.git branch=main target=tasks/03.md
On failure: confirm cause before proposing any fix.
<<< END
