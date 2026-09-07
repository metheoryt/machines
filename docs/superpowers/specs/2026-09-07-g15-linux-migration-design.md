# g15: Windows 11 → Ubuntu 26.04.1 LTS

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

## Transport — measured, and the fleet topology was wrong

**The fleet is one LAN, not two.** Every member except `hub` is behind the same
router (some wifi, some cable) and gets a direct P2P path. `tailscale ping` from
`desktop-wsl`, 2026-09-07: latitude direct in 2 ms, g15 direct in 3 ms, hub
direct in 6 ms. `AGENTS.md` said "two separate LANs, cross-LAN pairs relay
through our own DERP — expected and accepted"; that is corrected in the same
change as this spec. The first draft of this document wrote latitude off as a
7-hour target on the strength of that sentence. It is the fastest target there
is.

| Path | Rate | Note |
|---|---|---|
| **g15-wsl → latitude, over the LAN** | **78 MB/s** | measured, 3 GB. One wifi hop; latitude is on cable. **The route this plan uses.** |
| desktop-wsl → latitude, over the tailnet | 99 MB/s | measured. Direct P2P, 2 ms. |
| latitude ← g15 Windows sshd → `wsl.exe`, over the LAN | 44 MB/s | measured. Two wifi hops — the double radio hop is the cost. |
| g15-wsl ↔ desktop-wsl, over the tailnet | 3.3 MB/s | measured. DERP relay via hub (Kazakhstan). |
| direct Ethernet cable, APIPA | ~117 MB/s | measured 2026-08-28. Not needed now. |

**`g15-wsl` is the fleet's only relayed peer, and that is a WSL property rather
than a network one.** `tailscale ping` reports `direct connection not
established`: the distro runs in NAT networking mode, so tailscale cannot punch
through to another NATed peer. But **NAT permits outbound**, which is why the
distro pushing to latitude's LAN address works and is fast — the relay is only
in the way when something tries to reach *in*.

**Do not switch g15 to `networkingMode=mirrored` to "fix" this.** It would
probably work — that is exactly why `desktop-wsl` has a real LAN address — but
mirrored also exposes the Windows Tailscale adapter inside the distro, and g15
has both a Windows node (`100.64.0.3`) and a distro node (`100.64.0.9`) to fight
over routes; desktop's own `.wslconfig` carries that warning in writing. Changing
the network mode of the box you are about to read 204 GB out of, to save perhaps
half an hour on a route that already works at 78 MB/s, is the wrong trade.

Both laptops now hold a 1201 Mbps WiFi 6 link, **and that is not what made the
difference**: re-measured with that link up, the relayed pair still delivers
3.3 MB/s. Leaving the relay is what helps; a faster radio is not.

Two transport facts that cost time when forgotten:

- **`ssh` to a bare IP does not pick up the fleet identity.** The generated
  config keys on `Host *.gg.ez`, so `ssh methe@192.168.8.170` falls through to
  the default identity and fails in 0.2 s with zero bytes transferred — which
  reads as "no bandwidth". Pass `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`. This
  produced three false measurements before it was spotted.
- **Only port 22 is open inbound** on either Windows box, so a transfer rides
  ssh whether or not that was the plan.

Staging target is **latitude**, `/mnt/immich-mirror` (610 GB free). It is the
always-on box, which matters for a park that spans a reinstall — a laptop that
sleeps is a poor custodian of the only copy.

## Payload

~292 GB out, ~292 GB back. Everything below lives inside the vhdx or on the
Windows partition and dies with the disk.

**Out of the distro (204 GB):**

- `/data/qaz-law/pgdata` — 186 GB. Physical postgres copy, `data_checksums on`.
- `/home/me` — 18 GB.

**Out of Windows (88.3 GB):**

