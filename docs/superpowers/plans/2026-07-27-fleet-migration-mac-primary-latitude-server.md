# Fleet Migration: MacBook Primary, latitude → Server, Retire G15

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan spans two repos and physical hardware.** Tasks are tagged `[machines]`, `[vps]`, `[physical]`, or `[remote-box]`. Physical tasks cannot be done by an agent — they are checkpoints for the human.

**Goal:** Make the MacBook Air M5 the primary dev machine, convert latitude5520 from dev laptop to the always-on services host, move the homeserver's data off the G15 (g513ie), and retire/sell the G15.

**Architecture:** Three surviving fleet members plus the VPS. `air` (MacBook, to-go dev, repos local) → `desktop` (G614JV, gaming + always-on Orca daemon + WSL Ubuntu 26 for amd64 work) → `latitude` (NixOS, always-on Docker services host, takes over `10.0.0.2` behind the VPS Caddy). `hub` (VPS) unchanged. The four 2.5" HDDs live in two externally-powered 2×2 docks that move from the G15 to latitude; the G15's internal Kingston NVMe (live Immich library) moves into a USB/TB3 enclosure.

**Tech Stack:** NixOS 25.05 + flakes + Home Manager, Docker Compose, Headscale/Tailscale (`cc.cyphy.kz`, `gg.ez`), WireGuard/AmneziaWG to the VPS, Caddy (+`caddy-l4`), restic + resticprofile, Immich/Navidrome/Forgejo/qBittorrent/Tugtainer/LibreSpeed.

## Global Constraints

- **The G15 is the only copy of some data until Task 15 passes.** No wipe, no sale, no reformat of any drive before the restore verification in Task 15 succeeds.
- **latitude keeps WireGuard address `10.0.0.2`.** Reusing the homeserver's tunnel IP means `vps/caddy/Caddyfile` reverse-proxy targets need no change. Only the l4 SSH upstream port changes (Task 9).
- **Immich container-side paths must not change.** The compose file bind-mounts `${LOCATION_<year>}:/data/library/admin/<year>`. Host paths change; container paths stay identical, so the Immich DB needs no path rewrite and no re-import.
- **Mount every external drive by UUID**, never by `/dev/sdX`. Five USB block devices across two docks have no stable enumeration order.
- **NTFS stays NTFS for this migration.** Converting 1.35 TB of media to ext4 is a separate follow-up project (Task 19), not part of the cutover. Only PostgreSQL and Docker's own storage move to ext4 on latitude's internal NVMe.
- **`nix flake check` / `just quick` can only run on latitude.** It is the fleet's only Nix host. Any `[machines]` task that changes Nix must be validated there.
- **Timezone `Asia/Almaty`, locale `ru_RU.UTF-8`** — already set in latitude's config; do not change.
- **Commit on the worktree branch, never on `main`.** Offer a fast-forward merge-back at phase boundaries.
- Fleet keys stay as they are (`latitude`, `desktop`, `server`, `hub`) until Task 18. Renaming during the migration would churn SSH aliases, the flake attr, and `hosts/` paths while things are in motion.

---

## Data Inventory (measured 2026-07-27)

**g513ie volumes:**

| Vol | Label | Disk | Bus | Size | Used | Contents | Destination |
|---|---|---|---|---|---|---|---|
| D | Immich | 0 KINGSTON SNV2S1000G | **internal NVMe** | 932G | 689G | `ImmichMedia\library` (UPLOAD_LOCATION), `ImmichMedia\postgres` (DB_DATA_LOCATION) | NVMe enclosure → latitude |
| C | (OS) | 1 WD PC SN560 | **internal NVMe** | 953G | 459G | Windows | stays in the G15, wiped, sold |
| E | Immich 2024 | 2 WDC WD10 SPZX | USB dock | 931G | 663G | `E:\admin\<year>` ×19 (LOCATION_1970…LOCATION_2024) | dock → latitude |
| G | Immich backup | 3 ST1000LM024 | USB dock | 931G | 158G | restic repo `backup-homeserver\immich-media` etc. | dock → latitude |
| F | Public | 4 ST320LT020 | USB dock | 298G | 177G | `qb`, `restic-repos`, `secrets`, GoPro folder, `G614JV-Ubuntu-24.04.tar` | dock → latitude |
| H | Immich 2024 backup | 5 HGST HTS541010A9 | USB dock | 931G | 650G | restic repo `backup-homeserver\immich-media-2024` | **candidate for off-site** |

**latitude:** single KIOXIA KBG40ZNS512G 512G NVMe; `nvme0n1p2` 450.4G LUKS → ext4 `/home`, 329G free. 24 GB RAM, 8 threads (Tiger Lake). Thunderbolt via `bolt`. USB: two 4-port 10 Gbps root hubs (buses 002, 004).

**desktop (G614JV):** 64 GB RAM, C: 1862G with 1195G free. Already runs the Orca daemon endpoint the fleet pairs against.

**Services (`vps` repo, `homeserver/`):** `immich`, `navidrome`, `forgejo`, `restic-server`, `tugtainer`, `speedtest`, `beat`, `telegrind`, `embedthat`. Public routes in `vps/caddy/Caddyfile` all point at `10.0.0.2`.

---

## Phase A — Prep and Decisions

### Task 1: Decide the two open questions and record them `[machines]`

Two decisions gate hardware purchases. Make them before touching anything.

**Files:**
- Modify: `.claude/memory/project.md` (append under a new `## Fleet migration 2026-07` heading)

- [ ] **Step 1: Decide how the Kingston NVMe attaches to latitude**

Run on latitude:

```bash
sudo dmidecode -t slot
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL
```

Expected: `lsblk` shows exactly one NVMe (`nvme0n1`, 476.9G). If `dmidecode` reports a free M.2 2280 slot with `Current Usage: Available`, the Kingston drops straight in. The Latitude 5520's second M.2 is usually a 2230 WWAN slot, which will **not** take a 2280 SSD — if that is what you see, buy a USB 3.2 Gen2 or Thunderbolt NVMe enclosure instead.

- [ ] **Step 2: Decide whether to buy a 2 TB staging/off-site drive**

