#!/bin/bash
# Installs latitude's restic schedules from the profiles.yaml next to this file.
#
# SUDO IS LOAD-BEARING, and it is the only reason this script exists separately
# from desktop-wsl's. Both of latitude's profiles declare
# `schedule-permission: system`, so resticprofile writes into
# /etc/systemd/system and must be root; desktop-wsl's client is user-scope and
# must NOT be root, or its units land in the wrong manager. The scope decision
# lives next to the config that declares it rather than being re-derived by the
# role executor.
#
# ONE invocation covers BOTH profiles: `schedule --all` ignores `-n` and
# schedules every profile in the config. That is four units here --
# backup@profile-latitude, check@profile-latitude,
# forget@profile-g614jv-maintenance, check@profile-g614jv-maintenance.
#
# Prerequisite: /mnt/spare320 mounted and both repositories present. The
# profiles' own `run-before` assertions enforce that at RUN time; nothing
# enforces it at SCHEDULE time, and nothing needs to -- scheduling writes units,
# it does not touch a repo.
set -e
cd "$(dirname "$0")"
sudo resticprofile schedule --all
