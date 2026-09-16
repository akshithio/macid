#!/bin/bash
#
# repair-pam.sh — restore PAM stacks that reference a module file that no
# longer exists.
#
# On macOS a stack that lists a missing module fails to initialize entirely,
# `optional` line or not. That is how an earlier MacID build broke sudo: it
# deleted the old pam_faceprobe.so while four stacks still referenced it.
#
#   repair-pam.sh --dry-run    report only, needs no privileges
#   repair-pam.sh              repair, needs root
#
set -uo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

if (( ! DRY )) && [[ $EUID -ne 0 ]]; then
	echo "needs root (or pass --dry-run)" >&2
	exit 1
fi

PAMD=/etc/pam.d
# Only these are ever restored from backup. screensaver_new is deliberately
# absent: it carries the live MacID line, and it is not broken.
CANDIDATES=(sudo authorization screensaver_la screensaver)
LEGACY='pam_faceprobe|pam_face\.so'

# Absolute module paths referenced by a stack that do not exist on disk.
missing_modules() {
	awk '$1 ~ /^(auth|account|password|session)$/ && $3 ~ /^\// { print $3 }' "$1" \
		| while read -r mod; do [[ -e "$mod" ]] || echo "$mod"