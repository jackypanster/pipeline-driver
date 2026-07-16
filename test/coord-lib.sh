#!/usr/bin/env bash
# Shared helpers for the Phase 3 watch/resume test suites. Sourced (not run).
# Hermetic: local bare Git remotes, a stub `herdr` on PATH, a physical temp base
# (macOS /var symlink), and HERDR_* env dropped so the coordinator's self-pane
# capture does not collide with the stub. NO network; no test hooks in the CLI.
#
# Convention: each suite sets COORD to coordinate.sh and AWKX to parse-tail.awk,
# then `source`s this file. Helpers read $T (per-test subdir) set by `fresh`.

unset HERDR_PANE_ID HERDR_PANE_CWD_MATCH HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID 2>/dev/null || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
[ -n "${COORD:-}" ] || COORD="$(cd "$(dirname "$0")" && pwd)/../coordinate.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
N=0; fresh() { N=$((N+1)); T="$TMP/t$N"; }

# cl_bounded <budget_s> <cmd...>: run under a HARD external deadline, killing the
# whole process group at the deadline (returns 124 on timeout). A test that would
# otherwise hang proves nothing.
cl_bounded() {
  local budget=$1; shift
  perl -e '
    my $s = shift; my @c = @ARGV;
    my $p = fork(); die "fork: $!" unless defined $p;
    if (!$p) { setpgrp(0,0); exec @c or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $s; waitpid $p, 0; my $rc = $? >> 8; alarm 0;
    kill "KILL", -$p; exit $rc;
  ' "$budget" "$@"
}

# cl_seed_clones <root>: bare remote + 4 independent clones on main + baseline cfg.
cl_seed_clones() {
  local root=$1 c
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  for c in obs cc pi codex; do git clone -q "$root/origin.git" "$root/$c" >/dev/null 2>&1; done
  for c in obs cc pi codex; do git -C "$root/$c" symbolic-ref HEAD refs/heads/main; done
  cat > "$root/cfg" <<EOF
OBSERVER_WORKDIR=$root/obs
BRANCH=main
CC_WORKDIR=$root/cc
PI_WORKDIR=$root/pi
CODEX_WORKDIR=$root/codex
CC_ARCH_CMD=/pipeline-arch
CC_TASK_CMD=/pipeline-task
CC_HUNT_CMD=/pipeline-hunt
PI_IMPL_CMD=/skill:pipeline-impl
CODEX_REVIEW_CMD='\$pipeline-review'
POLL_SECS=1
PANE_READY_TIMEOUT_MS=5000
STAGE_TIMEOUT_SECS=60
STATE_DIR=$root/state
EOF
}

# cl_feature <root> <feature> <journal_fixture> [mode]: commits current.json +
# control.json (mode=coordinated default) + the journal fixture; pushes main.
cl_feature() {
  local root=$1 feat=$2 jfix=$3 mode=${4:-coordinated}
  ( cd "$root/obs"; git checkout -q -b main 2>/dev/null || git checkout -q main
    mkdir -p ".pipeline/$feat"
    printf '{"feature":"%s","stage":"impl"}' "$feat" > .pipeline/current.json
    printf '{"schema_version":1,"mode":"%s","merge_gate":"human-direct"}' "$mode" > ".pipeline/$feat/control.json"
    cp "$jfix" ".pipeline/$feat/journal.md"
    git add -A && git commit -qm seed && git push -q origin main ) >/dev/null 2>&1
}

# cl_commit_journal <root> <feature> <fixture>: replace the journal + push
# (simulates a stage agent advancing the journal between watch cycles).
cl_commit_journal() {
  local root=$1 feat=$2 jfix=$3
  ( cd "$root/obs"; cp "$jfix" ".pipeline/$feat/journal.md"
    git add -A && git commit -qm advance && git push -q origin main ) >/dev/null 2>&1
}

# cl_stub_herdr <root>: writes $root/bin/herdr + $root/list.json (3 panes). The
# stub is a QUOTED heredoc so no outer expansion mangles it; paths/state come via
# env (HERDR_STUB_LIST / HERDR_STUB_RUNS / HERDR_STUB_STATE / HERDR_STUB_NO_AUTH /
# HERDR_STUB_RUN_RC). pane run APPENDS the full argv and exits HERDR_STUB_RUN_RC.
cl_stub_herdr() {
  local root=$1
  mkdir -p "$root/bin"
  cat > "$root/bin/herdr" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pane list") cat "${HERDR_STUB_LIST:-/dev/null}" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "agent explain")
    st="${HERDR_STUB_STATE:-idle}"
    # optional stateful mode: HERDR_STUB_BUSY_N_FILE holds a countdown — while
    # positive, report "working" and decrement (lets a test hold the pane busy for
    # a bounded window, e.g. to advance the remote mid-decision).
    if [ -n "${HERDR_STUB_BUSY_N_FILE:-}" ] && [ -s "$HERDR_STUB_BUSY_N_FILE" ]; then
      n=$(cat "$HERDR_STUB_BUSY_N_FILE" 2>/dev/null || echo 0)
      if [ "$n" -gt 0 ] 2>/dev/null; then echo $((n-1)) > "$HERDR_STUB_BUSY_N_FILE"; st=working; fi
    fi
    # optional mode: report "working" once ANYTHING was typed (pane run recorded) —
    # models a stage that accepted the dispatch and keeps running, so watch stays
    # in WAITING without fatal or redelivery.
    if [ -n "${HERDR_STUB_WORKING_AFTER_RUN:-}" ] && [ -s "${HERDR_STUB_RUNS:-/dev/null}" ]; then
      st=working
    fi
    if [ -n "${HERDR_STUB_NO_AUTH:-}" ]; then
      printf '{"state":"%s","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":null,"fallback_reason":"default_known_agent_idle_fallback"}\n' "$st"
    else
      printf '{"state":"%s","matched_rule":null,"manifest_source":null,"screen_detection_skip_reason":"full_lifecycle_hook_authority","fallback_reason":null}\n' "$st"
    fi ;;
  "pane run") printf '%s\n' "$*" >> "${HERDR_STUB_RUNS:-/dev/null}"; exit "${HERDR_STUB_RUN_RC:-0}" ;;
  *) exit 0 ;;
