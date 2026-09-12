#!/usr/bin/env bash
# install-rest-server.sh — the village box's restic REST server.
#
# Idempotent; run as root. Installs a PINNED rest-server binary, its user, its
# htpasswd file and its systemd unit.
#
# THE BIND IS A WILDCARD AND THAT IS NOT AN OVERSIGHT. latitude tried binding its
# tailnet address and it cost 29 hours of lost backups on 2026-08-02 and 3 days on
# 2026-08-04: nothing can bind 100.64.x.x before tailscaled is up, and a bind that
# fails during network setup leaves a process that never runs and never exits, so
# nothing that retries exited services recovers it. On a box nobody can touch that
# is the worst failure available. The credentials carry the security argument —
# htpasswd + --private-repos + --append-only is strictly stronger than "reachable
# means authorised", because it also constrains fleet members and it survives a
# device joining the ISP's wifi.
#
# --append-only refuses every DELETE except locks and refuses to delete the config
# at all, so Almaty can add history and can never remove it. The cost is that
# `forget --prune` cannot run from the client. It is not rehomed here: this box
# holds no password, so it COULD not prune, and does not need to — the payload is
# ~1 TB on 8 TB and 663 GB of it is a frozen archive that dedupes to nothing.
# Never forgetting is the correct behaviour for a copy of last resort.
#
# THE CHECKSUM IS NOT OPTIONAL. An installer that would run unverified as root on
# a box 900 km away, on a warning alone, is worse than one that refuses outright —
# a warning nobody is there to read is not a control. So SHA256_LINUX_AMD64 below
# is checked unconditionally: empty (a placeholder never filled in) refuses before
# any network call, and a mismatch refuses just as hard, on its own exit code so it
# is never confused with any other failure this script can hit.
#
# EXIT CODES — two failures must never share one status (AGENTS.md):
#   0  success
#   2  not running as root
#   3  operator has not created $DATA/.htpasswd yet (a separate, later
#      precondition from "not root" — distinct fix, so distinct code)
#   78 $VAULT is not mounted as VAULT_UUID
#   79 rest-server checksum unverifiable — empty pin or an actual mismatch;
#      one failure class (an unverified binary), correctly one code
#   1  service failed to reach active after install
set -euo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

REST_SERVER_VERSION=0.14.0
VAULT=${VAULT:-/mnt/vault}
DATA="$VAULT/restic"
# Fetched 2026-09-12 from the published release's own SHA256SUMS:
#   https://github.com/restic/rest-server/releases/download/v0.14.0/SHA256SUMS
SHA256_LINUX_AMD64="4c9c95bc079a0334e81fad379b19dc5c3353c71c2c88d652cafce2081c2b1c66"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }

# The disk, by UUID. `nofail` means an absent drive leaves an ordinary empty
# directory, so serving that would publish an empty repository that restic would
# happily accept snapshots into. Refuse instead.
VAULT_UUID=${VAULT_UUID:?set VAULT_UUID to the data disk UUID}
actual="$(findmnt -no UUID "$VAULT" || true)"
[ "$actual" = "$VAULT_UUID" ] || { echo "$VAULT is not UUID=$VAULT_UUID (got '${actual:-nothing}')" >&2; exit 78; }

id -u restic >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin restic
install -d -o restic -g restic -m 0700 "$DATA"

if ! [ -x /usr/local/bin/rest-server ] ||
   ! /usr/local/bin/rest-server --version 2>&1 | grep -q "$REST_SERVER_VERSION"; then
    # Refuse before touching the network at all if the pin has no checksum —
    # never `|| true`, never a warn-and-continue: an unverified binary run as
    # root on an unattended box is not an acceptable default.
    [ -n "$SHA256_LINUX_AMD64" ] || {
        echo "SHA256_LINUX_AMD64 is empty — refusing to install an unverified rest-server binary" >&2
        exit 79
    }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/restic/rest-server/releases/download/v${REST_SERVER_VERSION}/rest-server_${REST_SERVER_VERSION}_linux_amd64.tar.gz"
    curl -fsSL "$url" -o "$tmp/rs.tgz"
    echo "$SHA256_LINUX_AMD64  $tmp/rs.tgz" | sha256sum -c - || {
        echo "rest-server download FAILED checksum verification — refusing to install" >&2
        exit 79
    }
    tar -xzf "$tmp/rs.tgz" -C "$tmp"
    install -m 0755 "$tmp"/rest-server_*/rest-server /usr/local/bin/rest-server
fi

# htpasswd lives INSIDE the data directory, so it survives a reinstall of the
# binary and is not in any repository. bcrypt (-B): rest-server supports it and
# the alternative is MD5.
command -v htpasswd >/dev/null 2>&1 || { apt-get update && apt-get install -y apache2-utils; }
if [ ! -f "$DATA/.htpasswd" ]; then
    echo "Create the client credential now:" >&2
    echo "  htpasswd -B -c $DATA/.htpasswd latitude" >&2
    echo "The username MUST be 'latitude': --private-repos maps a username to a" >&2
    echo "TOP-LEVEL directory, so the repo is $DATA/latitude/." >&2
    exit 3
fi
chown restic:restic "$DATA/.htpasswd"; chmod 600 "$DATA/.htpasswd"

cat > /etc/systemd/system/rest-server.service <<UNIT
[Unit]
Description=restic REST server (append-only sink)
# The DISK, not the network. A wildcard bind needs nothing from tailscaled, and
# ordering on the mount is what stops the server publishing an empty directory.
After=mnt-vault.mount
Requires=mnt-vault.mount

[Service]
Type=simple
User=restic
Group=restic
ExecStart=/usr/local/bin/rest-server \\
    --path $DATA \\
    --listen :8001 \\
    --private-repos \\
    --append-only \\
    --htpasswd-file $DATA/.htpasswd \\
    --log -
Restart=always
RestartSec=10
# Hardening. The process reads one directory and listens on one port.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now rest-server.service
systemctl is-active --quiet rest-server.service || { journalctl -u rest-server -n 30 --no-pager; exit 1; }
echo "rest-server $REST_SERVER_VERSION listening on :8001, serving $DATA (append-only)"
