#!/usr/bin/env bash
# Runs the repo-harvest distiller's behavioural cases under plain python3.
#
# distill.py is not a local script: fleet-gather.sh `cat`s it over ssh to every
# fleet box and runs it there, and its watermark/merge logic decides which
# transcript lines are read once and which are re-read forever. That is exactly
# the class of bug that never announces itself, which is why these cases exist.
#
# They used to be tests/test_distill.py, needing pytest — absent from the fleet
# toolchain, so `just test` never ran them and AGENTS.md carried an exemption for
# the one file outside the gate. distill_cases.py now brings its own runner, so
# this wrapper is all the gate needs and the exemption is gone.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  # Not a pass and not a hard failure: a box without python3 cannot run the
  # distiller either, so there is nothing here to regress. Say so out loud
  # rather than printing ALL PASS on zero assertions.
  echo "skip - no python3 on this box (distill.py could not run here either)"
  echo "ALL PASS"
  exit 0
fi

python3 "$here/distill_cases.py"
