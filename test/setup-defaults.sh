#!/usr/bin/env bash
# FROZEN red test — card C2 (defaults gen + the ask_* / headless seam):
# `drive.sh setup` generates ~/.config/pipeline-driver/drive.defaults from SETUP_*,
# idempotently, with .bak-on-change-only (ADR 0003). Hermetic: DRIVE_DEFAULTS pins
# the output path (same seam test/defaults-doctor.sh uses). RED until setup() exists.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

DD="$TMP/pd/drive.defaults"   # note: parent dir does NOT exist — setup must mkdir -p it
run() { # extra SETUP_* as KEY=VAL args; writes to $DD
  env HOME="$TMP" DRIVE_DEFAULTS="$DD" \
    SETUP_YES=1 SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 \
    SETUP_DO_DASHBOARD=0 SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=1 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=0 \
    PATH="/usr/bin:/bin" "$@" bash "$DRIVE" setup >/dev/null 2>&1
}

# --- 1. chosen SETUP_* values land in the generated file; codex slash-cmd stays single-quoted.
run SETUP_IMPL_TRANSPORT=orca SETUP_YOLO=1 SETUP_REVIEW_TERMINAL_TITLE=codex
if [ -f "$DD" ] \
   && grep -q "^IMPL_TRANSPORT=orca" "$DD" \
   && grep -q "^YOLO=1" "$DD" \
   && grep -q "^REVIEW_TERMINAL_TITLE=codex" "$DD" \
   && grep -qF "REVIEW_SLASH_CMD='\$pipeline-review'" "$DD"; then
  ok "drive.defaults carries the chosen SETUP_* values (codex cmd single-quoted)"
else bad "drive.defaults generation" "$(cat "$DD" 2>&1)"; fi

# --- 2. idempotent: two identical runs -> byte-identical, and NO backup is ever made.
run SETUP_IMPL_TRANSPORT=orca SETUP_YOLO=1; cp "$DD" "$TMP/first"
run SETUP_IMPL_TRANSPORT=orca SETUP_YOLO=1
if cmp -s "$DD" "$TMP/first" && [ ! -e "$DD.bak" ]; then
  ok "idempotent re-run: identical output, no .bak churn"
else bad "idempotency" "diff/backup unexpected"; fi

# --- 3. overwrite-on-change: a changed value backs up the prior file to .bak, writes the new.
run SETUP_YOLO=0
run SETUP_YOLO=1
if grep -q "^YOLO=1" "$DD" && [ -f "$DD.bak" ] && grep -q "^YOLO=0" "$DD.bak"; then
  ok "changed value -> .bak holds the prior version, file holds the new"
else bad "overwrite backup" "$(cat "$DD" "$DD.bak" 2>&1)"; fi

# --- 4. the ask_* seam: SETUP_* override beats the default (default YOLO=0, override YOLO=1).
run;             grep -q "^YOLO=0" "$DD" && d1=1 || d1=0
run SETUP_YOLO=1; grep -q "^YOLO=1" "$DD" && d2=1 || d2=0
if [ "$d1" = 1 ] && [ "$d2" = 1 ]; then
  ok "ask_* seam: env override wins, default applies when unset"
else bad "ask_* seam (default=$d1 override=$d2)" "$(cat "$DD" 2>&1)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
