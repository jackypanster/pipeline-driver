#!/usr/bin/env bash
# FROZEN red test — new card C5 (re-spec after reviews/review-01.md): the four external
# installer steps (preflight/deps, sources, skills-attach, dashboard) must ACT, not be
# no-op stubs (PRD Scope steps 1–4a). Hermetic: real work is asserted via honest-degrade
# remediation + the canonical skills copy — no network, no package manager. Also pins the
# public toggle name to SETUP_DO_DEPS (finding 6). RED against the stubbed PR #9 head.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="${DRIVE:-$HERE/../drive.sh}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }
ONLY() { # step-name : all steps off except the named one
  printf 'SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=0'
}

# --- 1a. preflight (SETUP_DO_DEPS=1) on a stripped PATH: missing deps -> remediation + non-zero.
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/none" SETUP_YES=1 $(ONLY) SETUP_DO_DEPS=1 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
# --- 1b. SETUP_DO_DEPS=0 must actually disable the step (finding 6: code checked DO_PREFLIGHT).
out0=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/none" SETUP_YES=1 $(ONLY) SETUP_DO_DEPS=0 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup 2>&1)
if grep -q 'fix:' <<<"$out" && [ "$rc" -ne 0 ] && ! grep -qi 'preflight\|--- deps' <<<"$out0"; then
  ok "preflight checks deps + honest-degrades, and SETUP_DO_DEPS actually gates it"
else bad "preflight/DEPS toggle" "rc=$rc"$'\n'"DEPS=1:"$'\n'"$out"$'\n'"DEPS=0:"$'\n'"$out0"; fi

# --- 2. skills step populates the canonical SKILLS_DIR from the pipeline repo (not a no-op).
mkdir -p "$TMP/srcpipe/skills/pipeline-impl" "$TMP/srcpipe/skills/pipeline-prd"
SK="$TMP/agents-skills"
env HOME="$TMP" DRIVE_DEFAULTS="$TMP/none" SETUP_YES=1 $(ONLY) SETUP_DO_SKILLS=1 \
  SETUP_PIPELINE_REPO="$TMP/srcpipe" SETUP_SKILLS_DIR="$SK" SETUP_RUNTIMES='' \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
if [ -e "$SK/pipeline-impl" ] && [ -e "$SK/pipeline-prd" ]; then
  ok "skills step installs pipeline-* into the canonical SKILLS_DIR"
else bad "skills attach is a no-op" "$(ls -la "$SK" 2>&1)"; fi

# --- 3. sources step honest-degrades on a MISSING source repo (remediation, not silent 0).
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/none" SETUP_YES=1 $(ONLY) SETUP_DO_SOURCES=1 \
  SETUP_PIPELINE_REPO="$TMP/no-pipe" SETUP_DASHBOARD_REPO="$TMP/no-dash" SETUP_REFRESH_SOURCES=0 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
if grep -q 'fix:' <<<"$out" && [ "$rc" -ne 0 ]; then
  ok "sources step honest-degrades on a missing source repo"
else bad "sources is a no-op" "rc=$rc"$'\n'"$out"; fi

# --- 4. dashboard step honest-degrades when the repo is absent/unbuilt (remediation, not silent 0).
out=$(env HOME="$TMP" DRIVE_DEFAULTS="$TMP/none" SETUP_YES=1 $(ONLY) SETUP_DO_DASHBOARD=1 \
  SETUP_DASHBOARD_REPO="$TMP/no-dash" \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup 2>&1); rc=$?
if grep -q 'fix:' <<<"$out" && [ "$rc" -ne 0 ]; then
  ok "dashboard step honest-degrades when repo/npm absent"
else bad "dashboard is a no-op" "rc=$rc"$'\n'"$out"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