esac
S
  chmod +x "$root/bin/herdr"
  cat > "$root/list.json" <<EOF
{"result":{"panes":[
  {"pane_id":"wA:p1","agent":"claude","agent_status":"idle","cwd":"$root/cc","foreground_cwd":"$root/cc"},
  {"pane_id":"wB:p1","agent":"pi","agent_status":"idle","cwd":"$root/pi","foreground_cwd":"$root/pi"},
  {"pane_id":"wC:p1","agent":"codex","agent_status":"idle","cwd":"$root/codex","foreground_cwd":"$root/codex"}
]}}
EOF
}

# cl_run_watch <root>: bounded watch run, stub herdr on PATH. There is NO cycle
# hook in the shipped CLI (a __bounded-run-class lesson): stub scenarios either
# self-terminate through a fatal (default stub state is idle, so a dispatched
# stage that never advances the journal fatals AGENT_ENDED_WITHOUT_HANDOFF), or
# the external deadline KILLs the run (rc 124) and the suite asserts on files.
# Override CL_WATCH_BUDGET / CL_WATCH_EXTRA (extra env) per case.
cl_run_watch() {
  local root=$1
  cl_bounded "${CL_WATCH_BUDGET:-10}" env \
      STATE_DIR="$root/state" HERDR_STUB_LIST="$root/list.json" HERDR_STUB_RUNS="$root/runs.txt" \
      PATH="$root/bin:/usr/bin:/bin" ${CL_WATCH_EXTRA:-} \
      bash "$COORD" watch --config "$root/cfg" 2>&1
}

# cl_spawn_watch <root>: start watch in the BACKGROUND (exec'd, so $! IS the
# coordinator); caller polls files then `kill -TERM $CL_WATCH_PID` and
# `wait $CL_WATCH_PID` for the graceful-stop path. Output goes to $root/watch.out.
CL_WATCH_PID=""
cl_spawn_watch() {
  local root=$1
  ( exec env STATE_DIR="$root/state" HERDR_STUB_LIST="$root/list.json" HERDR_STUB_RUNS="$root/runs.txt" \
        PATH="$root/bin:/usr/bin:/bin" ${CL_WATCH_EXTRA:-} \
        bash "$COORD" watch --config "$root/cfg" ) > "$root/watch.out" 2>&1 &
  CL_WATCH_PID=$!
}

# cl_mkjournal <file> <from> <to> <status> <next-line> [seq]: a format-faithful
# single-entry journal (· = \xc2\xb7, → = \xe2\x86\x92). Genesis from = ∅.
cl_mkjournal() {
  local f=$1 from=$2 to=$3 st=$4 next=$5 seq=${6:-1}
  printf '## seq=%s \xc2\xb7 2026-07-16T00:00:00Z \xc2\xb7 %s\xe2\x86\x92%s \xc2\xb7 %s \xc2\xb7 by=t\ndone: x\noutput: y\n--- handoff ---\n>>> NEXT\n%s\n<<< END\n' \
    "$seq" "$from" "$to" "$st" "$next" > "$f"
}
CL_GENESIS=$(printf '\xe2\x88\x85')   # ∅

# cl_card <root> <feat> <nn> <status> <attempts>: commit one task card (frontmatter
# only — cards_validate reads status/attempts mechanically).
cl_card() {
  ( cd "$1/obs"; mkdir -p ".pipeline/$2/tasks"
    printf -- '---\nstatus: %s\nattempts: %s\nverify: ["true"]\n---\ncard body\n' "$4" "$5" > ".pipeline/$2/tasks/$3.md"
    git add -A && git commit -qm "card $3" && git push -q origin main ) >/dev/null 2>&1
}

# cl_rkey_of <root>: the repo key coordinate.sh derives (from doctor output).
cl_rkey_of() {
  env PATH=/usr/bin:/bin bash "$COORD" doctor --config "$1/cfg" 2>/dev/null \
    | awk '/^ok    normalized repo key:/ {sub(/^ok    normalized repo key: /,""); print; exit}'
}
# cl_featdir <root> <feature>: the absolute feature state dir.
cl_featdir() { printf '%s/state/%s/%s' "$1" "$(cl_rkey_of "$1")" "$2"; }
