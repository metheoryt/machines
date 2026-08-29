#!/bin/bash
# Prerequisites: restic REST server must be running on server (homeserver/restic-server/compose.yml).
# Initialize the repo if it doesn't exist yet:
#   resticprofile -n wsl init
set -e
cd "$(dirname "$0")"
resticprofile schedule --all
