# Latitude wipe — harvest and pre-install decisions

Status: **open**. Created 2026-07-28, ahead of retiring NixOS on `latitude` and
reinstalling it as a plain-Linux always-on server.

Latitude is `100.64.0.2` / OS hostname `latitude5520`, NixOS
`26.11.20260726.624af66`, root on a 450G LUKS volume inside a 512G KIOXIA
BG4 NVMe. Uptime at survey time 1d2h, so the box is healthy and reachable —
this is a planned wipe, not a recovery.

## 1. What is already safe

Surveyed live 2026-07-28. **No code is at risk.** Every git checkout on the
box is clean and fully pushed:

| Repo | dirty | unpushed | stashes |
|---|---|---|---|
| `~/machines`, `~/my/vps`, `~/my/airdrome`, `~/my/skep` | 0 | 0 | 0 |
| `~/pure/backend-api`, `backend-core`, `backend-schema-registry`, `claude-plugins` | 0 | 0 | 0 |

The dotfiles bare repo is on branch `latitude`, clean, nothing ahead of
`origin/latitude`. It tracks only **7 files**, which is the point below: almost
nothing of latitude's local configuration is version-controlled, so anything
worth keeping has to be taken deliberately.

No GPG secret keys exist — `gpg` is not even installed, so there is no keyring
to lose.

## 2. What must come off the box — the short list

The home directory is 31G, and nearly all of it is deliberately worthless
because latitude is becoming headless: `.cache` 11G, Google Chrome profile
6.7G, Slack 1.5G, `.local/share` 9.1G. **Do not copy the home directory.**
Chrome and Slack re-sync from their accounts; caches regenerate.

Genuinely irreplaceable, total well under 100 MB:

| Path | Why | Disposition |
|---|---|---|
| `~/amnezia.cyphy.kz.conf` | AmneziaWG client config for the VPS, untracked, only copy | **Re-issue on `hub`**, do not transport |
| `~/.ssh/vps_awg_private.key` | AWG private key, 45 B, blocked from dotfiles by the deny block | **Re-issue on `hub`**, do not transport |
| `~/.ssh/id_ed25519` | Passphrase-less, has GitHub push access | **Revoke + regenerate**, do not transport |
| `/etc/ssh/ssh_host_ed25519_key`, `ssh_host_rsa_key` | Wipe changes the host key; five boxes' `known_hosts` break | Either preserve, or plan the re-accept |
| `/var/lib/tailscale/tailscaled.state` | Headscale node identity for `100.64.0.2` | See §4 |
| `~/.config/gh/hosts.yml` | gh OAuth token | Low stakes — just `gh auth login` again |
| `airdrome_db_data` Docker volume | Postgres data for `airdrome-db-1`, in no repo | **`pg_dump`**, not a volume file copy |
| `~/Documents`, `~/Pictures` | 3 MB combined | Just take them |
| `~/.ssh/config.backup` | Dated 2026-05-10, predates the Nix-generated `~/.ssh/config` | Glance at it, then drop |

Also present and safely ignorable: `~/.claude.json.tmp.*` leftovers (nine of
them), `~/.config/orca` and `~/.config/JetBrains` IDE settings (regenerable),
`~/.zoom`.

**Prefer re-issuing over transporting.** For the AWG peer, the GitHub key, and
the Headscale node, minting a fresh identity on the surviving side is both less
work and better practice than carrying a private key off a machine that is
about to be destroyed. `hub` runs the AmneziaWG server, so the AWG peer is a
hub-side operation.

## 3. Blockers — resolve before the wipe

**B1. `nvme0n1p3` is unidentified.** A 25.5G `crypto_LUKS` partition, not
mounted, not in the captured fstab. It is probably an old swap or hibernation
volume, but that is a guess, and a disk with an unreadable partition on it
cannot be certified safe to erase. Resolution needs the sudo password:

```console
sudo cryptsetup luksDump /dev/nvme0n1p3
grep -rn nvme0n1p3 /etc/crypttab /etc/fstab
```

**B2. The second M.2 slot is unverified.** `dmidecode -t slot` returned
nothing usable, so "latitude has a free M.2 slot" is not yet a fact the plan
can rest on. What matters is length (2230 vs 2280), keying (M-key PCIe ×4
versus a B+M WWAN slot that may be ×1 or USB-only), and the negotiated link
width. Verify empirically after seating the drive: `nvme list`, then
`lspci -vv` and read `LnkSta` on the new controller. If it enumerates ×4 the
plan holds; if it turns out to be the WWAN slot, the 1TB stays in its enclosure
and the "re-plug from server to latitude" premise is void.

**B3. LUKS on an always-on headless server.** Today's root is LUKS-encrypted
and a human types the passphrase at the console. As an always-on server, any
unattended reboot then hangs at that prompt. Decide at install time —
unencrypted root, or LUKS plus remote unlock (dropbear-initramfs / clevis +
TPM). This is not revisitable without a second reinstall.

