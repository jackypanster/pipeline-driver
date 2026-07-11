#!/usr/bin/env bash
# Hermetic tests for the global-defaults layer + `drive.sh doctor`.
# No network, no real HOME/XDG reads (DRIVE_DEFAULTS pins the defaults path),
# stripped PATH plays "dep not installed" (macOS keeps git/awk/sed in /usr/bin;
# everything brew-installed — jq/gh/node/claude/orca — disappears).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

# --- 1. the defaults file is sourced (bogus transport set ONLY there halts preflight)
cat > "$TMP/defaults1" <<EOF
WORKDIR=$TMP
BRANCH=main
FEATURE=f
IMPL_TRANSPORT=bogus-from-defaults
EOF
: > "$TMP/empty.config"
out=$(DRIVE_DEFAULTS="$TMP/defaults1" bash "$DRIVE" "$TMP/empty.config" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q "bogus-from-defaults" <<<"$out"; then ok "defaults file is sourced"
else bad "defaults file is sourced (rc=$rc)" "$out"; fi

# --- 2. per-feature drive.config wins over the defaults
printf 'IMPL_TRANSPORT=bogus-from-config\n' > "$TMP/win.config"
out=$(DRIVE_DEFAULTS="$TMP/defaults1" bash "$DRIVE" "$TMP/win.config" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q "bogus-from-config" <<<"$out"; then ok "drive.config wins over defaults"
else bad "drive.config wins over defaults (rc=$rc)" "$out"; fi

# --- 3. no defaults file at all: behavior unchanged (missing config still exit 2)
out=$(DRIVE_DEFAULTS="$TMP/nope" bash "$DRIVE" "$TMP/no-such.config" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q "config not found" <<<"$out"; then ok "absent defaults file = today's behavior"
else bad "absent defaults file (rc=$rc)" "$out"; fi

# --- 4. doctor on a bare machine: MISSes + remediation + exit 1
cat > "$TMP/defaults2" <<EOF
PIPELINE_REPO=$TMP/no-pipeline
DASHBOARD_REPO=$TMP/no-dashboard
SKILLS_DIR=$TMP/no-skills
EOF
out=$(DRIVE_DEFAULTS="$TMP/defaults2" PATH=/usr/bin:/bin bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1); rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "claude not on PATH" <<<"$out" \
   && grep -q "pipeline repo not found" <<<"$out" \
   && grep -q "dashboard repo not found" <<<"$out" \
   && grep -q "pipeline-impl shim not in" <<<"$out" \
   && grep -q "fix: git clone https://github.com/jackypanster/pipeline.git" <<<"$out"; then
  ok "doctor: bare machine -> MISSes with exact remediation, exit 1"
else bad "doctor bare machine (rc=$rc)" "$out"; fi

# --- 5. doctor on a healthy (stubbed) machine: exit 0, warnings only allowed
mkdir -p "$TMP/skills/pipeline-impl" "$TMP/pipeline/.git" "$TMP/dashboard/.git" "$TMP/dashboard/dist" "$TMP/bin"
: > "$TMP/dashboard/dist/cli.js"
for t in claude jq gh node orca; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
cat > "$TMP/defaults3" <<EOF
PIPELINE_REPO=$TMP/pipeline
DASHBOARD_REPO=$TMP/dashboard
SKILLS_DIR=$TMP/skills
YOLO=1
EOF
out=$(DRIVE_DEFAULTS="$TMP/defaults3" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "0 blocking" <<<"$out" && grep -q "YOLO=1" <<<"$out"; then
  ok "doctor: healthy machine -> exit 0, YOLO status surfaced"
else bad "doctor healthy machine (rc=$rc)" "$out"; fi

# --- 6. doctor flags an unbuilt dashboard as blocking
rm "$TMP/dashboard/dist/cli.js"
out=$(DRIVE_DEFAULTS="$TMP/defaults3" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q "npm install && npm run build" <<<"$out"; then
  ok "doctor: unbuilt dashboard -> MISS with build command"
else bad "doctor unbuilt dashboard (rc=$rc)" "$out"; fi

# --- 7. drive.config.example stays minimal: active assignments are EXACTLY the trio
# (bulk-copying the example must not override the global defaults — review finding)
active=$(grep -E '^[A-Za-z_]+=' "$HERE/../drive.config.example" | cut -d= -f1 | sort | tr '\n' ' ')
if [ "$active" = "BRANCH FEATURE WORKDIR " ]; then ok "drive.config.example active keys == {WORKDIR,BRANCH,FEATURE}"
else bad "drive.config.example minimality" "active keys: $active"; fi

: > "$TMP/dashboard/dist/cli.js"   # restore what test 6 removed; tests below want a healthy base

# --- 8. doctor: invalid IMPL_TRANSPORT is a MISS, not a false-green claude check
cat > "$TMP/defaults4" <<EOF
PIPELINE_REPO=$TMP/pipeline
DASHBOARD_REPO=$TMP/dashboard
SKILLS_DIR=$TMP/skills
IMPL_TRANSPORT=warp-drive
EOF
out=$(DRIVE_DEFAULTS="$TMP/defaults4" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q "unknown IMPL_TRANSPORT 'warp-drive'" <<<"$out"; then
  ok "doctor: invalid transport -> MISS, exit 1"
else bad "doctor invalid transport (rc=$rc)" "$out"; fi

# --- 9. doctor: config file present but a required key unset -> MISS naming it
printf 'WORKDIR=%s\nBRANCH=main\n' "$TMP" > "$TMP/incomplete.config"   # FEATURE missing
out=$(DRIVE_DEFAULTS="$TMP/defaults3" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/incomplete.config" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q "required setting(s) unset.* FEATURE" <<<"$out"; then
  ok "doctor: incomplete config -> MISS names FEATURE"
else bad "doctor incomplete config (rc=$rc)" "$out"; fi

# --- 10. doctor: git WORKDIR without roles.yaml must NOT abort mid-report (was rc=2)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMP/target" && git init -q "$TMP/target" && mkdir -p "$TMP/target/.pipeline"
: > "$TMP/target/.pipeline/current.json"
printf 'WORKDIR=%s/target\nBRANCH=main\nFEATURE=f\n' "$TMP" > "$TMP/target.config"
out=$(DRIVE_DEFAULTS="$TMP/defaults3" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/target.config" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "no .pipeline/roles.yaml" <<<"$out" && grep -q "doctor: 0 blocking" <<<"$out"; then
  ok "doctor: missing roles.yaml -> warn + full summary (no early exit)"
else bad "doctor missing roles.yaml (rc=$rc)" "$out"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
