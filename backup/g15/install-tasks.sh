#!/bin/bash
# Installs g15's restic client schedule from the profiles.yaml next to this file.
#
# NO SUDO, like ../g16-wsl/install-tasks.sh and unlike ../latitude's. The
# `g15` profile is `schedule-permission: user_logged_on`, so its units belong to
# THIS user's systemd manager. Running this as root would put them in the system
# manager, where they would run as root, read the wrong password path, and leave
# the user timer that actually backs this box up uninstalled.
#
# The user manager must be lingering or the timer dies with the last login
# shell: `sudo loginctl enable-linger "$USER"`. It is `yes` on g15 today, and
# provision/roles/backup-client.sh warns when it is not — this script does not
# re-check it.
#
# ~/.local/bin IS ON PATH HERE ON PURPOSE. resticprofile is installed there
# rather than in /usr/local/bin, because ../restic-install.sh installs it with
# sudo and g15 has no NOPASSWD sudo — the same reason tier_gortex puts gortex in
# ~/.local/bin. A non-interactive ssh shell does not have that directory on
# PATH, which is how a provision run driven over ssh would otherwise fail to
# find a binary that is plainly installed.
#
# Prerequisite: the restic REST server on latitude (the `vps` repo's
# homeserver/restic-server stack — services live there, machines here) with an
# htpasswd user for this box: `docker exec -i restic-server sh -c
# 'htpasswd -iB /data/.htpasswd g513ie'`. The repository is then created ONCE,
# by hand, and never by a scheduled run:
#   resticprofile -n g15 init
# `initialize` is opt-in per profile precisely so an unmounted drive on the
# server side cannot fabricate a fresh zero-history repo. See ../base.yaml.
# ONE INVOCATION IS ENOUGH ONLY WHILE EVERY PROFILE HERE IS USER-SCOPE.
# `schedule --all` ignores `-n` and schedules every profile in the config at
# whatever privilege it was started with, so the day a
# `schedule-permission: system` profile is added here — the qaz-code PGDATA leg
# is the one waiting on a drive — this line stops being correct. resticprofile
# refuses a system job from an unprivileged process ("user is not allowed to
# create a system job: please restart resticprofile as root"), and running the
# whole thing under sudo would put the USER profile's units in the system
# manager, where they run as root and read the wrong password path. Split it
# into `resticprofile -n g15 schedule` plus a sudo'd `-n <db-profile> schedule`
# at that point, and note that g15 has no NOPASSWD sudo.
set -e
export PATH="$PATH:$HOME/.local/bin"
cd "$(dirname "$0")"
resticprofile schedule --all
