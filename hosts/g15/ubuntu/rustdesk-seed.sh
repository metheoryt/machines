#!/usr/bin/env bash
# hosts/g15/ubuntu/rustdesk-seed.sh — point RustDesk at the self-hosted
# cyphy.kz rendezvous/relay instead of the public `rs-ny.rustdesk.com`.
#
# This is the surviving half of the deleted `modules/home/rustdesk-config.nix`,
# and it keeps that module's one load-bearing decision: RustDesk REWRITES its
# own TOML at runtime (window geometry, nat_type, last-connect), so the config
# cannot be a read-only symlink and cannot be clobbered wholesale. This merges
# three keys into the `[options]` table and leaves every other key alone. It
# never touches RustDesk.toml, which holds the device identity — `enc_id`,
# `key_pair`, `password`, `salt`.
#
# TWO configs, because the packaged unit is `User=root` and the root service
# re-launches `rustdesk --server` as `me` with the live session's
# WAYLAND_DISPLAY/XDG_RUNTIME_DIR/DBUS address injected. The service reads
# root's copy; the tray reads the user's. Seeding only one leaves the other
# talking to the public server.
#
# `key` here is the SERVER's PUBLIC key — safe to commit, and verified against
# the live `hbbs` container's `data/id_ed25519.pub` on hub 2026-09-10. Peer
# passwords are per-install encrypted secrets and are deliberately absent.
#
# g15 is the only box running the Wayland-unattended preview build, which is
# why this lives here — but nothing in the body is g15-specific. When upstream
# folds unattended Wayland into a stable release and this becomes a
# `tier_rustdesk`, this file is its seed half; the install half is the part
# that is still blocked (see docs/2026-08-01-nixos-harvest.md §2).
#
# Run as root. Testing: RD_SERVICE_CONF / RD_GUI_CONF override the paths and
# RD_NO_RESTART=1 skips the systemctl restart.
set -euo pipefail

RENDEZVOUS='cyphy.kz'
RELAY='cyphy.kz'
KEY='MUJKMH88yTSlixlnLpYxBtNgD8ixlyIt6Vdy6MferKs='

SERVICE_CONF="${RD_SERVICE_CONF:-/root/.config/rustdesk/RustDesk2.toml}"
GUI_CONF="${RD_GUI_CONF:-/home/me/.config/rustdesk/RustDesk2.toml}"

merge() {
  local f="$1" owner=""
  # python writes as root, so preserve whoever owned the file (the tray's copy
  # is the desktop user's). Derived per file — never a hardcoded username.
  [ -e "$f" ] && owner="$(stat -c '%u:%g' "$f")"
  [ -e "$f" ] && cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
  RD_F="$f" RD_R="$RENDEZVOUS" RD_L="$RELAY" RD_K="$KEY" python3 - <<'PY'
import os, pathlib
f = pathlib.Path(os.environ["RD_F"])
want = {
    "custom-rendezvous-server": os.environ["RD_R"],
    "relay-server":             os.environ["RD_L"],
    "key":                      os.environ["RD_K"],
}
lines = f.read_text().splitlines() if f.exists() else []

# Flat file, one [options] table: split into head (pre-table) and its body.
head, body, in_opts = [], [], False
for ln in lines:
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        in_opts = (s == "[options]")
        if in_opts:
            continue
    (body if in_opts else head).append(ln)

# Drop existing definitions of the keys we own; keep every other option.
kept = [ln for ln in body
        if "=" not in ln or ln.split("=")[0].strip() not in want]
while kept and not kept[-1].strip():
    kept.pop()

out = head[:]
while out and not out[-1].strip():
    out.pop()
out += ["", "[options]"] + kept + [f"{k} = '{v}'" for k, v in want.items()]
f.parent.mkdir(parents=True, exist_ok=True)
f.write_text("\n".join(out) + "\n")
print(f"  wrote {f}")
PY
  [ -n "$owner" ] && chown "$owner" "$f"
  return 0
}

echo "seeding service config (root-owned, read by rustdesk --service):"
merge "$SERVICE_CONF"
echo "seeding GUI config:"
merge "$GUI_CONF"

if [ "${RD_NO_RESTART:-}" != "1" ]; then
  systemctl restart rustdesk.service
  sleep 3
  echo "rustdesk.service: $(systemctl is-active rustdesk.service)"
  echo "--- service config now ---"
  cat "$SERVICE_CONF"
fi
