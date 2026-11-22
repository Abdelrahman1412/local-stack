#!/usr/bin/env bash
# Runs every tests/test_*.sh file. Exit status is non-zero if any assertion failed.
set -u
cd "$(dirname "$0")" || exit 1
status=0
for f in test_*.sh; do
  printf '== %s\n' "$f"
  bash "$f" || status=1
done
exit $status
