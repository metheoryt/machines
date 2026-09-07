# g15: Windows 11 → Debian 13 trixie

**Status:** design, approved in direction 2026-09-07. Not started.
**Box:** `g15` / ASUS ROG G16 G513IE — Ryzen 7 4800H, 31 GB, RTX 3050 Ti,
one 953 GB NVMe, tailnet `100.64.0.3`, LAN `192.168.8.170`, Windows user `methe`.

## Why

`AGENTS.md` deferred this on one premise: *"C: holds ~416 GB nobody has
reviewed, so a native Debian install would have to start with that review."*
**Measured 2026-09-07, the premise is wrong.** `C:\Users\methe` is 510 GB of
which **366 GB is two virtual disks** — 207.9 GB `ext4.vhdx` (the `g15-wsl`
distro already in daily use) and 158.2 GB `docker_data.vhdx` (Docker Desktop's
store). What is left is not a mystery pile:

| Item | Size | Disposition |
|---|---|---|
| `ext4.vhdx` (g15-wsl distro) | 207.9 GB | 204 GB of it migrates (below) |
| `docker_data.vhdx` (Docker Desktop) | 158.2 GB | **discard** — see *Docker* |
| `Music` | 88.3 GB | migrates; OneDrive does **not** cover it |
| `WindowsGSM` | 32.1 GB | **discard** — unused (owner's call, 2026-09-07) |
| `AppData` minus the two vhdx | ~14 GB | discard |
| `OneDrive` (Documents/Desktop/Pictures) | 3.7 GB | **no action** — already synced |
| `Downloads` | 2.2 GB | owner reviews before the wipe |
| `C:\Users\methe\my` (repos) | <1 GB | no action — git-tracked, cloned fresh |

`C:\Documents and Settings` (510 GB) and `Local Settings` (378.8 GB) are
junctions to `C:\Users` and `AppData\Local`. They are not additional data; do
not count them.

The second reason is that nearly every `g15` trap in `.claude/memory/project.md`
is an artifact of the Windows/WSL boundary rather than of the box: the distro
dies unless a `wsl.exe` client is attached (hence the `wsl-keepalive` task);
Windows cannot open TCP to its own distro's NAT address (hence `nc` in a
`ProxyCommand`); every remote command is parsed by PowerShell first (hence
base64-on-stdin for anything with quotes); `orca serve` needs WSLg's `:0` handed
to it because `/tmp/.X11-unix` is a read-only tmpfs. All of it disappears.

**The fleet keeps a Windows member.** `desktop` stays Windows, so
`provision.ps1`, `Fleet.psm1` and the PowerShell suites keep a live test host.
This migration costs no Windows coverage.

### What is NOT a reason

No games and no launchers appear anywhere in g15's installed software — the
usual reason to keep Windows on a ROG laptop does not apply here. Emby and
Jellyfin are installed but **not running** (only Cloudflare WARP, sshd and
Tailscale are), `Videos` is empty, and Jellyfin holds 0.1 GB of config.

## Transport — measured, not assumed

| Path | Rate | Note |
|---|---|---|
| g15 Windows sshd → `wsl.exe` → desktop-wsl, over the LAN | **44 MB/s** | measured, 3 GB |
| g15-wsl ↔ desktop-wsl over the tailnet | **3.3 MB/s** | measured, 1 GB — DERP relay via hub (Kazakhstan) |
| direct Ethernet cable, APIPA | ~117 MB/s | measured 2026-08-28 |

Both laptops now associate at a 1201 Mbps WiFi 6 link rate, **and that does not
help the tailnet path**: re-measured on 2026-09-07 with the WiFi 6 link up, the
relayed pair still delivers 3.3 MB/s, and `tailscale status` reports `curaddr=`
empty for it — 13× slower than the LAN route on the same radio. Two NATed WSL distros get no
direct path. The LAN route through g15's Windows sshd is the fast one because it
leaves tailscale out of it entirely.

Two transport facts that cost time when forgotten:

- **`ssh` to a bare IP does not pick up the fleet identity.** The generated
  config keys on `Host *.gg.ez`, so `ssh methe@192.168.8.170` falls through to
  the default identity and fails instantly with zero bytes transferred — which
  reads as "no bandwidth". Pass `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`.
- **Only port 22 is open inbound.** `nc` to any other port on either box is
  refused by Windows Firewall, so the transfer rides ssh whether you wanted it
  to or not.

Staging target is **desktop's `C:`** — 1.2 TB free of 1.9 TB, same LAN. Not
latitude: it is on the other LAN, so its path relays too (88 GB would be ~7
hours).

## Payload

**Out of the distro (204 GB)** — everything here is inside the vhdx and dies
with the Windows partition:

- `/data/qaz-law/pgdata` — 186 GB. Physical postgres copy, `data_checksums on`.
- `/home/me` — 18 GB.

**Out of Windows (~88.4 GB):**

- `Music` — 88.3 GB.
- Three Docker Desktop named volumes — **~59 MB total**: `telegrind_pgdata`
  (57.31 MB), `embedthat_redis_data` (1.335 MB),
  `tugtainer_tugtainer_data` (45.12 kB).

### Docker: the 158 GB store is disposable, and that is measured

