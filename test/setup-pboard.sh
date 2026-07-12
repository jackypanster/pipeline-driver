#!/usr/bin/env bash
# FROZEN red test — card C3 (pboard block): `drive.sh setup` writes the `pboard`
# shell function into the rc file inside a marker-delimited block, idempotently,
# owning ONLY its own markers (ADR 0003). Hermetic: SETUP_SHELL_RC pins the rc
# file. RED until setup() exists.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

RC="$TMP/zshrc"
run() {
  env HOME="$TMP" SETUP_SHELL_RC="$RC" SETUP_YES=1 \
    SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 \
    SETUP_DO_PBOARD=1 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=0 \
    PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
}
opens() { grep -c '>>> pipeline pboard >>>' "$RC" 2>/dev/null || echo 0; }

# --- 1. fresh rc file: exactly one marker pair, with a pboard() function inside.
run
if [ "$(opens)" = 1 ] \
   && [ "$(grep -c '<<< pipeline pboard <<<' "$RC")" = 1 ] \
   && grep -qE 'pboard *\(\)' "$RC"; then
  ok "pboard block written once, with the function inside its markers"
else bad "pboard fresh write" "$(cat "$RC" 2>&1)"; fi

# --- 2. idempotent: run twice -> still exactly ONE marker pair (no duplication).
run; run
if [ "$(opens)" = 1 ]; then
  ok "pboard block idempotent across re-runs (exactly one block)"
else bad "pboard idempotency (blocks=$(opens))" "$(cat "$RC" 2>&1)"; fi

# --- 3. setup owns only its markers: a pre-existing UNMARKED pboard is left untouched.
printf 'legacy_untouched_pboard() { echo hi; }\n' > "$RC"
run
if grep -q 'legacy_untouched_pboard' "$RC" && [ "$(opens)" = 1 ]; then
  ok "unmarked legacy line preserved; setup adds only its own marked block"
else bad "legacy preservation" "$(cat "$RC" 2>&1)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
