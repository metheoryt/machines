# What the NixOS tree knew — harvested before deletion, 2026-08-01

The flake and its 22 modules were deleted on 2026-08-01 because no Nix host
remains in the fleet. **Everything is recoverable from the annotated tag
`nixos-final`** — this file is not the archive, it is the list of things a future
session would otherwise have to *know to go looking for*.

```console
git show nixos-final:modules/system/ssh-server.nix
git log nixos-final -- modules/          # the whole history is still there
git worktree add /tmp/nixos nixos-final  # if you need to read several at once
```

The review was done module by module, comparing each against what
`provision/lib/tiers.sh` implements and against what is **live on latitude's
Debian install**. The interesting result is that in the two places where the Nix
module and the Debian install disagreed, **the Debian install was right and the
module was wrong** — so this is a deletion that loses no correct behaviour.

## 1. `ssh-server.nix` is the spec for P3's unimplemented role executor

The `ssh-server` role executor is still a stub that prints "not yet implemented".
This module was the only written record of what it is supposed to produce, and
the firewall shape in particular is not guessable:

- `services.openssh` with `PasswordAuthentication = false` **and**
  `KbdInteractiveAuthentication = false`. Both — disabling only the first leaves
  keyboard-interactive as a password path on some builds.
- **`openFirewall = false`, deliberately.** Port 22 is *not* opened globally.
  Instead: `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22]`,
  i.e. sshd is reachable **on the tailnet interface only**…
- …plus exactly one explicit LAN carve-out, added as a raw iptables rule because
  the NixOS option cannot express a source subnet:
  `iptables -A nixos-fw -p tcp -s 192.168.8.0/24 --dport 22 -j nixos-fw-accept`,
  with the matching `-D` in `extraStopCommands`.
- `users.users.me.openssh.authorizedKeys.keyFiles = [ ../../provision/fleet-authorized-keys ]`
  — the managed span, so the file in the repo *is* the authority.

The tailnet-only-plus-one-subnet shape is the load-bearing part. A reimplementation
that just opens 22 is a downgrade, and the LAN subnet is hardcoded to this
apartment's range.

## 2. `rustdesk-config.nix` held the only copy of the peer identity map

The only module carrying data not derivable from anything else. The mechanism
(a seed-only activation script, because RustDesk rewrites its own TOML at runtime
and cannot be given read-only symlinks) is gone with the flake; **the data is
worth keeping.**

Self-hosted rendezvous **and** relay server: `cyphy.kz` for both, with the
server's key alongside. That key is documented in the module itself as the
server's *public* key and therefore safe to commit — it is **not** reproduced
here on purpose, so this file stays free of anything key-shaped. Read it from the
tag when re-seeding: `git show nixos-final:modules/home/rustdesk-config.nix`.

The peer ID ↔ machine map, which is the part that is genuinely annoying to
reconstruct (RustDesk IDs are assigned, not chosen):

| RustDesk ID | Machine | User | Platform |
|---|---|---|---|
| `399975738` | `me-g614jv` (desktop) | `methe` | Windows |
| `482036139` | `g513ie` (server) | `methe` | Windows |
| `173199886` | `win-kiokq9idol4` | — | Windows |

Plus two LAN-IP-keyed duplicates that only resolve on this network:
`192.168.8.145` → desktop, `192.168.8.170` → server. Peer *passwords* were
never committed — they are per-install encrypted secrets, so RustDesk prompts on
first connect. `win-kiokq9idol4` is unidentified; it predates the current
naming convention and may be a machine that no longer exists.

Note `482036139` and `192.168.8.170` point at `server`, which P2 is
decommissioning — prune both when it goes.

## 3. The battery limit: the Nix module was BUGGY, `tiers.sh` fixed it

`hardware/dell-latitude.nix` wrote `charge_control_end_threshold` and nothing
else. On a Dell that is not enough: **the EC honours `charge_control_*` only in
its Custom charge mode and it comes up in `[Fast]`**, so the module produced a
box that *displayed* an 85% ceiling while charging straight past it. Measured on
latitude 2026-07-29: `end=85`, `charge_types=[Fast]`, battery at 94% and still
climbing.

`tier_battery_limit` in `provision/lib/tiers.sh` writes the charge mode as well,
and adds a start/floor threshold the module never had (a low floor makes the cell
cycle down and back repeatedly, which is the harder life; the floor sits just
under the ceiling instead). Verified live on latitude 2026-08-01:
`end=85 start=80`, `/usr/local/bin/charge-upto` present, `/etc/default/charge-upto`
carrying the window. Dell clamps a floor below 50 or a ceiling below 55 silently;
`charge-upto` reports it when that happens.

**This matters more than it looks:** latitude is a laptop that now runs 24/7 on
AC as the services host, which is precisely the duty cycle that swells a cell
held at 100%. The Debian implementation is the working one. Nothing to port.