All 19 containers are `Exited`, five weeks old — the servarr/immich/restic stack
from when this box was `server`, whose role has since moved to latitude. Every
stateful one bind-mounted `D:\` or `F:\`, and **both drives are absent from the
box now**: `D:\ImmichMedia\postgres`, `D:/Media/config/*`, `F:/restic-repos` all
point at nothing. So the containers are shells with no data behind them.

What carries size in that store is images and build cache — 7.6 GB and 7.1 GB
layers, `immich_model-cache` at 6.5 GB — all regenerable. The only real state is
the three named volumes above, and they fit in a single tar.

## Plan

Each phase ends in a verifiable state. Do not start the next until its check
passes.

### 0. Decide and record

- Owner reviews `Downloads` (2.2 GB) and says keep-or-drop.
- Confirm the OneDrive client has actually finished syncing — the 3.7 GB is only
  safe if it is uploaded, not merely enrolled. Check the client's own status,
  not the folder's existence.
- Write down the current identity set that must move together, per `AGENTS.md`:
  tailnet node `100.64.0.3`, the `g15` dotfiles branch, and this box's entry in
  `fleet-authorized-keys`.

### 1. Stage everything off the box

Target `desktop:C:\g15-staging\`. Transport: ssh from desktop-wsl pulling
through g15's Windows sshd, `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`.

1. Stop postgres cleanly on g15-wsl before copying `pgdata`. A running postgres
   directory copies torn — `hosts/latitude/debian/mirror-refresh.sh`'s header
   records why that looks like a backup and is not one.
2. Copy in **chunks with a marker per chunk**, reusing the shape of
   `scratchpad/xfer2.sh` (18 × 10 GB batches, resumable). An interruption then
   costs one chunk, not the run.
3. `Music`, the three docker volumes (`docker run --rm -v <vol>:/v …` to tar
   each), and `Downloads` if kept.

**Check — by manifest, never by `du`.** Path plus size for every file, sorted
`LC_ALL=C`, compared on both sides. `du` totals match even when one file is
truncated, which is exactly what a killed `tar` leaves behind.

Budget: ~293 GB at 44 MB/s ≈ 1 h 55 m. With the Ethernet cable ≈ 45 m.

### 2. Install Debian 13 trixie

Mirror latitude's shape where the reasons still apply, and only there:

- **Unencrypted ext4 root.** latitude's rationale is "must boot unattended" and
  is recorded as settled. g15 is a personal laptop that leaves the flat — this
  is the one place to diverge and take LUKS. Decide explicitly rather than by
  copying.
- GUI: install a desktop environment. The whole point of the reinstall is that
  this is a workstation, not a services host.
- Hostname `g513ie` (the OS-hostname layer keeps the SKU, per the two-layer
  convention). Logical name `g15` does not change.

### 3. Hybrid graphics — the one item that can eat a weekend

Ryzen 4800H iGPU + RTX 3050 Ti. `nvidia-driver` from trixie plus `supergfxctl`
for mode switching; the G513 is supported by the asus-linux project, and
`asusctl` replaces G-Helper for fan curves and charge limit. Treat this as its
own phase with its own rollback (the box is usable on the iGPU alone), not as a
step inside the install.

Also verify the wifi band here: `.claude/memory/project.md` records g15 stuck on
2.4 GHz channel 12 under Windows because the MT7921 exposed no band-preference
property. It now associates at a WiFi 6 rate, so either that changed or the
record is stale — `mt7921e` is in-kernel and may simply behave better.

### 4. Provision as a normal Linux fleet member

- `just provision --machine g15 --dry-run`, then `--apply`.
- **`ssh-server` is still an unimplemented stub** (roadmap P3) and is named in
  `PLANNED_ROLES`, so `--apply` will not fail on it — it will also not configure
  sshd. Expect to hand-roll it as latitude was, and take the firewall shape from
  `docs/2026-08-01-nixos-harvest.md`: port 22 on `tailscale0` only, plus the one
  explicit `192.168.8.0/24` carve-out. That harvest is the only written spec for
  the role.
- Charge limit via `tier_battery_limit`.
- Restore `/home/me`, then `pgdata`, then `Music`.

### 5. Flip the manifest — one change, not several

- `fleet.json`: `g15` becomes `platform: linux`, `detect.hostname` stays
  `g513ie`. This changes how `fd_probe`/`fd_run` reach it — the Git-Bash-through-
  PowerShell arm in `agents/plugin/skills/lib/fleet-dispatch.sh` is keyed on
  `platform: windows` and must stop applying to g15.
- **`g15-wsl` ceases to exist.** It is a self-declared host
  (`fleet.local.json`), never in `fleet.json`, so removing it is deleting that
  file with the distro. One host replaces two, and `g15` inherits the tailnet
  node it already had (`100.64.0.3`); the WSL host's `100.64.0.9` is retired.
- `desktop-wsl`'s `fleet.local.json` sets `self.parent: desktop` and is
  unaffected.
- Re-run `/ship`'s `fleet-pull` so every box sees the new manifest, then confirm
  `ssh g15` still resolves for boxes that re-provisioned.

### 6. Retire the Windows-shaped workarounds

Delete rather than port: the `wsl-keepalive` scheduled task, the
`nc`-in-`ProxyCommand` route into the distro, `FLEET_WIN_USER=methe`, and
`provision/orca-serve.sh`'s WSLg `:0` display handling — the last one only if no
other WSL host still needs it. `desktop-wsl` does, so **keep the `:0` code** and
drop only g15's use of it.

Orca on the box becomes a native GUI install rather than a headless `serve`
runtime, which is why `provision/orca-serve.sh` stays in the repo for
`desktop-wsl` and stops running here.

## Rollback

Until phase 2 begins, rollback is free: nothing on g15 has changed and the
staging copy is redundant. Once the disk is wiped, rollback means reinstalling
Windows — so **phase 1's manifest check is the point of no return** and must
pass before the installer boots. Keep the staging copy until the new box has run
for a week, then delete it deliberately.

## Open questions

- LUKS on the root or not (phase 2).
- Whether `Downloads` is kept (phase 0).
- Whether latitude should hold a second copy of `pgdata` while the box is being
  rebuilt. 186 GB at relay speed is ~14 hours, so this is only worth it if the
  single staging copy on desktop feels too thin.
