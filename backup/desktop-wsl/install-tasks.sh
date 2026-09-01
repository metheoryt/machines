#!/bin/bash
# Installs desktop-wsl's restic client schedule from the profiles.yaml next to
# this file.
#
# NO SUDO, deliberately -- the mirror image of ../latitude/install-tasks.sh.
# This client's profile is `schedule-permission: user`, so the units belong to
# THIS user's systemd manager. Running it as root would install them into the
# system manager, where they would run as root, read the wrong password path,
# and leave the user timer that actually backs this box up uninstalled.
#
# The user manager must be lingering or the timer dies with the last login
# shell: `sudo loginctl enable-linger "$USER"`. Checked by
# provision/roles/backup-client.sh, not here.
#
# Prerequisite: the restic REST server on latitude (the `vps` repo's
# homeserver/restic-server/compose.yml -- services live there, machines here).
# The repository is created ONCE, by hand, and never by a scheduled run:
#   resticprofile -n wsl init
# `initialize` is opt-in per profile precisely so an unmounted drive on the
# server side cannot fabricate a fresh zero-history repo. See ../base.yaml.
set -e
cd "$(dirname "$0")"
resticprofile schedule --all