## 4. `laptop.nix` would now be actively harmful

It set `HandleLidSwitch = "suspend"` and `HandlePowerKey = "suspend"`, with
`criticalPowerAction = "Hibernate"`. On the machine latitude has *become*, closing
the lid would suspend the box and take immich, servarr, the restic REST hub and
every backup timer down with it.

Latitude's Debian install is configured the opposite way, and more thoroughly
than a single option — verified live 2026-08-01:

- `/etc/systemd/logind.conf`: `HandleLidSwitch=ignore`,
  `HandleLidSwitchExternalPower=ignore`, `HandleLidSwitchDocked=ignore`,
  `IdleAction=ignore`
- and `sleep.target`, `suspend.target`, `hibernate.target` are all **masked** —
  belt and braces, so even a caller that asks for suspend directly cannot get it.

Do not "restore" any of `laptop.nix`'s power management onto latitude. The rest
of it was genuinely laptop-shaped and is moot on a permanently-docked box:
`mem_sleep_default=deep` (never sleeps), touchpad/backlight/actkbd Fn-key
bindings, `upower` low-battery thresholds, `scsiLinkPolicy = med_power_with_dipm`.

## 5. Docker auto-prune was NOT ported — a deliberate gap, with a warning

`programs/development.nix` had `virtualisation.docker.autoPrune = { enable = true;
dates = "weekly"; }`, which runs `docker system prune -f`. Latitude has **no
prune timer**. Measured 2026-08-01: 18 images / 14.83 GB with only 528 MB (3%)
reclaimable, and 899 MB (8%) of 10.47 GB in volumes — so the gap is currently
costing nothing, and nvme0 is at 28% after the migration.

If it is ever added back: **it must never gain `--volumes`.** 3 of latitude's 7
Docker volumes are live immich/postgres data, and `docker system prune --volumes`
would delete the unused ones without asking. The NixOS default was safe
specifically because it omitted that flag; a hand-rolled cron line that "improves"
it by adding `-a --volumes` is a data-loss bug.

## 6. Everything else was already ported, or is moot

- `home/me.nix`'s git identity, fish aliases/functions and Starship config →
  `tier_git_identity` / the fish setup in `tiers.sh` (which says so in its own
  comments: "mirrors modules/home/me.nix"). Its GNOME dconf settings are moot —
  latitude is a headless-ish services box now.
- `system/git-autofetch/` → `tier_git_autofetch` + the user timer, live on
  latitude and on desktop-wsl.
- `system/fleet-selfpull.nix` → it was already only a wrapper around
  `provision/fleet-selfpull.sh`, which is the live implementation everywhere.
- `system/machines-converge.nix` → `scripts/converge.sh` is the live engine; the
  module was the NixOS-only trigger.
- `system/fleet.nix` → read `fleet.json` with `fromJSON`; `provision/lib/fleet.sh`
  is the portable reader.
- `home/ssh.nix` → **not ported, and that is P3's open item.** It rendered
  latitude's outbound `~/.ssh/config` from `fleet.json`; `tier_fleet_ssh` is
  darwin-only, so latitude's client config is currently unmanaged. Note the module
  rendered *fleet hosts only* — it never emitted a GitHub account block, which is
  why latitude would silently offer the wrong key for a `cyphy671` clone.
- `system/base.nix` — `zramSwap` at 50%; latitude instead runs a 14.9 GB swap
  **partition** (1.7 GB in use against 23 GB RAM), which is the better fit for a
  box with real disk and long-lived services. Kernel was
  `linuxPackages_latest`; Debian's stock kernel is now in force deliberately.
- `nvidia.nix`, `hardware/asus-rog.nix` — orphaned since NixOS `g16` was retired
  2026-07-08. No host imported them. The G16's RTX 4060 lives under Windows now.
- `desktop/gnome.nix` — GDM/GNOME/PipeWire/portals/fonts. Nothing to port.
- `home/claude.nix` → `agents/bootstrap.sh` does the same job on every platform
  and is the mechanism everywhere now.
- `home/orca-bin.nix`, `home/rustdesk-bin.nix`, `pkgs/gortex.nix` — AppImage /
  binary wrappers. All three tools are installed **outside Nix** now (gortex runs
  from `~/.local/bin`), so the packaging was already vestigial. Their three
  `scripts/update-*.sh` version-bumpers wrote *only* into these Nix files and
  went with them; the "find the latest release" logic is in the tag if a
  non-Nix equivalent is ever wanted.
- `pylspFixOverlay` in `flake.nix` pinned python-lsp-server to fork
  `metheoryt@e4ee218` for the `pylsp_definitions` crash gortex hit constantly.
  It goes with the flake. If that crash reappears on a non-Nix box, the fix is
  the same commit, applied however that box installs pylsp.
