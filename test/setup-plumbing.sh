#!/usr/bin/env bash
# FROZEN red test — card C1 (plumbing): `drive.sh setup` subcommand dispatch,
# headless mode, and `doctor` as the terminal success signal (ADR 0002).
# Hermetic: temp HOME/XDG, DRIVE_DEFAULTS pinned, stubbed PATH, no network, no fzf.
# Mold: test/defaults-doctor.sh. RED until pipeline-impl adds setup() to drive.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

# every wizard step OFF — the shared headless prefix
OFF="SETUP_YES=1 SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 \
SETUP_DO_DASHBOARD=0 SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=0"

# a healthy stubbed machine (mirrors defaults-doctor.sh test 5; git stays real via /usr/bin)
mkdir -p "$TMP/skills/pipeline-impl" "$TMP/pipeline/.git" "$TMP/dashboard/.git" "$TMP/dashboard/dist" "$TMP/bin"
: > "$TMP/dashboard/dist/cli.js"
for t in claude jq gh node orca; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
cat > "$TMP/healthy" <<EOF
PIPELINE_REPO=$TMP/pipeline
DASHBOARD_REPO=$TMP/dashboard
SKILLS_DIR=$TMP/skills
EOF
cat > "$TMP/bare" <<EOF
PIPELINE_REPO=$TMP/no-pipeline
DASHBOARD_REPO=$TMP/no-dashboard
SKILLS_DIR=$TMP/no-skills
EOF

# --- 1. `setup` is a recognized subcommand: headless, all steps off, doctor off -> exit 0, never
#        the missing-config death (proves setup is dispatched, not parsed as a config path arg).
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/healthy" $OFF SETUP_DO_DOCTOR=0 \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "config not found" <<<"$out"; then
  ok "setup is a recognized subcommand (headless no-op exits 0)"
else bad "setup subcommand dispatch (rc=$rc)" "$out"; fi

# --- 2. doctor is the terminal step: healthy machine, all steps off, doctor on -> exit 0 + summary.
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/healthy" $OFF SETUP_DO_DOCTOR=1 \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "doctor:" <<<"$out"; then
  ok "setup ends on doctor (healthy -> exit 0, summary printed)"
else bad "setup doctor terminal healthy (rc=$rc)" "$out"; fi

# --- 3. honest-degrade: bare machine, doctor on -> setup exits non-zero (never green when doctor blocks).
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/bare" $OFF SETUP_DO_DOCTOR=1 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q "fix:" <<<"$out"; then
  ok "setup honest-degrade (bare -> exit 1 with remediation, doctor is ground truth)"
else bad "setup honest-degrade (rc=$rc)" "$out"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
