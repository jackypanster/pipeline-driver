#!/usr/bin/env bash
# FROZEN red test — card C1 hardening (re-spec after reviews/review-01.md).
# The safety-critical paths codex's semantic review found and the old happy-path
# suite never probed: config-injection, pboard marker EOF-deletion, rc-mode widening,
# and non-TTY silent-default. Hermetic (temp HOME, DRIVE_DEFAULTS/SETUP_SHELL_RC pins,
# stubbed PATH, no network). RED against the reviewed setup() at PR #9 head; green when
# impl serializes safely, validates markers, preserves mode, and refuses non-TTY writes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="${DRIVE:-$HERE/../drive.sh}"   # DRIVE override lets a reviewer point at a branch's drive.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }
OFF="SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=0"

# --- 1. hostile SETUP_* values must NOT inject/execute when the generated file is sourced.
DD="$TMP/pd/drive.defaults"
env HOME="$TMP" DRIVE_DEFAULTS="$DD" SETUP_YES=1 $OFF SETUP_DO_DEFAULTS=1 \
  SETUP_BOARD_OUT='/tmp/board with space.html' \
  SETUP_REVIEW_TERMINAL_TITLE=$'codex\nINJECTED_ASSIGN=pwned' \
  SETUP_REVIEW_SLASH_CMD="x'; INJECTED_CMD=pwned; :'" \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
probe=$( unset INJECTED_ASSIGN INJECTED_CMD BOARD_OUT
         . "$DD" 2>/dev/null
         printf 'BOARD_OUT=[%s]|IA=[%s]|IC=[%s]' "${BOARD_OUT:-}" "${INJECTED_ASSIGN:-}" "${INJECTED_CMD:-}" )
if [ -f "$DD" ] \
   && printf '%s' "$probe" | grep -qF 'BOARD_OUT=[/tmp/board with space.html]' \
   && printf '%s' "$probe" | grep -qF 'IA=[]' \
   && printf '%s' "$probe" | grep -qF 'IC=[]'; then
  ok "generated defaults are injection-safe (space/newline/quote round-trip, no execution)"
else bad "config injection" "probe=$probe"$'\n'"file:"$'\n'"$(cat "$DD" 2>&1)"; fi

# --- 2. an UNMATCHED opening pboard marker must NOT sed-delete following user content.
RC="$TMP/zshrc"
printf '%s\n' 'keep-before' '# >>> pipeline pboard >>>' 'keep-after-DANGER' > "$RC"
env HOME="$TMP" SETUP_SHELL_RC="$RC" SETUP_YES=1 $OFF SETUP_DO_PBOARD=1 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
if grep -q 'keep-after-DANGER' "$RC"; then
  ok "unmatched pboard marker preserves following content (no delete-to-EOF)"
else bad "marker EOF deletion" "$(cat "$RC" 2>&1)"; fi

# --- 3. replacing the rc file must preserve its mode (0600 must not widen to 0644).
RC2="$TMP/zshrc2"; : > "$RC2"; chmod 600 "$RC2"
env HOME="$TMP" SETUP_SHELL_RC="$RC2" SETUP_YES=1 $OFF SETUP_DO_PBOARD=1 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
mode=$(stat -f '%Lp' "$RC2" 2>/dev/null || stat -c '%a' "$RC2" 2>/dev/null)
if [ "$mode" = "600" ]; then
  ok "rc file mode preserved (0600 stays 0600, no secret exposure)"
else bad "rc mode widening" "mode=$mode"; fi

# --- 4. non-TTY without --yes must REFUSE: no file written, non-zero exit (no silent default).
DD2="$TMP/pd2/drive.defaults"
env HOME="$TMP" DRIVE_DEFAULTS="$DD2" \
  SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 \
  SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=1 SETUP_DO_TARGET=0 SETUP_DO_DOCTOR=0 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup </dev/null >/dev/null 2>&1
rc4=$?
if [ ! -f "$DD2" ] && [ "$rc4" -ne 0 ]; then
  ok "non-TTY without --yes refuses (no write, non-zero exit — prompt error is not consent)"
else bad "non-TTY silent default" "rc=$rc4 file_exists=$([ -f "$DD2" ] && echo yes || echo no)"; fi

# --- 5. a COUNT-BALANCED but MIS-ORDERED marker layout (closer before opener) must NOT
#        delete trailing content (review-02 finding 1: equal-count validation is insufficient).
RC3="$TMP/zshrc3"
printf '%s\n' 'keep-head' '# <<< pipeline pboard <<<' 'keep-mid' '# >>> pipeline pboard >>>' 'keep-TAIL-DANGER' > "$RC3"
env HOME="$TMP" SETUP_SHELL_RC="$RC3" SETUP_YES=1 $OFF SETUP_DO_PBOARD=1 \
  PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
if grep -q 'keep-TAIL-DANGER' "$RC3"; then
  ok "mis-ordered (closer-before-opener) markers preserve trailing content (require one ORDERED pair)"
else bad "malformed marker ordering deletes content" "$(cat "$RC3" 2>&1)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
