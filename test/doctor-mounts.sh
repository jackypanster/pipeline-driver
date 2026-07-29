#!/usr/bin/env bash
# Hermetic tests for `drive.sh doctor`:
#   - SKILL_MOUNTS sweep: the six entry forms (symlink ok, symlink wrong target,
#     dangling symlink, real-dir match, real-dir drift, absent-from-mount), plus
#     self-mount-skip.
#   - F1 (review round 1): SKILL_MOUNTS unset = BLOCKING; `none` opt-out; entries
#     must be ABSOLUTE.
#   - F2 (review round 1): every "cannot verify" state is a MISS — diff stderr/
#     rc>=2, entry with no canonical counterpart, unreadable/searchless mount. The
#     reverse rule (skill absent from a readable mount is NOT flagged) is locked.
#   - F3 (review round 1): a hostile IFS=_ in the sourced defaults cannot split a
#     valid underscored path into bogus entries.
#   - dashboard dist/cli.js freshness: stale vs. up to date.
# No network, no real HOME/XDG reads (DRIVE_DEFAULTS pins the config path), and
# every mount tree is built under mktemp — this NEVER reads ~/.codex or ~/.agents.
# Pattern follows test/defaults-doctor.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
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

# Base defaults: NO SKILL_MOUNTS (so the F1 "unset" case can use it directly).
cat > "$TMP/base.defaults" <<EOF
PIPELINE_REPO=$TMP/pipeline
DASHBOARD_REPO=$TMP/dashboard
SKILLS_DIR=$CANON
EOF
run() { DRIVE_DEFAULTS="$1" PATH="$TMP/bin:/usr/bin:/bin" bash "$DRIVE" doctor "$TMP/no-such.config" 2>&1; }
# macOS keeps the real tmp under /private/var; pwd -P exposes that, and doctor
# compares PHYSICAL paths (correctly). Assert against the resolved path, not $TMP.
CANON_PHYS=$(cd "$CANON" && pwd -P)
# Write a fresh $TMP/cfg.defaults = base + one extra line, print its path.
cfg() { printf '%s\n%s\n' "$(cat "$TMP/base.defaults")" "$1" > "$TMP/cfg.defaults"; printf '%s\n' "$TMP/cfg.defaults"; }