**B4. Backup capacity is smaller than primary capacity.** 6TB primary against
3×1TB gives at most 3TB of coverage, and only by spanning the three disks,
which defeats the point of independent backup disks. Which datasets get a
second copy therefore has to be decided *before* the 6TB is laid out, because
it sets the dataset boundaries.

## 4. Fleet-side consequences

- **`fleet.json` pins latitude.** `platform: "nixos"`, `tailnet.ip:
  "100.64.0.2"`, roles `base, ssh-server, dev, desktop, laptop, agents,
  dotfiles, repos, backup-client`. All of that changes: the platform becomes
  Debian/Ubuntu, `desktop` and `laptop` come off, and a services/backup-hub
  role probably goes on.
- **The tailnet address may not come back.** Re-enrolling with a new machine
  key creates a *new* Headscale node; the old name can end up suffixed and the
  next free IP handed out instead. Delete the stale node in Headscale first so
  the name and `100.64.0.2` are free.
- **Latitude is the fleet's only Nix executor.** `just quick` hard-gates on a
  one-host dry build, and `scripts/converge.sh`'s `touches_nix` path has no
  other runner. The moment latitude is wiped, that gate breaks fleet-wide.
  Either run a final `nix flake check` now and record the result, or accept
  that the Nix surface is deleted as part of retirement — but decide before the
  wipe, because afterwards there is no way to validate it in order to delete it
  confidently.
- **`modules/system/fleet-selfpull.nix` and `machines-converge.nix` lose their
  only consumer**, and latitude moves onto the same `post-merge` hook +
  cron/systemd-user path as every other non-Nix member.

## 5. Runtime facts worth recording before the box is gone

- **`/sys/power/mem_sleep` reads `s2idle`, not `deep`** — the
  `mem_sleep_default=deep` kernel parameter documented in `CLAUDE.md` does not
  take effect on this hardware. Irrelevant for a server, but the doc is wrong.
- **Battery health 63%** — `energy-full` 39.4 Wh against a 62.3 Wh design
  capacity. Still useful as a crude UPS for an always-on box, worth about 40 Wh.
- **Both USB-A ports are genuine 10 Gbps.** `lsusb -t` shows two
  `xhci_hcd/4p` root hubs at `10000M` (buses 002 and 004), fed by the
  Tiger Lake "On-Package USB 3.2 Gen 2x1 (10 Gbs)" controller. The user's
  reading is confirmed: HDD docks can go on USB-A and leave both USB-C free.
  Note the two 10 Gbps hubs share that one controller, so concurrent dock
  throughput is shared, not additive.
- **`/etc/ssh/authorized_keys.d/me`** (731 B, root-owned, generated) is the
  Nix-rendered authorized-keys file; the new install must reproduce its content
  from `fleet.json`, not from this file.

## 6. Sequence

These steps are destructive and order-dependent. Written out in full prose
deliberately.

1. Resolve blocker **B1** — identify and, if it holds nothing, note
   `nvme0n1p3` as disposable. Do not proceed with an unidentified encrypted
   partition on the disk.
2. Decide **B3** (LUKS or not) and **B4** (which datasets get a second copy).
   Both are install-time decisions and neither can be changed afterwards
   without redoing the install.
3. Harvest the §2 short list to a destination that is **neither the 1TB SSD
   nor any disk about to be installed**. Use `air` or `desktop` over the
   tailnet. Everything in §2 must be off-box before anything is erased.
4. `pg_dump` the airdrome database out of the running container, verify the
   dump is non-empty and restorable, and only then consider the Docker volume
   expendable.
5. Re-issue rather than transport: mint a fresh AmneziaWG peer for latitude on
   `hub`, and remove latitude's current GitHub key from the GitHub account.
   Delete latitude's stale node from Headscale so its name and IP free up.
6. Run a final `nix flake check` and record the output in this document, so the
   last known-good state of the Nix surface is on record before it stops being
   verifiable.
7. **Physically remove the 1TB SSD from the machine during the OS install.** It
   is still the only copy of some data until the server-side restore
   verification in Task 15 of
   `2026-07-27-fleet-migration-mac-primary-latitude-server.md` passes. "Not
   selected in the installer" is not sufficient protection; out of the chassis
   is.
8. Install, then verify the second M.2 slot per **B2** before assuming the
   1TB can live inside the laptop at all.
9. Update `fleet.json` (platform, IP, roles) and re-provision through the role
   front door. Re-accept the changed SSH host key on the other members.

## 7. Standing holds

- The 1TB SSD extracted from `server` is under the plan-level hold: no wipe, no
  sale, no reformat before the Task 15 server-side restore verification passes.
  The ~980 MB/s SEQ1M Q8T1 benchmark over the Type-C enclosure demonstrates
  media health and a full Gen2 link. It is **not** a restore verification.
- The 320GB laptop HDD slated for retirement has not been surveyed for unique
  content. Do that before it leaves the rotation.