Recommended: yes. It removes the only genuinely risky step in this plan (the free-space shuffle in Task 12's fallback) and it becomes the off-site copy that closes the gap in Task 2. Without it, both the live library and its only backups end up in one chassis on latitude.

- [ ] **Step 3: Record both decisions**

Append to `.claude/memory/project.md`:

```markdown
## Fleet migration 2026-07

- **Kingston NVMe attach method:** <free M.2 slot | USB enclosure | TB3 enclosure> —
  decided 2026-07-XX from `dmidecode -t slot` on latitude.
- **2 TB staging drive:** <bought | skipped> — if skipped, Task 12 uses the
  G→H shuffle fallback and there is no off-site copy until Task 19.
```

- [ ] **Step 4: Commit**

```bash
git add .claude/memory/project.md
git commit -m "docs(memory): record fleet-migration hardware decisions"
```

---

### Task 2: Close the single-chassis backup gap `[remote-box]`

Today live media (D, E) and its restic repos (F, G, H) are all in the g513ie chassis. Consolidating onto latitude preserves that property — one machine, one power event, both copies. `hub` has role `backup-client`, not a repo destination, so it is not a copy.

**Files:**
- Modify: `/home/me/my/vps/backup/homeserver/profiles.yaml` (later, in Task 14 — this task is the decision + physical set-aside)

- [ ] **Step 1: Pick the drive that leaves the building**

Default: `H:` (HGST, 931G, holds `backup-homeserver\immich-media-2024`, 650G used). It is the largest single backup set and it is on a dock bay you can free.

- [ ] **Step 2: Verify that repo is healthy before it becomes your off-site copy**

On g513ie (PowerShell):

```powershell
cd D:\; restic -r H:\backup-homeserver\immich-media-2024 --password-file <path-to-pass.txt> check --read-data-subset 5%
```

Expected: `no errors were found`.

- [ ] **Step 3: Set it aside physically**

Label it, note the date and the last snapshot ID, and store it somewhere that is not the same room. It does **not** travel to latitude in Task 11. Plan to rotate it back in quarterly.

- [ ] **Step 4: No commit** — physical/operational step. Note the outcome in the migration log you started in Task 1.

---

## Phase B — latitude → macOS (Mac becomes primary)

### Task 3: Teach the fleet libraries about the `darwin` platform `[machines]`

`fleet.json` currently only carries `nixos`, `windows`, `debian`. Dispatch code branches on platform, so add `darwin` before adding the machine.

**Files:**
- Modify: `provision/lib/fleet.sh`
- Modify: `provision/lib/Fleet.psm1`
- Modify: `agents/plugin/skills/lib/fleet-dispatch.sh`
- Test: `provision/tests/fleet-profile.test.sh`, `provision/tests/tiers.test.sh`, `agents/plugin/skills/lib/tests/`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `fleet_platform` returns `darwin` for the new host; `fd_probe`/`fd_run` treat `darwin` like a POSIX-SSH host (same branch as `nixos`/`debian`), **not** like `windows` (which tunnels through Git Bash via PowerShell's call operator).

- [ ] **Step 1: Read the current platform branching**

```bash
grep -n "platform\|windows\|nixos\|debian" provision/lib/fleet.sh agents/plugin/skills/lib/fleet-dispatch.sh
```

Note every `case`/`if` that enumerates platforms. Each one needs a `darwin` arm or must fall through to the POSIX default.

- [ ] **Step 2: Write the failing test**

Add to `provision/tests/fleet-profile.test.sh`, following the file's existing assertion style:

```bash
test_darwin_platform_is_posix() {
  local out
  out="$(fleet_platform air)"
  assert_equals "darwin" "$out"
}
```

- [ ] **Step 3: Run it and confirm it fails**

```bash
bash provision/tests/fleet-profile.test.sh
```

Expected: FAIL — no `air` machine in `fleet.json` yet, or `darwin` not recognised.

- [ ] **Step 4: Add the `air` entry to `fleet.json`**

```json
    "air": {
      "platform": "darwin",
      "tailnet": { "ip": "100.64.0.5" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "air" }
    },
```

Place it after `"latitude"`. `100.64.0.5` is the next free tailnet address (hub .1, latitude .2, server .3, desktop .4).

- [ ] **Step 5: Add the `darwin` arms**

In every platform `case` found in Step 1, group `darwin` with the POSIX hosts. In `fleet-dispatch.sh` the rule is: `windows` gets the PowerShell/Git-Bash path, everything else (`nixos`, `debian`, `darwin`) gets plain `ssh`.

- [ ] **Step 6: Run the tests**

```bash
bash provision/tests/fleet-profile.test.sh
bash provision/tests/tiers.test.sh
bash provision/tests/fleet-local.test.sh
```

Expected: all PASS.

- [ ] **Step 7: Validate the Nix side on latitude**

`fleet.json` feeds `modules/system/fleet.nix` and `modules/home/ssh.nix`, which generate `~/.ssh/config`.

```bash
ssh latitude 'cd /home/me/machines && git pull --ff-only && nix build --dry-run ".#nixosConfigurations.latitude.config.system.build.toplevel"'
```

Expected: evaluates without error. (Remember: latitude logs into fish — avoid `$(...)` and POSIX `test` syntax in the remote command string.)

- [ ] **Step 8: Commit**

```bash
git add fleet.json provision/lib/fleet.sh provision/lib/Fleet.psm1 \
        agents/plugin/skills/lib/fleet-dispatch.sh provision/tests/fleet-profile.test.sh
git commit -m "feat(fleet): add darwin platform and the air MacBook member"
```

---

### Task 4: Add a macOS provisioning path `[machines]`

`provision/` is apt-Linux/WSL only (`provision/README.md` says so explicitly). `agents/bootstrap.sh` already branches on `uname -s` and handles macOS, so only the tool-install tier needs a Darwin sibling.

**Files:**
- Create: `provision/macos.sh`
- Modify: `provision/README.md` (add a macOS section)
- Modify: `provision/provision.sh` (dispatch `darwin` → `macos.sh`)

**Interfaces:**
- Consumes: `fleet_platform` returning `darwin` (Task 3).
- Produces: `provision/macos.sh` accepting the same argv shape as `provision/linux.sh`, so `provision.sh`'s existing role loop works unchanged.

- [ ] **Step 1: Read `provision/linux.sh` end to end**

```bash
cat provision/linux.sh
```

It is the template. `macos.sh` mirrors its structure and its CORE/best-effort split; only the package manager changes.

- [ ] **Step 2: Write `provision/macos.sh`**

Same CORE set as Linux (`git`, `curl`, `python3`, `ripgrep`, `fd`, `fzf`, `jq`), installed with Homebrew instead of apt; same best-effort set (`gortex` pinned to `pkgs/gortex.nix`, `claude`, `codex`, `gh`, `starship`, `direnv`, `fish`, `uv`, `git-delta`, `bat`). Keep the same abort-on-CORE-failure, warn-on-best-effort semantics. Two Darwin differences to handle explicitly:

- `fd` and `bat` install under their real names via brew — the Debian `fdfind`/`batcat` aliasing in `provision/lib/tiers.sh` must not run.
- `git-autofetch` is scheduled with a systemd user timer on Linux; on macOS use a `launchd` LaunchAgent plist in `~/Library/LaunchAgents/`.

- [ ] **Step 3: Dispatch `darwin` in `provision.sh`**

Add the `darwin` arm next to the existing platform executors so `provision/provision.sh air` routes to `macos.sh`.

- [ ] **Step 4: Dry-run it**

```bash
bash provision/provision.sh air dry-run
```

Expected: prints `▸ Machine: air   platform: darwin   mode: dry-run` and a plan line per role, no writes.

- [ ] **Step 5: Document it**

Add a short macOS section to `provision/README.md` mirroring the existing Linux/WSL one, noting Homebrew as the prerequisite and that the full `me.nix` desktop/`development.nix` toolchain is not reproduced (same trade the Linux path makes).

- [ ] **Step 6: Commit**

```bash
git add provision/macos.sh provision/provision.sh provision/README.md
git commit -m "feat(provision): add macOS (darwin) provisioning path"
```

---

### Task 5: Bring the Mac onto the tailnet `[physical]`

- [ ] **Step 1: Set the OS hostname**

```bash
sudo scutil --set HostName air
sudo scutil --set LocalHostName air
sudo scutil --set ComputerName air
```

Must match `detect.hostname` in `fleet.json`.

- [ ] **Step 2: Install Tailscale and join Headscale**

Install the Tailscale macOS app (the standalone variant, not the App Store one — the App Store build cannot set a custom control server), then:

```bash
tailscale up --login-server https://cc.cyphy.kz --authkey <KEY>
tailscale set --accept-dns=true
```

Generate `<KEY>` on the hub with `headscale preauthkeys create`.

- [ ] **Step 3: Verify the address matches `fleet.json`**

```bash
tailscale ip -4
```

Expected: `100.64.0.5`. If Headscale assigned something else, either reassign it there or update `fleet.json` — they must agree.

- [ ] **Step 4: Verify reachability both ways**

```bash
ping -c2 latitude.gg.ez && ping -c2 desktop.gg.ez
ssh latitude 'echo ok'
```

From latitude: `ssh air 'echo ok'` (after Step 5).

- [ ] **Step 5: Enable inbound SSH (role `ssh-server`)**

System Settings → General → Sharing → Remote Login: on, keys-only. Then append the fleet's public keys:

```bash
cat >> ~/.ssh/authorized_keys < <keys from provision/fleet-authorized-keys>
chmod 600 ~/.ssh/authorized_keys
```

- [ ] **Step 6: No commit** — verify in the migration log that all four fleet members ping each other.

---

### Task 6: Provision the Mac and move the dev workload `[physical]`

**Files (on the Mac, not in the repo):**
- Create: `~/machines` (clone), `~/my/vps` (clone), `~/pure/*` (clones)
- Create: per-repo `.claude/settings.local.json` (gitignored, holds the Pure Sentry secret)

- [ ] **Step 1: Clone `machines` and run the provisioner**

```bash
git clone <machines-remote> ~/machines
cd ~/machines && bash provision/provision.sh air apply
```

Expected: CORE tools installed, `agents/bootstrap.sh` runs, `~/.claude` and `~/.codex` get the shared symlink set (memory stores, `CLAUDE.md`, `plugin/`, `hosts/air.md` → `host-memory.md`).

- [ ] **Step 2: Create the per-host memory file**

```bash
touch ~/machines/hosts/air.md   # bootstrap links this to ~/.claude/host-memory.md
```

Note: `hosts/<hostname>.md` under `agents/` is the per-host memory path referenced by `agents/bootstrap.sh` — confirm the exact directory it reads before creating the file, and put it where bootstrap expects.

- [ ] **Step 3: Clone the work repos**

```bash
mkdir -p ~/pure && cd ~/pure
git clone <backend-api> && git clone <backend-core> && git clone <backend-schema-registry> && git clone <claude-plugins>
```

Roughly 1.5 GB total.

- [ ] **Step 4: Restore the gitignored per-repo secrets**

Each Pure repo carries a **project-scope** `.claude/settings.local.json` holding the Sentry token in `env`. These are gitignored and do not come with a clone. Copy them from latitude:

```bash
scp latitude:/home/me/pure/backend-api/.claude/settings.local.json ~/pure/backend-api/.claude/
# repeat per repo that has one
```

- [ ] **Step 5: Install the Pure toolchain**

Docker Desktop, `uv` (Python 3.14 per `pyproject.toml`'s `requires-python = "==3.14.*"`), the company VPN client, and `tsh` for Teleport. Re-authenticate `tsh` (12 h sessions).

- [ ] **Step 6: Verify the Docker stack actually runs on arm64**

This is the one unverified assumption from the earlier analysis. No `platform:` pin exists anywhere in `docker-compose.yml`, `docker-compose.override.yml`, or `docker/docker-compose-tests.yml`, and every base image is multi-arch — except `kartoza/postgis:18-3.6`, which was never checked.

```bash
docker manifest inspect kartoza/postgis:18-3.6 | grep -A2 architecture
cd ~/pure/backend-api && docker compose up -d
docker compose ps
```

Expected: an `arm64` entry in the manifest, and all containers `healthy`/`running`. If `kartoza/postgis` is amd64-only, that single service runs under Rosetta emulation — slow but functional; note it and move on, or fall back to the `desktop` Orca remote environment for DB-heavy work.

- [ ] **Step 7: Install gortex (darwin/arm64) and track the repos**

```bash
gortex daemon start --detach
gortex track ~/pure/backend-api
gortex track ~/machines
gortex daemon status
```

Expected: both repos listed with non-zero node counts. Remember worktrees are tracked individually — each new Orca worktree needs its own `gortex track`.

- [ ] **Step 8: Install Orca and pair the remote environments**

Install the macOS Orca build, then pair `desktop` (`ws://100.64.0.4:6768`) as a remote environment — the same shape as latitude's existing `~/.config/orca/orca-environments.json` entries. Do **not** pair latitude; it is becoming a services box.

- [ ] **Step 9: Work a full day on the Mac before proceeding**

Hard gate. Do not start Phase C until you have done real work on the Mac — a branch, a test run, an agent session, a PR — without reaching for latitude. Anything you discover missing is cheaper to fix while latitude is still a working dev machine.

- [ ] **Step 10: Commit** (from the Mac, proving the git identity works)

```bash
cd ~/machines
git add hosts/air.md
git commit -m "feat(fleet): add air per-host memory file"
```

---

## Phase C — Reshape latitude for the server role (config only, no hardware yet)

### Task 7: Convert latitude's NixOS config to a headless always-on server `[machines]`

**Files:**
- Modify: `hosts/latitude/nixos/configuration.nix`
- Modify: `fleet.json` (latitude's `roles`)

**Interfaces:**
- Consumes: the `darwin`/`air` entry from Task 3.
- Produces: a latitude generation with no GNOME, lid-close ignored, Docker running, and NTFS support compiled in — the prerequisite for Task 11's drive mounts.

- [ ] **Step 1: Drop the desktop environment**

Remove this import from `hosts/latitude/nixos/configuration.nix`:

```nix
    # Desktop environment
    ../../../modules/desktop/gnome.nix
```

Also remove `services.flatpak.enable = true;` — it exists for GUI apps. Reversible: re-add both lines if you later want a local GUI.

- [ ] **Step 2: Stop the lid from suspending the machine**

`modules/system/laptop.nix:16-19` sets `HandleLidSwitch = "suspend"` and `HandlePowerKey = "suspend"`. An always-on server must ignore both. Add to `hosts/latitude/nixos/configuration.nix`:

```nix
  # Always-on services host: the lid stays shut and the machine stays up.
  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
    HandleLidSwitchDocked = lib.mkForce "ignore";
    HandlePowerKey = lib.mkForce "ignore";
  };
```

`lib.mkForce` is required — `laptop.nix` sets these directly, not with `mkDefault`.

- [ ] **Step 3: Keep the battery healthy under permanent AC**

The battery is now effectively a small UPS. Lower the charge ceiling from 85:

```nix
  hardware.dell.battery = {
    chargeUpto = 60;
    enableChargeUptoScript = true;
  };
```

- [ ] **Step 4: Enable NTFS**

```nix
  # The relocated homeserver drives stay NTFS for this migration (see Task 11).
  boot.supportedFilesystems = ["ntfs"];
```

- [ ] **Step 5: Confirm Docker is on**

`modules/programs/development.nix` provides Docker with auto-start and auto-prune, and it is already imported. Keep the import — the services host needs it. Verify after switch in Step 8.

- [ ] **Step 6: Update latitude's roles in `fleet.json`**

```json
    "latitude": {
      "platform": "nixos",
      "tailnet": { "ip": "100.64.0.2" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client", "services"],
      "detect": { "hostname": "latitude5520" }
    },
```

Dropped: `dev`, `desktop`, `laptop`, `repos`. Added: `backup-hub` (taken from `server`), `services`. Check whether a `services` role already has a handler in `provision/roles/` — if not, either add a stub or leave the role out rather than referencing a role nothing implements.

- [ ] **Step 7: Validate**

```bash
just quick
ssh latitude 'cd /home/me/machines && git pull --ff-only && nix build --dry-run ".#nixosConfigurations.latitude.config.system.build.toplevel"'
```

Note `just quick` treats `nix flake check` failures as non-fatal — the `nix build --dry-run` is the real gate.

- [ ] **Step 8: Apply and verify on the box**

```bash
ssh latitude 'cd /home/me/machines && sudo nixos-rebuild switch --flake .#latitude'
ssh latitude 'systemctl is-active docker; loginctl show-session -p HandleLidSwitch'
```

Expected: `active`, and lid handling `ignore`. Close the lid and confirm over SSH that the box stays reachable.

- [ ] **Step 9: Commit**

```bash
git add hosts/latitude/nixos/configuration.nix fleet.json
git commit -m "feat(latitude): reshape as headless always-on services host"
```

---

### Task 8: Port the homeserver Docker configs from Windows paths to Linux `[vps]`

**Files (in `/home/me/my/vps`):**
- Modify: `homeserver/immich/.env.dist`
- Modify: `homeserver/immich/compose.yml:57-60`
- Modify: `homeserver/navidrome/.env.dist` (`NAVIDROME_DATA_ABS_PATH`, `NAVIDROME_LIBRARY_ABS_PATH`)
- Modify: `homeserver/restic-server/.env.dist` (`RESTIC_DATA_PATH`)
- Modify: `CLAUDE.md`, `README.md` (homeserver is Linux now, not Windows + Docker Desktop)

**Interfaces:**
- Consumes: the mount layout defined here is what Task 11 must create on disk.
- Produces: the canonical host-path mapping every later task references.

- [ ] **Step 1: Fix the mount layout now, in one place**

| Old (Windows) | New (Linux) | Backing |
|---|---|---|
| `D:\ImmichMedia\library` | `/srv/immich/library` | Kingston NVMe (enclosure), NTFS |
| `D:\ImmichMedia\postgres` | `/var/lib/immich/postgres` | **latitude internal NVMe, ext4** |
| `D:\ImmichMedia\library\backups` | `/srv/immich/library/backups` | Kingston NVMe, NTFS |
| `E:\admin\<year>` | `/srv/immich-years/admin/<year>` | WD10 dock bay, NTFS |
| `G:\backup-homeserver\...` | `/srv/backup-1/backup-homeserver/...` | ST1000LM024 dock bay, NTFS |
| `F:\...` (`qb`, `restic-repos`, `secrets`) | `/srv/public/...` | ST320LT020 dock bay, NTFS |
| `H:\backup-homeserver\...` | *(off-site, not mounted)* | HGST, set aside in Task 2 |

Postgres on the internal ext4 NVMe is not optional — a database on an NTFS-over-USB HDD would make Immich miserable, and it is the one dataset small enough (tens of GB) to fit latitude's 329 G free.

- [ ] **Step 2: Rewrite `homeserver/immich/.env.dist`**

```ini
UPLOAD_LOCATION=/srv/immich/library
DB_BACKUPS_LOCATION=/srv/immich/library/backups
DB_DATA_LOCATION=/var/lib/immich/postgres

LOCATION_1970=/srv/immich-years/admin/1970
LOCATION_2007=/srv/immich-years/admin/2007
LOCATION_2008=/srv/immich-years/admin/2008
LOCATION_2009=/srv/immich-years/admin/2009
LOCATION_2010=/srv/immich-years/admin/2010
LOCATION_2011=/srv/immich-years/admin/2011
LOCATION_2012=/srv/immich-years/admin/2012
LOCATION_2013=/srv/immich-years/admin/2013
LOCATION_2014=/srv/immich-years/admin/2014
LOCATION_2015=/srv/immich-years/admin/2015
LOCATION_2016=/srv/immich-years/admin/2016
LOCATION_2017=/srv/immich-years/admin/2017
LOCATION_2018=/srv/immich-years/admin/2018
LOCATION_2019=/srv/immich-years/admin/2019
LOCATION_2020=/srv/immich-years/admin/2020
LOCATION_2021=/srv/immich-years/admin/2021
LOCATION_2022=/srv/immich-years/admin/2022
LOCATION_2023=/srv/immich-years/admin/2023
LOCATION_2024=/srv/immich-years/admin/2024

TZ=Asia/Almaty
IMMICH_VERSION=v2
DB_PASSWORD=
```

Leave `DB_PASSWORD` empty in `.env.dist` — the real `.env` is created on the box and is not committed.

- [ ] **Step 3: Switch machine learning from CUDA to OpenVINO**

`homeserver/immich/compose.yml:57-60` currently reads:

```yaml
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}-cuda
    extends:
      file: hwaccel.ml.yml
      service: cuda
```

Change to:

```yaml
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}-openvino
    extends:
      file: hwaccel.ml.yml
      service: openvino
```

latitude has `intel-compute-runtime` in `hardware.graphics.extraPackages` already. Also check `hwaccel.transcoding.yml` (extended by the server service at line 17-18) and set it to the `quicksync` variant — Tiger Lake has QSV. Expect slower bulk ML re-indexing than the 3050 Ti; steady-state is unaffected.

- [ ] **Step 4: Update the other services' env defaults**

`navidrome/compose.yml:12-13` uses `NAVIDROME_DATA_ABS_PATH` and `NAVIDROME_LIBRARY_ABS_PATH`; `restic-server/compose.yml:8` uses `RESTIC_DATA_PATH`. Point them at `/srv/...` paths consistent with Step 1. `forgejo`, `tugtainer`, `telegrind`, `embedthat` use named Docker volumes only (`forgejo_data`, `tugtainer_data`, `pgdata`, `redis_data`) — those live under `/var/lib/docker` and need no path change, but see Task 13 for migrating their contents.

- [ ] **Step 5: Update the repo docs**

`README.md` and `CLAUDE.md` describe the homeserver as Windows + Docker Desktop and reference `.bat` installers. Correct them to NixOS on latitude at `10.0.0.2`.

- [ ] **Step 6: Commit** (in the `vps` repo, on a branch)

```bash
cd /home/me/my/vps
git checkout -b homeserver-linux-migration
git add homeserver/ README.md CLAUDE.md
git commit -m "feat(homeserver): port paths and hwaccel from Windows/CUDA to Linux/OpenVINO"
```

---

### Task 9: Port the backup profiles and scheduling `[vps]`

**Files:**
- Modify: `backup/homeserver/profiles.yaml`
- Create: `backup/homeserver/install-timers.sh` (systemd replacement for `install-tasks.bat`)
- Delete: `backup/homeserver/install-tasks.bat` (only after the systemd path is verified in Task 15)
- Modify: `vps/caddy/Caddyfile:6`

**Interfaces:**
- Consumes: the path table from Task 8 Step 1.
- Produces: resticprofile profiles whose `repository` and `source` keys are Linux paths, scheduled by systemd user timers.

- [ ] **Step 1: Rewrite the repository and source paths**

Current values are Windows: `repository: "G:\\backup-homeserver\\immich-postgres"`, `source: - "D:\\ImmichMedia\\library\\library"`, `repository: "H:\\backup-homeserver\\immich-media-2024"`. Map them through Task 8's table. The `H:` profile now targets an off-site drive that is normally unmounted — either drop that profile from the automatic schedule or guard it so a missing mount is a skip, not a failure.

- [ ] **Step 2: Use `backup/wsl/profiles.yaml` as the Linux model**

It already exists and already solves the Linux-side conventions. Match its structure rather than inventing a third dialect.

- [ ] **Step 3: Keep the battery guard**

`base-job` in `backup/base.yaml` sets `schedule-ignore-on-battery: true`. On a laptop server that is exactly right — a power cut should not start a multi-hour restic run on battery. Do not remove it.

- [ ] **Step 4: Replace Windows Task Scheduler with systemd user timers**

Write `backup/homeserver/install-timers.sh` calling `resticprofile schedule --all`, which generates systemd units natively. Verify with:

```bash
systemctl --user list-timers 'resticprofile*'
```

Expected: one timer per profile, `NEXT` populated. Note `schedule-permission: user` in `base.yaml` means user timers, so `loginctl enable-linger me` is required or the timers stop when you log out.

- [ ] **Step 5: Fix the Caddy SSH upstream port**

`vps/caddy/Caddyfile:6` forwards public `:2222` to `upstream 10.0.0.2:2222`, but latitude's sshd listens on **22** (`modules/system/ssh-server.nix:34` opens port 22 on `tailscale0`, plus LAN `192.168.8.0/24`). Change the upstream:

```
                    upstream 10.0.0.2:22
```

The `reverse_proxy 10.0.0.2:<port>` lines for Immich (2283), Navidrome (4533), LibreSpeed (2282), qBittorrent (8084), Tugtainer (9412), and Forgejo (3000) all stay exactly as they are, because latitude keeps the `10.0.0.2` tunnel address.

- [ ] **Step 6: Commit**

```bash
git add backup/ vps/caddy/Caddyfile
git commit -m "feat(backup): port homeserver profiles to Linux paths and systemd timers"
```

---

## Phase D — G15 → latitude (the physical move)

### Task 10: Quiesce the G15 and take the final backup `[remote-box]`

- [ ] **Step 1: Stop every service cleanly**

```powershell
docker compose -f homeserver\immich\compose.yml down
# repeat for navidrome, forgejo, restic-server, tugtainer, speedtest, beat, telegrind, embedthat
docker ps
```

Expected: no running containers.

- [ ] **Step 2: Dump the Immich database**

Do **not** copy the PostgreSQL data directory across operating systems. Dump it — this is also what the existing `immich-postgres` restic profile does.

```powershell
docker compose -f homeserver\immich\compose.yml up -d database
docker exec -t immich_postgres pg_dumpall -U postgres > D:\immich-final-dump.sql
docker compose -f homeserver\immich\compose.yml down
```

Verify the dump is non-trivial in size and ends with `-- PostgreSQL database cluster dump complete`.

- [ ] **Step 3: Run a final backup of everything**

```powershell
resticprofile --name immich-media backup
resticprofile --name immich-postgres backup
```

Expected: `snapshot <id> saved` for each. Record the snapshot IDs in the migration log.

- [ ] **Step 4: Disable Windows fast startup and shut down fully**

This matters. Fast startup leaves NTFS volumes flagged dirty, and Linux will refuse to mount them read-write.

```powershell
powercfg /h off
shutdown /s /t 0
```

A full shutdown, not a restart, not sleep.

---

### Task 11: Move the hardware and mount the drives `[physical]`

**Files:**
- Modify: `hosts/latitude/nixos/configuration.nix` (add `fileSystems` entries)

- [ ] **Step 1: Pull the Kingston NVMe from the G15**

Disk 0, `KINGSTON SNV2S1000G`, holds the live library. Leave the WD SN560 (disk 1, `C:`) in the machine — that is what the buyer gets. Install the Kingston per the Task 1 decision (free M.2 slot or enclosure).

- [ ] **Step 2: Move the two docks**

Both docks, externally powered, three of the four bays populated (WD10, ST1000LM024, ST320LT020). The HGST stays off-site per Task 2. Two USB cables plus the NVMe enclosure = three devices; latitude's two 4-port 10 Gbps root hubs handle that without a hub.

- [ ] **Step 3: Enumerate and record UUIDs**

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL
sudo blkid
```

Expected: four NTFS filesystems (Immich, Immich 2024, Immich backup, Public). Copy each UUID into the migration log — the next step needs them and `/dev/sdX` names will shuffle on reboot.

- [ ] **Step 4: Check for the UAS quirk**

Under Linux, some JMicron/ASMedia USB-SATA bridges misbehave with the `uas` driver — resets and I/O errors under sustained write, which is exactly what a restic run produces.

```bash
lsusb
dmesg | grep -iE "uas|usb-storage|reset high-speed|reset SuperSpeed"
```

If you see resets, note the dock's `VID:PID` from `lsusb` and add to `hosts/latitude/nixos/configuration.nix`:

```nix
  boot.kernelParams = ["usb-storage.quirks=<VID>:<PID>:u"];
```

If the docks behave, skip this — do not add the param preemptively.

- [ ] **Step 5: Check SMART passthrough**

```bash
sudo smartctl -d sat -a /dev/sdX
```

If a bridge hides SMART, try `-d usbjmicron`. Whichever dock cannot report SMART should hold your least critical drive.

- [ ] **Step 6: Declare the mounts by UUID**

Add to `hosts/latitude/nixos/configuration.nix`:

```nix
  # Relocated homeserver drives. NTFS for now (see the ext4 conversion
  # follow-up); nofail so a missing dock never blocks boot.
  fileSystems."/srv/immich" = {
    device = "/dev/disk/by-uuid/<KINGSTON-UUID>";
    fsType = "ntfs3";
    options = ["nofail" "x-systemd.device-timeout=30" "uid=1000" "gid=100" "umask=0022"];
  };
  fileSystems."/srv/immich-years" = {
    device = "/dev/disk/by-uuid/<WD10-UUID>";
    fsType = "ntfs3";
    options = ["nofail" "x-systemd.device-timeout=30" "uid=1000" "gid=100" "umask=0022"];
  };
  fileSystems."/srv/backup-1" = {
    device = "/dev/disk/by-uuid/<ST1000LM024-UUID>";
    fsType = "ntfs3";
    options = ["nofail" "x-systemd.device-timeout=30" "uid=1000" "gid=100" "umask=0022"];
  };
  fileSystems."/srv/public" = {
    device = "/dev/disk/by-uuid/<ST320LT020-UUID>";
    fsType = "ntfs3";
    options = ["nofail" "x-systemd.device-timeout=30" "uid=1000" "gid=100" "umask=0022"];
  };
```

`uid=1000`/`gid=100` is user `me` — confirm with `id me` and adjust if it differs.

- [ ] **Step 7: Apply and verify**

```bash
sudo nixos-rebuild switch --flake .#latitude
findmnt /srv/immich /srv/immich-years /srv/backup-1 /srv/public
ls /srv/immich/library | head
ls /srv/immich-years/admin | head -25
```

Expected: four mounts present; the library directory and 19 year directories visible. If a mount fails with "volume is dirty", go back to Task 10 Step 4 — the G15 did not shut down fully. Recover with `sudo ntfsfix /dev/sdX` (and re-do the clean shutdown if the G15 is still available).

- [ ] **Step 8: Reboot and confirm the mounts survive re-enumeration**

```bash
sudo reboot
# then, after it comes back:
findmnt /srv/immich /srv/immich-years /srv/backup-1 /srv/public
```

Expected: all four mounted, from the same UUIDs, regardless of `/dev/sdX` assignment.

- [ ] **Step 9: Commit**

```bash
git add hosts/latitude/nixos/configuration.nix
git commit -m "feat(latitude): mount relocated homeserver drives by UUID"
```

---

### Task 12: Restore the Immich database `[remote-box]`

- [ ] **Step 1: Create the ext4 postgres directory on the internal NVMe**

```bash
sudo mkdir -p /var/lib/immich/postgres
sudo chown 1000:100 /var/lib/immich/postgres
df -h /var/lib/immich
```

Expected: on the LUKS/ext4 root with 329 G free. Immich's DB for ~1.35 TB of media is tens of GB — comfortable.

- [ ] **Step 2: Create the real `.env`**

```bash
cd ~/my/vps/homeserver/immich
cp .env.dist .env
# set DB_PASSWORD to the value from the G15's old .env
```

The old password is required — the dump contains role definitions tied to it. Retrieve it from the G15 (or `F:\secrets`) before that machine is wiped.

- [ ] **Step 3: Start only the database**

```bash
docker compose up -d database
docker compose logs -f database
```

Expected: `database system is ready to accept connections`. The image is pinned by digest (`postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf6…`), so the restore target matches the dump source exactly.

- [ ] **Step 4: Restore the dump**

Copy `immich-final-dump.sql` from the Kingston (it was written to `D:\`, now `/srv/immich/`) and load it:

```bash
docker exec -i immich_postgres psql -U postgres < /srv/immich/immich-final-dump.sql
```

- [ ] **Step 5: Verify the asset count matches**

```bash
docker exec -t immich_postgres psql -U postgres -d immich -c "select count(*) from assets;"
```

Expected: the same count the G15 reported before shutdown. **Record that number during Task 10** — you cannot compare against a number you never took.

---

### Task 13: Bring the services up `[remote-box]`

- [ ] **Step 1: Start Immich in full**

```bash
cd ~/my/vps/homeserver/immich && docker compose up -d
docker compose ps
```

Expected: `immich-server`, `immich-machine-learning`, `valkey`, `database` all healthy.

- [ ] **Step 2: Verify the library loads without a re-import**

Open Immich on the LAN (`http://latitude.gg.ez:2283`). Check: total asset count matches Task 12 Step 5; thumbnails render; a photo from 2012 and one from 2024 both open. Because the compose file bind-mounts to fixed container paths (`/data/library/admin/<year>`), the DB's stored paths are unchanged — if assets show as missing, a host mount is wrong, not the database.

- [ ] **Step 3: Verify OpenVINO machine learning is actually being used**

```bash
docker compose logs immich-machine-learning | grep -i "openvino\|provider\|device"
```

Expected: OpenVINO execution provider, not a CPU fallback. A CPU fallback works but will be very slow on Tiger Lake.

- [ ] **Step 4: Migrate the named-volume services**

`forgejo` (`forgejo_data`), `tugtainer` (`tugtainer_data`), `telegrind` (`pgdata`), `embedthat` (`redis_data`) keep their data in Docker named volumes, which live inside Docker's storage and did **not** come across on the drives. For each: export from the G15 before wipe (`docker run --rm -v <vol>:/from -v $PWD:/to alpine tar cf /to/<vol>.tar -C /from .`), copy over, and import on latitude with the inverse. Do this **before** Task 16.

- [ ] **Step 5: Start the rest**

```bash
for s in navidrome forgejo restic-server tugtainer speedtest beat telegrind embedthat; do
  docker compose -f ~/my/vps/homeserver/$s/compose.yml up -d
done
docker ps --format '{{.Names}}\t{{.Status}}'
```

Expected: all containers up. `beat` bind-mounts `./tasks` and `./logs` from the repo checkout — make sure `~/my/vps` is cloned on latitude.

---

### Task 14: Cut the WireGuard tunnel over to latitude `[remote-box]` `[vps]`

- [ ] **Step 1: Generate latitude's keypair**

```bash
wg genkey | tee /tmp/lat.key | wg pubkey > /tmp/lat.pub
cat /tmp/lat.pub
```

- [ ] **Step 2: Swap the peer on the VPS**

```bash
ssh hub
cd /path/to/vps/vps
sudo bash manage-peers.sh show
sudo bash manage-peers.sh remove homeserver
sudo bash manage-peers.sh add homeserver 10.0.0.2 <latitude-pubkey>
sudo bash manage-peers.sh list
```

`manage-peers.sh` validates that the IP is not already in use, so the old peer must be removed first. Reusing `10.0.0.2` is what keeps the whole Caddyfile valid.

- [ ] **Step 3: Bring the tunnel up on latitude**

Use the config printed by the setup script (`vps/awg/wg0-homeserver.dist.conf` is the template: `Address = 10.0.0.2/24`, `AllowedIPs = 10.0.0.0/24`). Install it as a systemd-managed WireGuard interface so it survives reboot.

```bash
sudo wg show
ping -c2 10.0.0.1
```

Expected: handshake present, VPS reachable.

- [ ] **Step 4: Deploy the Caddyfile change from Task 9 Step 5**

```bash
ssh hub 'cd /path/to/vps/vps && sudo bash deploy-caddy.sh'
```

- [ ] **Step 5: Verify every public route end-to-end**

From outside the tailnet (phone on mobile data is the honest test):

| URL | Expect |
|---|---|
| `https://immich.cyphy.kz` | login page, then the library |
| `https://navi.cyphy.kz` | Navidrome, music plays |
| `https://speed.cyphy.kz` | LibreSpeed runs |
| `https://tug.cyphy.kz` | Tugtainer |
| `https://qb.cyphy.kz` | qBittorrent |
| `ssh -p 2222 <user>@cyphy.kz` | lands on latitude |

The SSH one is the check for the port fix in Task 9 Step 5.

---

### Task 15: Verify the backups restore on the new host `[remote-box]`

**This is the gate for the sale. Do not skip it and do not soften it.**

- [ ] **Step 1: Check every relocated repo**

```bash
cd /srv/backup-1/backup-homeserver
restic -r ./immich-postgres --password-file <pass> check --read-data-subset 5%
restic -r ./immich-media    --password-file <pass> check --read-data-subset 5%
```

Expected: `no errors were found` for each.

- [ ] **Step 2: Do a real test restore, not just a check**

```bash
mkdir -p /tmp/restore-test
restic -r /srv/backup-1/backup-homeserver/immich-media --password-file <pass> \
  restore latest --target /tmp/restore-test --include <one known file path>
```

Verify the restored file opens and its checksum matches the live copy. A `check` proves the repo is internally consistent; only a restore proves you can get data back out on this machine.

- [ ] **Step 3: Confirm the schedule fires**

```bash
systemctl --user list-timers 'resticprofile*'
loginctl show-user me -p Linger
```

Expected: timers with populated `NEXT`, and `Linger=yes`.

- [ ] **Step 4: Run one full backup cycle on latitude and confirm a new snapshot**

```bash
resticprofile --name immich-media backup
restic -r /srv/backup-1/backup-homeserver/immich-media --password-file <pass> snapshots | tail -3
```

Expected: a new snapshot dated today with `latitude5520` as host.

- [ ] **Step 5: Record the gate result in the migration log**

Write down: repos checked, file restored, checksum matched, new snapshot ID. Only now may Task 16 proceed.

---

## Phase E — Retire the G15

### Task 16: Wipe and list the G15 `[physical]`

Blocked on Task 15 passing. Everything here is irreversible.

- [ ] **Step 1: Final confirmation checklist**

Confirm each, out loud, against the migration log:
- Immich asset count on latitude matches the pre-shutdown count (Task 12 Step 5).
- All public routes serve from latitude (Task 14 Step 5).
- `restic check` clean **and** a test restore succeeded on latitude (Task 15 Steps 1-2).
- Named-volume services exported and re-imported (Task 13 Step 4).
- Everything from `F:\secrets` is copied somewhere safe and is not only on that drive.
- The Kingston NVMe is physically out of the G15.

- [ ] **Step 2: Harvest anything left on `C:`**

`C:` has 459 G used. Check for: the Immich `.env` with the real `DB_PASSWORD`, WireGuard private keys, restic password files, SSH host keys, Docker Desktop settings, `G614JV-Ubuntu-24.04.tar` (also on `F:`), browser profiles, anything under the user profile.

- [ ] **Step 3: Remove the G15 from the tailnet**

```bash
ssh hub 'headscale nodes list'
ssh hub 'headscale nodes delete -i <g513ie-node-id>'
```

- [ ] **Step 4: Revoke its access**

Remove the G15's public key from `provision/fleet-authorized-keys` and from any `authorized_keys` on the other fleet members and the VPS.

- [ ] **Step 5: Wipe `C:` and reinstall Windows**

Use the shared media in `install-media/` and the scripts under `hosts/desktop/windows/`. A clean install over the SN560 is the right level of wipe for an SSD being sold; a full-disk overwrite is unnecessary on an encrypted-at-rest NVMe and just burns write cycles. If BitLocker was on, the key destruction alone makes the old data unrecoverable.

- [ ] **Step 6: List it** — with the SN560 in and the Kingston out.

---

## Phase F — Repo cleanup

### Task 17: Remove the retired host from both repos `[machines]` `[vps]`

**Files:**
- Delete: `hosts/server/windows/` (entire directory)
- Modify: `fleet.json` (remove the `server` entry)
- Modify: `CLAUDE.md` (repository overview, hostname convention, hardware context)
- Modify: `.claude/memory/project.md`
- Modify: `agents/plugin/skills/lib/fleet-dispatch.sh` if it special-cases `server`

- [ ] **Step 1: Find every reference**

```bash
grep -rn "g513ie\|methe-server\|homeserver\|100\.64\.0\.3" --include='*.md' --include='*.json' --include='*.nix' --include='*.sh' --include='*.ps1' . | grep -v '\.git/'
```

Work through the list. Expect hits in `CLAUDE.md`'s repository overview and hostname-convention sections, `.claude/memory/project.md`, and possibly the fleet dispatch helper.

- [ ] **Step 2: Remove the `server` entry from `fleet.json`**

Note the `backup-hub` role already moved to latitude in Task 7 Step 6, so nothing is orphaned.

- [ ] **Step 3: Delete `hosts/server/windows/`**

```bash
git rm -r hosts/server/windows
```

- [ ] **Step 4: Rewrite the CLAUDE.md fleet description**

Three members plus the VPS: `air` (MacBook Air M5, macOS, primary to-go dev), `desktop` (G614JV, Windows, gaming + always-on Orca daemon + WSL Ubuntu 26), `latitude` (NixOS, always-on services host at `10.0.0.2`), `hub` (Debian VPS). Update the two-layer hostname-convention section: `air`/`air` is a new logical/OS pair; `g513ie` is gone.

- [ ] **Step 5: Validate**

```bash
just quick
bash provision/tests/fleet-profile.test.sh
bash provision/tests/fleet-local.test.sh
ssh latitude 'cd /home/me/machines && git pull --ff-only && nix build --dry-run ".#nixosConfigurations.latitude.config.system.build.toplevel"'
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore(fleet): retire g513ie, remove the server host"
```

- [ ] **Step 7: Same cleanup in the `vps` repo**

Remove Windows-only artifacts now dead: `backup/homeserver/install-tasks.bat`, `backup/restic-install.bat`, `homeserver/awg-restart-task.ps1` (a Windows Task Scheduler helper). Check each for a Linux equivalent before deleting.

```bash
cd /home/me/my/vps
git rm backup/homeserver/install-tasks.bat backup/restic-install.bat homeserver/awg-restart-task.ps1
git commit -m "chore(homeserver): drop Windows-only backup and task artifacts"
```

---

### Task 18 (optional): Rename the `latitude` fleet key to `server` `[machines]`

Deliberately last and deliberately optional. The repo's convention is that logical names are role-based (`desktop`, `server`, `hub`), so a services host called `latitude` is drift. But renaming touches the fleet key, the SSH alias, the flake attribute, and the `hosts/` directory — churn you do not want while a migration is in flight.

**Files:**
- Rename: `hosts/latitude/` → `hosts/server/`
- Modify: `flake.nix` (the `latitude` nixosConfiguration attr)
- Modify: `fleet.json`, `CLAUDE.md`, `.claude/memory/project.md`, `justfile` (any `#latitude` references)

- [ ] **Step 1: Confirm you want the churn.** If not, close this task and record in `.claude/memory/project.md` that `latitude` is intentionally keeping its name.
- [ ] **Step 2:** `networking.hostName` stays `latitude5520` — only the logical name changes. That is exactly the pattern from the earlier `g16` → `desktop` rename.
- [ ] **Step 3:** Grep for `latitude`, update every hit, run `just quick` plus the dry-build, and switch on the box so the regenerated `~/.ssh/config` is proven before you rely on the new alias.
- [ ] **Step 4: Commit** — `refactor(fleet): rename latitude to server to match the role-based convention`.

---

### Task 19 (follow-up, separate project): Convert the media drives to ext4

Out of scope for the cutover; captured so it is not lost.

NTFS-over-USB works for large read-mostly media but costs performance and gives up POSIX ownership. Converting means a drive-by-drive shuffle: with the 2 TB staging drive from Task 1 it is a straight copy per drive; without it, free space must be juggled (move `/srv/backup-1`'s 158 G onto the off-site HGST's 281 G free, reformat, copy, repeat). Do it one drive at a time, verifying checksums, with the off-site copy present throughout. Also revisit whether the Kingston should hold the Immich thumbnail/upload tier on ext4 for the latency win.

---

## Self-Review

**Spec coverage** — the user's five steps map as: *latitude → macOS* = Tasks 3-6; *latitude switch to server role + adjust vps* = Tasks 7-9; *g15 → latitude* = Tasks 10-14; *retire g15* = Tasks 15-16; *run latitude* = Tasks 13, 15, and the Task 17 cleanup. Tasks 1-2 are prep the user did not ask for but that gate hardware purchases and close the backup gap. Tasks 18-19 are explicitly optional/deferred.

**Known gaps, stated rather than hidden:**
- The exact per-host memory path `agents/bootstrap.sh` reads is flagged for confirmation in Task 6 Step 2 rather than asserted.
- Whether a `services` role has an implementation in `provision/roles/` is flagged in Task 7 Step 6 rather than assumed.
- Navidrome's music library location was never inventoried on the G15 — Task 8 Step 4 assigns it a `/srv` path, but which physical drive holds the music today must be checked before that mount is declared.
- The `qb` (qBittorrent) download path and the `telegrind`/`embedthat`/`beat` env requirements are covered generically in Tasks 8 and 13; each needs its `.env.dist` read before that task runs.