# --- form 1: symlink -> canonical (absolute target) = ok, exit 0 -------------------
M1="$TMP/m1"; mkdir -p "$M1"
ln -s "$CANON/pipeline-impl" "$M1/pipeline-impl"
out=$(run "$(cfg "SKILL_MOUNTS=$M1")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M1 -> " <<<"$out" \
   && grep -qF "$CANON/pipeline-impl" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "form 1: symlink (abs target) -> canonical = ok"
else bad "form 1 symlink abs (rc=$rc)" "$out"; fi

# --- form 1b: symlink -> canonical (RELATIVE target) also compares equal ---------
M1R="$TMP/m1r"; mkdir -p "$M1R"
( cd "$M1R" && ln -s "../../$(basename "$TMP")/canon/pipeline-impl" pipeline-impl )
out=$(run "$(cfg "SKILL_MOUNTS=$M1R")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M1R -> " <<<"$out"; then
  ok "form 1b: symlink (relative target) -> canonical compares EQUAL (pwd -P)"
else bad "form 1b symlink rel (rc=$rc)" "$out"; fi

# --- form 2: symlink -> somewhere ELSE = blocking + pasteable ln -s fix -----------
M2="$TMP/m2"; mkdir -p "$M2/decoy/pipeline-review" "$M2"
ln -s "$M2/decoy/pipeline-review" "$M2/pipeline-review"
out=$(run "$(cfg "SKILL_MOUNTS=$M2")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-review in $M2 -> " <<<"$out" \
   && grep -qF "(expected $CANON_PHYS/pipeline-review)" <<<"$out" \
   && grep -qF "fix: rm $M2/pipeline-review && ln -s $CANON/pipeline-review $M2/pipeline-review" <<<"$out"; then
  ok "form 2: symlink wrong target -> MISS names target + pasteable fix"
else bad "form 2 symlink wrong (rc=$rc)" "$out"; fi

# --- form 3: dangling symlink = blocking, reports readlink target ----------------
M3="$TMP/m3"; mkdir -p "$M3"
ln -s "$TMP/no-such-target" "$M3/pipeline-review"
out=$(run "$(cfg "SKILL_MOUNTS=$M3")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "dangling symlink: $M3/pipeline-review -> $TMP/no-such-target" <<<"$out" \
   && grep -qF "fix: rm $M3/pipeline-review && ln -s $CANON/pipeline-review $M3/pipeline-review" <<<"$out"; then
  ok "form 3: dangling symlink -> MISS names stored target"
else bad "form 3 dangling (rc=$rc)" "$out"; fi

# --- form 4: real dir, diff -rq identical = ok ----------------------------------
M4="$TMP/m4"; mkdir -p "$M4"
cp -r "$CANON/pipeline-impl" "$M4/pipeline-impl"
out=$(run "$(cfg "SKILL_MOUNTS=$M4")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M4 matches $CANON/pipeline-impl" <<<"$out"; then
  ok "form 4: real dir identical = ok"
else bad "form 4 real dir match (rc=$rc)" "$out"; fi

# --- form 5: real dir, content DRIFTED = blocking (THE incident form) ------------
M5="$TMP/m5"; mkdir -p "$M5"
cp -r "$CANON/pipeline-review" "$M5/pipeline-review"
printf 'STALE — pre-#57, no size-budget axis\n' > "$M5/pipeline-review/SKILL.md"
out=$(run "$(cfg "SKILL_MOUNTS=$M5")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-review in $M5 differs from $CANON/pipeline-review (stale copy)" <<<"$out" \
   && grep -qF "fix: rm -rf $M5/pipeline-review && ln -s $CANON/pipeline-review $M5/pipeline-review" <<<"$out"; then
  ok "form 5: real dir drift -> MISS (the codex/pipeline-review incident form)"
else bad "form 5 real dir drift (rc=$rc)" "$out"; fi

# --- form 6: a skill ABSENT from a readable mount is NOT flagged -----------------
# Canonical has impl+review+prd; this mount carries ONLY pipeline-impl. Doctor must
# say nothing about pipeline-review / pipeline-prd and report 0 blocking. (Reverse
# lock for F2.2: absent-in-mount != present-but-no-canonical.)
M6="$TMP/m6"; mkdir -p "$M6"
ln -s "$CANON/pipeline-impl" "$M6/pipeline-impl"
out=$(run "$(cfg "SKILL_MOUNTS=$M6")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "pipeline-impl in $M6 -> " <<<"$out" \
   && ! grep -q "pipeline-review in $M6" <<<"$out" \
   && ! grep -q "pipeline-prd in $M6" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "form 6: absent skills not flagged (reverse lock for F2.2)"
else bad "form 6 absent (rc=$rc)" "$out"; fi

# --- self-mount skip: a mount resolving to $SKILLS_DIR is skipped ----------------
out=$(run "$(cfg "SKILL_MOUNTS=$CANON")"); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "real dir" <<<"$out" && ! grep -q "in $CANON -> " <<<"$out"; then
  ok "self-mount: a mount == \$SKILLS_DIR is skipped (canonical is the reference)"
else bad "self-mount skip (rc=$rc)" "$out"; fi

# === F1: inventory is required ==================================================
# F1a: unset -> BLOCKING (was info-skip; the review's headline fail-open).
out=$(run "$TMP/base.defaults"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "MISS  SKILL_MOUNTS unset" <<<"$out" \
   && grep -qF "SKILL_MOUNTS=none" <<<"$out"; then
  ok "F1a: SKILL_MOUNTS unset -> >=1 blocking (was 0 on 50a2b04)"
else bad "F1a unset blocking (rc=$rc)" "$out"; fi

# F1b: literal `none` opt-out -> info, 0 blocking.
out=$(run "$(cfg "SKILL_MOUNTS=none")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "info  SKILL_MOUNTS=none — explicit opt-out" <<<"$out" \
   && ! grep -q "dir not found: none" <<<"$out" && grep -q "0 blocking" <<<"$out"; then
  ok "F1b: SKILL_MOUNTS=none -> info opt-out, 0 blocking"
else bad "F1b none opt-out (rc=$rc)" "$out"; fi

# F1c: a non-absolute entry -> BLOCKING (was a silent 'missing dir' warn).
out=$(run "$(cfg "SKILL_MOUNTS=some/relative/path")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "SKILL_MOUNTS entry must be an absolute path: some/relative/path" <<<"$out"; then
  ok "F1c: non-absolute entry -> blocking"
else bad "F1c non-absolute (rc=$rc)" "$out"; fi

# === F2: unverifiable states fail CLOSED ========================================
# F2.1: diff -rq emits stderr / rc>=2 (unreadable file inside a real-dir entry).
M_DIFF="$TMP/m_diff"; mkdir -p "$M_DIFF/pipeline-review"
cp "$CANON/pipeline-review/SKILL.md" "$M_DIFF/pipeline-review/SKILL.md"
chmod 000 "$M_DIFF/pipeline-review/SKILL.md"
out=$(run "$(cfg "SKILL_MOUNTS=$M_DIFF")"); rc=$?
chmod 644 "$M_DIFF/pipeline-review/SKILL.md"     # restore so the EXIT trap can rm
if [ "$rc" -eq 1 ] && grep -q "cannot trust diff for pipeline-review in $M_DIFF" <<<"$out" \
   && grep -q "unverifiable is not verified" <<<"$out"; then
  ok "F2.1: diff trouble -> MISS (was d_warn, 0 blocking on 50a2b04)"
else bad "F2.1 diff trouble (rc=$rc)" "$out"; fi

# F2.2: entry present in the mount but NO canonical counterpart -> MISS.
M_NC="$TMP/m_nocanon"; mkdir -p "$M_NC/pipeline-hunt"
printf -- '---\nname: pipeline-hunt\n---\nhunt\n' > "$M_NC/pipeline-hunt/SKILL.md"
out=$(run "$(cfg "SKILL_MOUNTS=$M_NC")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-hunt in $M_NC has no canonical $CANON/pipeline-hunt to compare against" <<<"$out"; then
  ok "F2.2: entry without canonical -> MISS (was d_info, 0 blocking on 50a2b04)"
else bad "F2.2 no canonical (rc=$rc)" "$out"; fi

# F2.3: unreadable / searchless mount -> MISS (glob left literal, silently skipped).
M_UNR="$TMP/m_unread"; mkdir -p "$M_UNR/pipeline-review"
printf 'STALE\n' > "$M_UNR/pipeline-review/SKILL.md"   # trapped — never enumerated
chmod 000 "$M_UNR"
out=$(run "$(cfg "SKILL_MOUNTS=$M_UNR")"); rc=$?
chmod 755 "$M_UNR"                               # restore so the EXIT trap can rm
if [ "$rc" -eq 1 ] && grep -q "declared mount not searchable: $M_UNR" <<<"$out"; then
  ok "F2.3: unreadable mount -> MISS (was silent 0 blocking on 50a2b04)"
else bad "F2.3 unreadable mount (rc=$rc)" "$out"; fi

# === F3: IFS inheritance ========================================================
# drive.defaults sets IFS=_ then declares an UNDERSCORED path that is genuinely
# stale. Old head split it into "/.../my" + "mount" (two missing-dir warns), never
# scanned the real mount -> 0 blocking. New head binds a local whitespace IFS.
M_US="$TMP/my_mount"; mkdir -p "$M_US/pipeline-review"
printf 'STALE\n' > "$M_US/pipeline-review/SKILL.md"
out=$(run "$(cfg $'IFS=_\nSKILL_MOUNTS='"$M_US")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "pipeline-review in $M_US differs from $CANON/pipeline-review (stale copy)" <<<"$out" \
   && ! grep -q "dir not found: $TMP/my" <<<"$out"; then
  ok "F3: IFS=_ cannot split an underscored stale mount (was 0 blocking on 50a2b04)"
else bad "F3 IFS=_ (rc=$rc)" "$out"; fi

# --- declared mount not found = warn (not blocking); dangling mount = blocking ----
MN="$TMP/nope-missing"
out=$(run "$(cfg "SKILL_MOUNTS=$MN")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "declared SKILL_MOUNTS dir not found: $MN" <<<"$out"; then
  ok "missing mount dir -> warn (not blocking)"
else bad "missing mount dir (rc=$rc)" "$out"; fi

MD="$TMP/dangling-mount"
ln -s "$TMP/gone" "$MD"
out=$(run "$(cfg "SKILL_MOUNTS=$MD")"); rc=$?
if [ "$rc" -eq 1 ] && grep -q "declared SKILL_MOUNTS entry is a dangling symlink: $MD -> $TMP/gone" <<<"$out"; then
  ok "dangling mount dir -> MISS"
else bad "dangling mount dir (rc=$rc)" "$out"; fi

# === dashboard freshness (uses SKILL_MOUNTS=none so the F1 block stays quiet) =====
touch "$TMP/dashboard/src/cli.ts"        # a tracked source is now newer than dist
out=$(run "$(cfg "SKILL_MOUNTS=none")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "dashboard dist/cli.js is stale" <<<"$out" \
   && grep -qF "(cd $TMP/dashboard && npm run build)" <<<"$out"; then
  ok "dashboard stale -> warn (not blocking) + build command"
else bad "dashboard stale (rc=$rc)" "$out"; fi

: > "$TMP/dashboard/dist/cli.js"; sleep 1; : > "$TMP/dashboard/dist/cli.js"  # dist strictly newest
out=$(run "$(cfg "SKILL_MOUNTS=none")"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "dashboard dist/cli.js is up to date" <<<"$out" \
   && ! grep -q "dashboard dist/cli.js is stale" <<<"$out"; then
  ok "dashboard rebuilt -> up to date"
else bad "dashboard fresh (rc=$rc)" "$out"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
