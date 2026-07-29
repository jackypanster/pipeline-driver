#!/usr/bin/env bash
# Hermetic tests for `drive.sh doctor`:
#   - SKILL_MOUNTS sweep: the six entry forms in the handoff table (symlink ok,
#     symlink wrong target, dangling symlink, real-dir match, real-dir drift,
#     absent-from-mount), plus self-mount-skip and the SKILL_MOUNTS-unset info skip.
#   - dashboard dist/cli.js freshness: stale vs. up to date.
# No network, no real HOME/XDG reads (DRIVE_DEFAULTS pins the config path), and
# every mount tree is built under mktemp — this NEVER reads ~/.codex/skills or
# ~/.agents/skills. Pattern follows test/defaults-doctor.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

# --- shared healthy stubs: canonical SKILLS_DIR + a built, FRESH dashboard + deps
CANON="$TMP/canon"
mkdir -p "$CANON/pipeline-impl" "$CANON/pipeline-review" "$CANON/pipeline-prd"
printf -- '---\nname: pipeline-impl\n---\nimpl body\n'   > "$CANON/pipeline-impl/SKILL.md"
printf -- '---\nname: pipeline-review\n---\nreview body\n' > "$CANON/pipeline-review/SKILL.md"
printf -- '---\nname: pipeline-prd\n---\nprd body\n'      > "$CANON/pipeline-prd/SKILL.md"
mkdir -p "$TMP/pipeline/.git"
mkdir -p "$TMP/dashboard/.git" "$TMP/dashboard/src" "$TMP/dashboard/dist"
: > "$TMP/dashboard/src/cli.ts"
: > "$TMP/dashboard/package.json"
: > "$TMP/dashboard/tsconfig.json"
sleep 1                                   # guarantee dist is strictly NEWER than sources
: > "$TMP/dashboard/dist/cli.js"          # baseline = fresh; tests touch sources to stale it
mkdir -p "$TMP/bin"
for t in claude jq gh node herdr; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done

# Base defaults (every test appends SKILL_MOUNTS as needed). $TMP/$CANON expand now.
cat > "$TMP/base.defaults" <<EOF
PIPELINE_REPO=$TMP/pipeline
DASHBOARD_REPO=$TMP/dashboard
SKILLS_DIR=$CANON
EOF
run() { DRIVE_DEFAULTS="$1" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1; }
# macOS keeps the real tmp under /private/var; pwd -P exposes that, and doctor
# compares PHYSICAL paths (correctly). Assert against the resolved path, not $TMP.
CANON_PHYS=$(cd "$CANON" && pwd -P)
defaults_with_mounts() {   # <mounts-value> -> writes $TMP/cfg.defaults and prints its path
  cat > "$TMP/cfg.defaults" <<EOF
$(cat "$TMP/base.defaults")
SKILL_MOUNTS=$1
EOF
  printf '%s\n' "$TMP/cfg.defaults"
}

