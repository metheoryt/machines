# Fleet Roadmap

Living backlog for the machine fleet. Curated — tick/prune as items land. A new
session inherits the fleet state from `.claude/memory/project.md`; this file is
the "where to head next" companion. For any item worth real work, run
`superpowers:brainstorming` → `writing-plans` and drop the plan under
`docs/superpowers/plans/`.

_Last updated: 2026-08-01 — rewritten after the latitude-server migration. The
previous revision (2026-07-14) had gone materially wrong: retired node names,
latitude at the wrong tailnet IP, and done items still open. If you find
yourself copying an unchecked box forward without re-verifying it, stop — that
is how the last revision rotted._

## Where we are now

Transport is **Headscale** (self-hosted, `cc.cyphy.kz`, MagicDNS `gg.ez`);
AmneziaWG survives on the VPS **only** as the relatives' obfuscated VPN.

| Node | Tailnet IP | Platform | State |
|---|---|---|---|
| `hub` | `100.64.0.1` | Debian VPS | Headscale control plane + embedded DERP; AWG relatives-hub |
| `server` | `100.64.0.3` | Windows 11 (`g513ie`) | **draining** — services moved to latitude, containers stopped, retirement pending |
| `desktop` | `100.64.0.4` | Windows 11 (`g614jv`) | tailnet + sshd |
| `air` | `100.64.0.7` | macOS | **primary dev box** |
| `latitude` | `100.64.0.8` | **Debian 13 trixie** | **services host** — immich + servarr + speedtest + tugtainer |

`desktop-wsl` (`100.64.0.6`) is a self-declared WSL host: no `fleet.json` entry,
a gitignored `fleet.local.json` instead.

Two separate LANs. Same-LAN pairs get direct P2P (~3ms); cross-LAN pairs relay
through our own DERP — expected and accepted, which is why **UPnP/router
port-mapping is not on this backlog**.

**There is no Nix host left in the fleet** (verified live 2026-08-01). Read the
P1 item before touching anything under `modules/`.

---

## P0 — The 663 GiB archive has one copy, and the restic layer is gone.

_Corrected 2026-08-01, after a full audit. An earlier revision of this section
claimed "nothing has been backed up anywhere since 2026-07-19." **That was
wrong** — immich's own nightly dump is alive. The real exposure is narrower and
sharper than the overstatement, and the overstatement pointed at the wrong fix
(a scheduler, when what is missing is a second copy)._

### What is actually protected right now

| Data | Size | Protection |
|---|---|---|
| immich DB (albums, faces, metadata) | 223 MB/night | ✅ immich's own nightly dump → `/var/backups/immich-db`, latest `20260801T020000` |
| immich library, 2025→now | 242 G | ⚠️ rsync mirror → sdd2, **manual**, last run 2026-07-31 17:10 |
| **immich archive 1970–2024** (`/mnt/immich-2024/admin`) | **663 G** | ❌ **exactly one copy** |
| servarr media | 526 G | ✅ deliberately unprotected — replaceable |
| versioned / prunable / off-host backup | — | ❌ gone entirely |

### What died

