#!/usr/bin/env bash
# clobber-guard.sh — decide whether a trunk is fully protected against CLOBBER.
#
# Reads a GitHub `repos/{owner}/{repo}/rules/branches/<branch>` JSON array on stdin
# (the effective rules, which reflect both classic branch protection and rulesets).
# Exit 0 if trunk is fully clobber-protected — BOTH a `non_fast_forward` rule (blocks
# force-push) AND a `deletion` rule (blocks branch deletion) are present. Exit 1
# otherwise (no rules / only one of the two / 403 on a free-plan private repo → empty).
#
# This is the trunk-CLOBBER hardening check only; it has nothing to do with the
# feature-PR merge gate (that is the driver halting before review + a human merge —
# see README §Merge safety). drive.sh pipes the gh output here and warns on exit 1.

rules=$(cat)
printf '%s' "$rules" | grep -q 'non_fast_forward' \
  && printf '%s' "$rules" | grep -q '"deletion"'
