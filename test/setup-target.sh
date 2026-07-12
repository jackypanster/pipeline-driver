#!/usr/bin/env bash
# FROZEN red test — card C4 (target repo init): `drive.sh setup` writes a target
# repo's .pipeline/roles.yaml from the pipeline repo's template, rewriting the impl
# slot to the real installed name and keeping the file tool-agnostic (CONTRACT
# invariant), with .bak-on-change. Hermetic: SETUP_PIPELINE_REPO / SETUP_TARGET_REPO
# pin both ends. RED until setup() exists.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVE="$HERE/../drive.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "$2"; }

# a fake pipeline repo whose roles.yaml still carries the placeholder impl slot
mkdir -p "$TMP/pipeline" "$TMP/repo"
cat > "$TMP/pipeline/roles.yaml" <<'YML'
prd:    [grill-me, think]
arch:   grill-with-docs
task:   think
impl:   <autonomous-coding-skill>
review: check
YML
RF="$TMP/repo/.pipeline/roles.yaml"
run() {
  env HOME="$TMP" SETUP_YES=1 SETUP_PIPELINE_REPO="$TMP/pipeline" \
    SETUP_DO_DEPS=0 SETUP_DO_SOURCES=0 SETUP_DO_SKILLS=0 SETUP_DO_DASHBOARD=0 \
    SETUP_DO_PBOARD=0 SETUP_DO_DEFAULTS=0 SETUP_DO_TARGET=1 SETUP_TARGET_REPO="$TMP/repo" \
    SETUP_DO_DOCTOR=0 PATH="/usr/bin:/bin" bash "$DRIVE" setup >/dev/null 2>&1
}

# --- 1. roles.yaml created; impl slot rewritten to the real name; no placeholder left.
run
if [ -f "$RF" ] \
   && grep -qE '^impl:[[:space:]]+goal-driven-implementation' "$RF" \
   && ! grep -q 'autonomous-coding-skill' "$RF"; then
  ok "target roles.yaml: impl slot = goal-driven-implementation, placeholder gone"
else bad "target roles.yaml generation" "$(cat "$RF" 2>&1)"; fi

# --- 2. tool-agnostic: no runtime/LLM name leaks onto any slot binding (contract invariant).
if [ -f "$RF" ] && ! grep -qiE '^(prd|arch|task|impl|review|hunt|improve):.*(claude|codex|grok|gpt|opus|sonnet|haiku|glm)' "$RF"; then
  ok "roles.yaml stays tool-agnostic (no runtime/LLM name on any slot)"
else bad "roles.yaml tool-agnosticism" "$(cat "$RF" 2>&1)"; fi

# --- 3. .bak-on-change: an existing target roles.yaml is backed up before overwrite.
mkdir -p "$TMP/repo/.pipeline"; printf 'impl:   stale-old-binding\n' > "$RF"
run
if grep -qE '^impl:[[:space:]]+goal-driven-implementation' "$RF" \
   && [ -f "$RF.bak" ] && grep -q 'stale-old-binding' "$RF.bak"; then
  ok "existing roles.yaml backed up to .bak before overwrite"
else bad "target roles.yaml backup" "$(cat "$RF" "$RF.bak" 2>&1)"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