- The three `immich-*` scheduled tasks on `server` last ran **2026-07-19** and
  have returned `0x8007010B` — *"the directory name is invalid"* — ever since.
  They target `G:\`/`H:\`. They are still `State: Ready` with a `NextRunTime`,
  so **the schedule reads healthy while backing up nothing.**
- **The restic repos no longer exist.** No `backup-homeserver` directory and no
  repo markers on any mount, on any box. G:/H: were repurposed into
  `immich-mirror` / `spare320` / `immich-2024` during the migration — the
  migration consumed the backup drives. Whatever gets built starts from zero;
  there is no history to recover.
- `restic-server` (the REST target on `server:8001`, which `desktop-wsl` pushed
  to) has been `Exited (0)` for 3 days. `latitude` has the restic binary but no
  repo, timer, or container; `hub` has no restic at all.

### The fix, cheapest-irreversibility-first

- [ ] **Disable the three dead tasks on `server`.** Zero risk, do it first — a
  schedule that reports Ready while failing is worse than no schedule.
- [ ] **Put a systemd user timer on `hosts/latitude/debian/mirror-refresh.sh`,**
  alongside `fleet-selfpull` / `dotfiles-sync` / `git-autofetch`. Removes
  "someone remembers" from the only live redundancy.
- [ ] **Give `/mnt/immich-2024/admin` a second copy on `/mnt/xs`.** This is the
  actual data-loss fix. Measured 2026-08-01: source 662.9 GiB, target 700.0 GiB
  free and empty, **no hardlinks** (`nlink>1` count is 0), uniform `me:me`
  ownership, 4 files over 4 GiB (largest 11.6 GB — well inside exfat's limit;
  the 4 GiB ceiling is FAT32's, not exfat's). 37 GiB of slack is thin in
  general but fine here: 1970–2024 is a **closed** set, new photos land on
  `/mnt/immich`. exfat therefore works as-is; reformatting sda3 to ext4 would
  buy ownership preservation but is destructive on a Ventoy drive and is not
  required.
- [ ] **Stand up restic for the small irreplaceable set** — the DB dump and the
  stack configs. Fits anywhere, restores versioning, and does not require
  solving the 815 G problem first. Use `resticprofile`, the tool the old design
  already used (`vps/backup/base.yaml` + a new `latitude/profiles.yaml`).
  **Do not try to restore `vps/backup/homeserver/profiles.yaml` as-is** — it
  assumes two dedicated repo drives (`G:\`, `H:\`) that no longer exist as free
  space anywhere in the fleet.
- [ ] **The full versioned backup of all 815 G, and offsite rotation** — a
  separate decision that needs hardware. There is no drive in the fleet with
  815 G free. Everything currently lands in one apartment, on drives attached
  to one laptop; the dock drives are removable, so rotation needs no new
  infrastructure, but capacity does.

- [ ] **Decide what the mirror does with the deleted `Media/` tree.**
  `/mnt/immich-mirror` is 287G against `/mnt/immich`'s 249G; the difference is
  the `Media/` tree deleted from the source on 2026-08-01, plus `staging/` and
  `var-backups/`. `--delete` is **off by design** (see the script header), so
  the mirror will never drop it on its own. Prune deliberately or accept it as a
  last-resort copy — but write down which.

---

## P1 — Decide the flake's fate. It blocks everything under `modules/`.

- [ ] **Delete or archive the NixOS tree.** No Nix host remains, yet `flake.nix`
  still builds `latitude5520` — a machine that no longer exists. The carcass is
  ~10.1k lines across `flake.nix`, `flake.lock`, 18 `modules/*.nix`,
  `hosts/latitude/nixos/`, and `pkgs/`.
  **The consequence that matters is not the line count:** roughly twenty
  `justfile` recipes target it and cannot run on any box in the fleet —
  including **`just quick`, the validation gate AGENTS.md documents**. There is
  currently no gate at all (see P4 for what's left of one).
  Suggested shape: `git tag nixos-final` before deleting. It costs nothing and
  permanently answers "how did we do X under NixOS." Then prune the dead recipes
  and rewrite the AGENTS.md build section.
  This also retires the `pylspFixOverlay` item that used to live under
  Housekeeping — it goes with the flake, not separately.

---

## P2 — Finish the `server` (g513ie) decommission.

Coupled to P0: `backup-hub` is declared on `server` in `fleet.json` and exists
nowhere else, so backups cannot be fixed without deciding where it goes, and the
decommission cannot finish without the same decision. Do them together.

- [ ] Move the `backup-hub` role to `latitude`.
- [ ] Repoint the six Caddy routes still aimed at the dead `100.64.0.3`:
  `speed` (2282), `tug` (9412), `jfin` (8096), `seerr` (5055), navidrome (4533),
  and the layer4 `:2222`. **`jfin` republishes Jellyfin publicly — needs an
  explicit go, not a silent repoint.**
- [ ] Remove `server` from `fleet.json` and drop `methe@server` from
  `provision/fleet-authorized-keys`. Not before the two above: it is still
  reachable and still holds the only copies of things.
- [ ] Archive or delete `hosts/server/windows/`.

---

## P3 — latitude's SSH story has no generator.

- [ ] **`tier_fleet_ssh` is darwin-only.** With `modules/home/ssh.nix` dead,
  nothing generates latitude's outbound `~/.ssh/config`. It is unmanaged and
  drifting. The failure mode is silent rather than loud: latitude has **no
  GitHub account block at all**, so a `cyphy671` repo cloned there would fall
  back to default identity resolution and quietly offer the wrong key.
- [ ] **The `ssh-server` role executor is still an unimplemented stub** — it
  prints "not yet implemented (skipped)", as do `base` and `backup-client`.
  (`provision/roles/` holds only `agents`, `dotfiles`, `repos`.) The capability
  exists three separate hand-rolled ways — the now-dead NixOS module,
  `windows.ps1` step 6, and `tier_ssh_trust` for POSIX tier boxes — which is why
  AGENTS.md reads as though the role is done. It is not, and with the NixOS
  module gone latitude's sshd has no generator either. Windows gotchas for
  whoever implements it are in project memory.

---

## P4 — Green the test suite. It is now the only gate.

- [ ] **Three failures, all pre-existing** — they reproduce at HEAD in a clean
  worktree and are *not* fallout from the fleet-ssh work:
  `provision/tests/provision-wsl.test.sh`,
  `agents/tests/orca-profile-harvest.test.sh`,
  `agents/tests/orca-profile-link.test.sh`.
  With the Nix gate gone the bash suite is all the validation the repo has, and
  a red suite gives no signal at all. Whole suite:
  ```bash
  for t in provision/tests/*.test.sh provision/*.test.sh \
           agents/tests/*.test.sh scripts/converge.test.sh; do bash "$t"; done
  ```
- [ ] **No recipe runs the suite.** `just test` is `nixos-rebuild test` and dies
  with the flake. Give the bash suite a recipe as part of P1.

---

## P5 — Documentation drift.

- [ ] **`AGENTS.md`** still leads its Common Commands with Nix, and its
  "Fleet migration in flight" banner predates the migration finishing.
- [ ] **`.claude/memory/project.md` ~359–368** still discusses `latitude5520`
  NixOS builds as live facts.
- [ ] **45 plans under `docs/superpowers/plans/`, none marked done.** Their
  checkboxes are unchecked even where fully executed, so the directory cannot be
  read as a backlog — worth a status line at the top of each, or at least of the
  two migration plans that are effectively complete.

---

## P6 — Housekeeping.

- [ ] **hub's `me@desktop-wsl-ubuntu-26-04` key** (`…DXi623`) is live —
  desktop-wsl's `id_ed25519` — and redundant only because desktop-wsl's ssh
  config pins `id_fleet`. Removing it is a real revocation, not a cleanup.
  Needs a deliberate decision.
- [ ] **latitude's migration debris**: 21M `~/immich-migration/` plus six
  `*.log` (`overnight.log` alone is 3.2M).
- [ ] **Rotate the leaked Anthropic API key and Telegram bot token.** Blocks
  bringing telegrind and embedthat back up. Hermes credentials were never
  revoked at source either.
- [ ] **Headscale ACLs.** The tailnet is default-open. Relatives never join it,
  but least privilege across our own boxes is cheap now and annoying later.
- [ ] **Drop `desktop`'s AWG.** It runs AmneziaWG beside Tailscale and its
  services already work over the tailnet. Remove once nothing depends on
  `10.0.0.6`, then drop the peer on hub.
- [ ] Enumerate `xs-keepers/home`'s ~20 config dirs; unbundle
  `qaz-code-feature-sync-dashboard.bundle`; decide
  `windows-reinstall-runbook.md`'s fate; confirm immich still has "Hardware
  decoding" ticked.

---

## Done

**2026-08-01 — latitude-server migration.** latitude reinstalled as Debian 13
and took over the services role: immich, servarr, speedtest, tugtainer live and
healthy. `/mnt/immich/Media` deleted after a four-way guard (526 GiB reclaimed,
nvme0 86% → 28%); 30G reclaimed on spare320. Fleet SSH made **authoritative** —
`provision/fleet-authorized-keys` is now rewritten as a managed span rather than
appended to, so deletions actually revoke and renames actually propagate; keys
renamed to logical fleet names on all five boxes; hub's dead `methe@lat5520`
pruned. Two recurring latitude scripts tracked under `hosts/latitude/debian/`;
16 one-off migration scripts deleted after harvesting their measurement rules
into `docs/2026-07-drive-migration-log.md`.

**2026-07-17 — AWG mesh retired from the repo.** SSH re-homed onto the tailnet.
Deleted `mesh-vpn.nix`, mesh params, `fleet.json` mesh blocks, and the
provisioner mesh roles/libs. Kept the AmneziaVPN client and the VPS AWG server.

**2026-07-14 — fleet-wide SSH over tailnet + name resolution.** `fleet.json`
gained `tailnet.ip`; the whole SSH story moved onto `100.64.0.x`.

**2026-07-13 — Headscale rollout.** 0.29.2 + embedded DERP on the VPS; every
node cut over; reusable pre-auth keys revoked afterwards.