- `Music` — 88.3 GB. OneDrive does **not** cover it: `My Music` in the registry
  points at the local `C:\Users\methe\Music`, not into OneDrive. It comes back
  to g15 afterwards (owner's call, 2026-09-07), so it round-trips through
  latitude — that is why the return leg is also ~292 GB.

**Explicitly dropped** (all four decided by the owner, 2026-09-07):

- `WindowsGSM`, 32.1 GB — unused.
- `Downloads`, 2.2 GB.
- **Docker Desktop's store in full, 158.2 GB — including its data.** Everything
  it held has already moved to latitude. That decision is corroborated: all 19
  containers are five weeks `Exited`, and every stateful one bind-mounted `D:\`
  or `F:\` — **both drives are absent from the box now**, so
  `D:\ImmichMedia\postgres`, `D:/Media/config/*` and `F:/restic-repos` point at
  nothing. The three named volumes that did hold bytes
  (`telegrind_pgdata` 57 MB, `embedthat_redis_data` 1.3 MB,
  `tugtainer_tugtainer_data` 45 kB) go with it.
- `OneDrive`, 3.7 GB — no action needed, already in the cloud.
- `C:\Users\methe\my` (repos), <1 GB — no action, git-tracked and cloned fresh.

## Plan

Each phase ends in a verifiable state. Do not start the next until its check
passes.

### 0. Decide and record

- Confirm the OneDrive client has actually finished syncing — the 3.7 GB is only
  safe if it is uploaded, not merely enrolled. Check the client's own status,
  not the folder's existence.
- Write down the current identity set that must move together, per `AGENTS.md`:
  tailnet node `100.64.0.3`, the `g15` dotfiles branch, and this box's entry in
  `fleet-authorized-keys`.

### 1. Stage everything off the box

Target `latitude:/mnt/immich-mirror/g15-staging/`. Transport: **g15-wsl pushes
outbound to latitude's LAN address**, `ssh -i ~/.ssh/id_fleet -o
IdentitiesOnly=yes me@192.168.8.155` — verified to authenticate, 78 MB/s
measured. Windows-side items (`Music`) go the same way, read through
`/mnt/c` from inside the distro.

1. Stop postgres cleanly on g15-wsl before copying `pgdata`. A running postgres
   directory copies torn — `hosts/latitude/debian/mirror-refresh.sh`'s header
   records why that looks like a backup and is not one.
2. Copy in **chunks with a marker per chunk**, reusing the shape of
   `scratchpad/xfer2.sh` (18 × 10 GB batches, resumable). An interruption then
   costs one chunk, not the run.
3. `Music`, read from `/mnt/c/Users/methe/Music`. Nothing else — the docker
   volumes and `Downloads` are dropped, not staged.

**Check — by manifest, never by `du`.** Path plus size for every file, sorted
`LC_ALL=C`, compared on both sides. `du` totals match even when one file is
truncated, which is exactly what a killed `tar` leaves behind.

Budget: ~292 GB at 78 MB/s ≈ **1 h 5 m**. The Ethernet cable (117 MB/s) would
save ~20 minutes and is not worth unplugging anything for.

### 2. Install Ubuntu 26.04.1 LTS

**The distro was Debian 13 trixie until 2026-09-07, and the owner changed it.**
His reason: he reads Debian as a headless server OS, and g15 is a workstation
that wants a desktop and the utilities around it. That is a preference and does
not need defending — but it turns out to have a technical argument he did not
make, and the argument is the one that matters here:

- **The kernel floor for this hardware is met out of the box.** The asus-linux
  project does not officially support Debian-based distros and names the reason:
  a minimum recommended kernel of **6.19+**, because most of the patches that
  improve ASUS/ROG laptops land upstream first. trixie ships 6.12 LTS —
  answerable via `trixie-backports` (7.1.8), but answerable is not the same as
  free. Ubuntu 26.04 LTS ships **7.0** as its GA kernel, so the floor is met
  with nothing added.
- **The fleet provisioner does not care.** `provision/linux.sh`'s own header
  declares "Debian 11+ / Ubuntu 22.04+", its only distro gate is `have apt-get`,
  and `tier_apt_dev` already handles both distros' package-name quirks
  (`fdfind` → `fd`, `batcat` → `bat`). `fleet.json` carries **no distro field
  at all** — only `platform` — so g15's manifest entry changes exactly as §5
  already describes and no further. `tier_dotfiles` derives `platform=debian`,
  but that token is a class name meaning "not darwin, not WSL"; Ubuntu passes
  the gate unchanged. It is now a misnomer and should become `linux`, which is
  a rename in `tier_dotfiles` + `role_dotfiles`, not a behaviour change.
- **It is the release qaz-law is already developed on.** `g15-wsl` runs Ubuntu
  26.04.1 LTS today, so the native install is the same userland the project's
  compose stack has been running against — one fewer variable when the database
  comes back up in phase 4. **The point release is the pin** (owner, 2026-09-07):
  26.04.1 is both what the distro runs and what the current install media is, so
  naming it costs nothing and removes a question at ISO-download time.

The cost, stated plainly: the fleet gains a second apt distro, so latitude is
Debian and g15 is Ubuntu. That is a real divergence and it buys the kernel.

**The media is ready and verified (2026-09-07).**
`ubuntu-26.04.1-desktop-amd64.iso`, 6 482 409 472 bytes, sits on the Ventoy
drive's `Boot` partition (253.8 GB exFAT, 203 GB still free). Its SHA256 is
`601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f`, matching
`https://releases.ubuntu.com/26.04/SHA256SUMS` — fetched as the raw file, not
read back through a summarizer, because a single transcribed hex string is
exactly the kind of check that passes while proving nothing.

**Secure Boot is OFF on g15** (`Confirm-SecureBootUEFI` → `False`, probed
2026-09-07), so Ventoy boots directly and there is no shim to enrol through
MokManager. Worth knowing before standing at the machine: with Secure Boot on,
Ventoy's first boot is a security violation and the fix is a BIOS-level detour.

The same drive carries latitude's `xs700` archive-mirror partition on
`sda3`/`H:`. Nothing on Windows writes to it, and `archive-mirror.timer` on
latitude next fires **2026-10-01 05:01** — return the drive before then and no
run is missed.

Mirror latitude's shape where the reasons still apply, and only there:

- **Unencrypted ext4 root — decided, not copied.** latitude's own rationale is
  "must boot unattended", which does not transfer. The reason here is g15's own:
  it is a home box that does not get carried around (owner, 2026-09-07). Had it
  travelled, this is where LUKS would have gone in.
- GUI: **Ubuntu Desktop** (GNOME 50 on 26.04) — the stock image, not the
  server one. The whole point of the reinstall is that this is a workstation,
  not a services host. See §4 on why the provisioner will not supply this.
- Hostname `g513ie` (the OS-hostname layer keeps the SKU, per the two-layer
  convention). Logical name `g15` does not change. Note the release codename
  ("Resolute Raccoon") enters nothing — the two-layer convention has no slot
  for it, and `fleet.json` has no distro field to put it in.

### 3. Hybrid graphics — the one item that can eat a weekend

Ryzen 4800H iGPU + RTX 3050 Ti. `ubuntu-drivers autoinstall` plus
`supergfxctl` for mode switching; the G513 is supported by the asus-linux
project, and `asusctl` replaces G-Helper for fan curves and charge limit. Treat
this as its own phase with its own rollback (the box is usable on the iGPU
alone), not as a step inside the install.

**`asusctl` and `supergfxctl` are not packaged for any Debian-based distro** —
build from source (Rust) or use one of the third-party Debian/Mint installers.
Before paying that, check what the kernel already gives: `asus-wmi` exposes the
charge threshold as plain sysfs (which is what `tier_battery_limit` already
writes) and, on supported models, fan curves through hwmon
(`asus_custom_fan_curve`). **Verify on the box whether the G513IE exposes that
hwmon node.** If it does, `asusctl` is convenience rather than a requirement,
and the weekend this section warns about is mostly the GPU half.

Also verify the wifi band here: `.claude/memory/project.md` records g15 stuck on
2.4 GHz channel 12 under Windows because the MT7921 exposed no band-preference
property. It now associates at a WiFi 6 rate, so either that changed or the
record is stale — `mt7921e` is in-kernel and may simply behave better.

### 4. Provision as a normal Linux fleet member

- `just provision --machine g15 --dry-run`, then `--apply`.
- **The provisioner installs neither docker nor a desktop toolchain, and its
  closing text says so while pointing at a host that no longer exists**:
  "Not installed by design (only a NixOS host gets these): the declarative dev
  toolchain (docker, language servers, the full fish/ghostty/GNOME setup)"
  (`provision/linux.sh`). The last Nix host went 2026-08-01. So on the new g15
  those are nobody's job — and `dockerd` is exactly what qaz-law needs to come
  back up. This is independent of the distro choice; the Ubuntu decision only
  surfaced it. Two options, and the choice is not made here: install docker by
  hand as a phase-4 step, or add a `tier_docker` and let every future Linux
  workstation inherit it. The stale prose in `linux.sh` needs deleting either
  way.
- **`ssh-server` is still an unimplemented stub** (roadmap P3) and is named in
  `PLANNED_ROLES`, so `--apply` will not fail on it — it will also not configure
  sshd. Expect to hand-roll it as latitude was, and take the firewall shape from
  `docs/2026-08-01-nixos-harvest.md`: port 22 on `tailscale0` only, plus the one
  explicit `192.168.8.0/24` carve-out. That harvest is the only written spec for
  the role.
- Charge limit via `tier_battery_limit`.
- Restore `/home/me`, then `pgdata`, then `Music` — pulled from latitude, which
  is now a direct 2 ms peer.
- **Noticed while planning, not fixed here:** latitude has no `~/.ssh/id_fleet`
  and no `Host *.gg.ez` block, so the always-on box cannot *originate* fleet ssh
  — it can only be connected to. Nothing in this plan needs it (g15-wsl pushes),
  but it is a real asymmetry and belongs in the roadmap rather than in this
  spec's scope.

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
pass before the installer boots. Keep the staging copy on latitude until the new
box has run for a week, then delete it deliberately.

## Open questions

**None blocking.** All four that this design opened were answered on 2026-09-07:
no LUKS, `Downloads` dropped, Docker Desktop dropped with its data, `Music`
returns to g15.

The last one — whether a second copy of `pgdata` should exist while the box is
rebuilt — was left to wait until phase 1 had actually run. It ran on 2026-09-07
and the answer is **no second copy** (owner). So `pgdata` exists in exactly one
place: `latitude:/mnt/immich-mirror/g15-staging/pgdata` on `/dev/sdd2`, a USB
drive on the dock this repo calls the flaky one. The internal NVMe behind
`/mnt/immich` had 655 GB free and a `cp -a` would have cost nothing; it was
offered and declined. Not an open item — but if that drive misbehaves during the
rebuild, there is nothing to fall back on, so say so at once rather than
retrying.

**Phase 1 is complete.** All three payloads verified by manifest on 2026-09-07:
`pgdata` 1297 entries / 186G and `home-me` 341543 entries / 18G on latitude,
`Music` 18377 entries / 88.3G on desktop. Phase 2 may boot the installer.