# --- form 1: symlink -> canonical (absolute target) = ok, exit 0 -------------------
M1="$TMP/m1"; mkdir -p "$M1"
ln -s "$CANON/pipeline-impl" "$M1/pipeline-impl"
out=$(run "$(defaults_with_mounts "$M1")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M1 -> " <<<"$out" \
   && grep -qF "$CANON/pipeline-impl" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "form 1: symlink (abs target) -> canonical = ok"
else bad "form 1 symlink abs (rc=$rc)" "$out"; fi

# --- form 1b: symlink -> canonical (RELATIVE target) also compares equal ---------
# ~/.claude/skills uses ../../.agents/... — physical-path equality must catch both.
M1R="$TMP/m1r"; mkdir -p "$M1R"
( cd "$M1R" && ln -s "../../$(basename "$TMP")/canon/pipeline-impl" pipeline-impl )
out=$(run "$(defaults_with_mounts "$M1R")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M1R -> " <<<"$out"; then
  ok "form 1b: symlink (relative target) -> canonical compares EQUAL (pwd -P)"
else bad "form 1b symlink rel (rc=$rc)" "$out"; fi

# --- form 2: symlink -> somewhere ELSE = blocking + pasteable ln -s fix -----------
M2="$TMP/m2"; mkdir -p "$M2/decoy/pipeline-review" "$M2"
ln -s "$M2/decoy/pipeline-review" "$M2/pipeline-review"
out=$(run "$(defaults_with_mounts "$M2")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-review in $M2 -> " <<<"$out" \
   && grep -qF "(expected $CANON_PHYS/pipeline-review)" <<<"$out" \
   && grep -qF "fix: rm $M2/pipeline-review && ln -s $CANON/pipeline-review $M2/pipeline-review" <<<"$out"; then
  ok "form 2: symlink wrong target -> MISS names target + pasteable fix"
else bad "form 2 symlink wrong (rc=$rc)" "$out"; fi

# --- form 3: dangling symlink = blocking, reports readlink target ----------------
M3="$TMP/m3"; mkdir -p "$M3"
ln -s "$TMP/no-such-target" "$M3/pipeline-review"
out=$(run "$(defaults_with_mounts "$M3")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "dangling symlink: $M3/pipeline-review -> $TMP/no-such-target" <<<"$out" \
   && grep -qF "fix: rm $M3/pipeline-review && ln -s $CANON/pipeline-review $M3/pipeline-review" <<<"$out"; then
  ok "form 3: dangling symlink -> MISS names stored target"
else bad "form 3 dangling (rc=$rc)" "$out"; fi

# --- form 4: real dir, diff -rq identical = ok ----------------------------------
M4="$TMP/m4"; mkdir -p "$M4"
cp -r "$CANON/pipeline-impl" "$M4/pipeline-impl"
out=$(run "$(defaults_with_mounts "$M4")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M4 matches $CANON/pipeline-impl" <<<"$out"; then
  ok "form 4: real dir identical = ok"
else bad "form 4 real dir match (rc=$rc)" "$out"; fi

# --- form 5: real dir, content DRIFTED = blocking (THE incident form) ------------
M5="$TMP/m5"; mkdir -p "$M5"
cp -r "$CANON/pipeline-review" "$M5/pipeline-review"
printf 'STALE — pre-#57, no size-budget axis\n' > "$M5/pipeline-review/SKILL.md"
out=$(run "$(defaults_with_mounts "$M5")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-review in $M5 differs from $CANON/pipeline-review (stale copy)" <<<"$out" \
   && grep -qF "fix: rm -rf $M5/pipeline-review && ln -s $CANON/pipeline-review $M5/pipeline-review" <<<"$out"; then
  ok "form 5: real dir drift -> MISS (the codex/pipeline-review incident form)"
else bad "form 5 real dir drift (rc=$rc)" "$out"; fi

# --- form 6: a skill ABSENT from a mount is NOT flagged (minimal runtime ok) -----
# Canonical has impl+review+prd; this mount carries ONLY pipeline-impl. Doctor must
# say nothing about pipeline-review / pipeline-prd and report 0 blocking.
M6="$TMP/m6"; mkdir -p "$M6"
ln -s "$CANON/pipeline-impl" "$M6/pipeline-impl"
out=$(run "$(defaults_with_mounts "$M6")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M6 -> " <<<"$out" \
   && ! grep -q "pipeline-review in $M6" <<<"$out" \
   && ! grep -q "pipeline-prd in $M6" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "form 6: absent skills not flagged (a runtime need not carry every skill)"
else bad "form 6 absent (rc=$rc)" "$out"; fi

# --- self-mount skip: a mount resolving to $SKILLS_DIR is skipped (it IS canonical)
out=$(run "$(defaults_with_mounts "$CANON")"); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "real dir" <<<"$out" && ! grep -q "in $CANON -> " <<<"$out"; then
  ok "self-mount: a mount == \$SKILLS_DIR is skipped (canonical is the reference)"
else bad "self-mount skip (rc=$rc)" "$out"; fi

# --- SKILL_MOUNTS unset = info line, NEVER blocking ------------------------------
out=$(run "$TMP/base.defaults"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "SKILL_MOUNTS unset" <<<"$out" \
   && grep -q "runtime mount sweep skipped" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "SKILL_MOUNTS unset -> info skip, 0 blocking (existing installs stay green)"
else bad "SKILL_MOUNTS unset (rc=$rc)" "$out"; fi

# --- declared mount not found = warn (not blocking); dangling mount = blocking ----
MN="$TMP/nope-missing"
out=$(run "$(defaults_with_mounts "$MN")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "declared SKILL_MOUNTS dir not found: $MN" <<<"$out"; then
  ok "missing mount dir -> warn (not blocking)"
else bad "missing mount dir (rc=$rc)" "$out"; fi

MD="$TMP/dangling-mount"
ln -s "$TMP/gone" "$MD"
out=$(run "$(defaults_with_mounts "$MD")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "declared SKILL_MOUNTS entry is a dangling symlink: $MD -> $TMP/gone" <<<"$out"; then
  ok "dangling mount dir -> MISS"
else bad "dangling mount dir (rc=$rc)" "$out"; fi

# --- dashboard freshness: STALE source -> warn + npm run build -------------------
touch "$TMP/dashboard/src/cli.ts"        # a tracked source is now newer than dist
out=$(run "$TMP/base.defaults"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "dashboard dist/cli.js is stale" <<<"$out" \
   && grep -qF "(cd $TMP/dashboard && npm run build)" <<<"$out"; then
  ok "dashboard stale -> warn (not blocking) + build command"
else bad "dashboard stale (rc=$rc)" "$out"; fi

# --- dashboard freshness: rebuilt -> ok ------------------------------------------
: > "$TMP/dashboard/dist/cli.js"; sleep 1; : > "$TMP/dashboard/dist/cli.js"  # dist strictly newest
out=$(run "$TMP/base.defaults"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "dashboard dist/cli.js is up to date" <<<"$out" \
   && ! grep -q "dashboard dist/cli.js is stale" <<<"$out"; then
  ok "dashboard rebuilt -> up to date"
else bad "dashboard fresh (rc=$rc)" "$out"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
