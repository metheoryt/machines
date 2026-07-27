# Fleet Migration: MacBook Primary, latitude → Server, Retire G15

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan spans two repos and physical hardware.** Tasks are tagged `[machines]`, `[vps]`, `[physical]`, or `[remote-box]`. Physical tasks cannot be done by an agent — they are checkpoints for the human.

**Goal:** Make the MacBook Air M5 the primary dev machine, convert latitude5520 from dev laptop to the always-on services host, move the homeserver's data off the G15 (g513ie), and retire/sell the G15.

**Architecture:** Three surviving fleet members plus the VPS. `air` (MacBook, to-go dev, repos local) → `desktop` (G614JV, gaming + always-on Orca daemon + WSL Ubuntu 26 for amd64 work) → `latitude` (NixOS, always-on Docker services host, takes over `10.0.0.2` behind the VPS Caddy). `hub` (VPS) unchanged. The four 2.5" HDDs live in two externally-powered 2×2 docks that move from the G15 to latitude; the G15's internal Kingston NVMe (live Immich library) moves into a USB/TB3 enclosure.

**Tech Stack:** NixOS 25.05 + flakes + Home Manager, Docker Compose, Headscale/Tailscale (`cc.cyphy.kz`, `gg.ez`), WireGuard/AmneziaWG to the VPS, Caddy (+`caddy-l4`), restic + resticprofile, Immich/Navidrome/qBittorrent/Tugtainer/LibreSpeed.

## Global Constraints

- **The G15 is the only copy of some data until Task 15 passes.** No wipe, no sale, no reformat of any drive before the restore verification in Task 15 succeeds.
- **latitude keeps WireGuard address `10.0.0.2`.** Reusing the homeserver's tunnel IP means every surviving `reverse_proxy` target in `vps/caddy/Caddyfile` stays byte-identical. The only Caddyfile edits in this plan are **deletions** for the Forgejo retirement (Task 9 Step 5).
- **Forgejo is retired, not migrated.** Verified 2026-07-27: the container is stopped and `forgejo_data` is 4.0 K with no `git/repositories` directory — it hosts nothing. Both `machines` and `vps` have GitHub (`git@github.com:metheoryt/*`) as `origin`. Nothing anywhere references `git.cyphy.kz` as a remote. Delete it; do not export it.
- **The l4 `:2222` block is Forgejo's git-over-SSH, not host shell access.** It goes away with Forgejo. If you ever keep it, never repoint it at port 22 — `modules/system/ssh-server.nix:34` restricts host sshd to `tailscale0` + LAN `192.168.8.0/24`, and an internet-facing proxy would defeat that.
- **Immich container-side paths must not change.** The compose file bind-mounts `${LOCATION_<year>}:/data/library/admin/<year>`. Host paths change; container paths stay identical, so the Immich DB needs no path rewrite and no re-import.
- **Mount every external drive by UUID**, never by `/dev/sdX`. Five USB block devices across two docks have no stable enumeration order.
- **NTFS stays NTFS for this migration.** Converting 1.35 TB of media to ext4 is a separate follow-up project (Task 19), not part of the cutover. Only PostgreSQL and Docker's own storage move to ext4 on latitude's internal NVMe.
- **`nix flake check` / `just quick` can only run on latitude.** It is the fleet's only Nix host. Any `[machines]` task that changes Nix must be validated there.
- **Never validate Nix with `ssh latitude 'cd /home/me/machines && git pull --ff-only && nix build --dry-run …'`.** That idiom (originally written into Task 3 Step 7, Task 7 Step 7, Task 17 Step 5) is wrong twice over. The session already *runs on* latitude, so the `ssh` hop is a no-op detour; and `/home/me/machines` is the **base checkout on `main`**, while this plan's commits live on a worktree branch — the pull fetches `origin/main` and the dry-build evaluates the *pre-change* tree, passing vacuously. Run it locally from the worktree instead:

  ```bash
  nix build --dry-run '.#nixosConfigurations.latitude.config.system.build.toplevel'
  ```

  To prove a `fleet.json` change actually reached the generated SSH config (it feeds `modules/system/fleet.nix` → `modules/home/ssh.nix`), build the file and read it:

  ```bash
  nix build --no-link --print-out-paths \
    '.#nixosConfigurations.latitude.config.home-manager.users.me.home.file.".ssh/config".source'
  ```
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

**Services (`vps` repo, `homeserver/`):** `immich`, `navidrome`, `restic-server`, `tugtainer`, `speedtest`, `beat`, `telegrind`, `embedthat`. Public routes in `vps/caddy/Caddyfile` all point at `10.0.0.2`.

**Retired in this migration:** `forgejo` (empty volume, stopped container, staying on GitHub — see Task 8 Step 0 and Task 9 Step 5).

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

Recommended: yes. It removes the only genuinely risky step in this whole programme (the free-space shuffle in Task 19) and it becomes a second off-site copy on top of the one set aside in Task 2. Without it, both the live library and its only backups end up in one chassis on latitude.

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

- [ ] **Step 4: Record the gap this does *not* close**

Setting `H:` aside protects the years archive (`E:`). It does **not** protect the live upload tier on the Kingston, whose only backup repo is `G:` — and after Task 11 both the Kingston and `G:` sit in the same room on latitude. That is still strictly better than today (where all five volumes share one chassis), but it is not full closure. Full closure is the 2 TB drive from Task 1 Step 2, or the ext4/rotation work in Task 19. Write the residual gap in the migration log so it does not quietly become permanent.

- [ ] **Step 5: No commit** — physical/operational step. Note the outcome in the migration log you started in Task 1.

---

## Phase B — latitude → macOS (Mac becomes primary)

### Task 3: Teach the fleet libraries about the `darwin` platform `[machines]` — ✅ DONE (`62babbd`)

`fleet.json` currently only carries `nixos`, `windows`, `debian`. Dispatch code branches on platform, so add `darwin` before adding the machine.

**The file list this task originally carried was mostly wrong.** Recorded here as executed, because later tasks depend on knowing where platform dispatch actually lives:

| Originally listed | Reality |
|---|---|
| `provision/lib/fleet.sh` | **No platform branching at all** — it only reads the manifest with `jq`. `fleet_platform air` returns `darwin` the moment the entry exists. Not modified. |
| `provision/lib/Fleet.psm1` | Same — pure `ConvertFrom-Json` accessors. Not modified. |
| `agents/plugin/skills/lib/fleet-dispatch.sh` | Already correct: `fd_probe`/`fd_run`/`fd_wsl_hosts` branch `windows)` vs `*)`, so `darwin` already lands in the POSIX arm. Not modified — but **pinned with a test**, because nothing otherwise proves it. |
| *(missed entirely)* | `provision/roles/agents.sh:19`, `provision/roles/dotfiles.sh:39`, `provision/roles/repos.sh:20` — **the real platform `case`s**, and the actual edits. |

**The silent-failure mode that made this matter:** each role executor ends its `case` with a `*)` arm that prints `no posix executor for platform '<p>' (skipped)` and **returns 0**. An unlisted platform therefore provisions nothing and still reports success. `provision/tests/roles.test.sh` (new) guards this for all three roles.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `fleet_platform` returns `darwin` for the new host; `fd_probe`/`fd_run` treat `darwin` like a POSIX-SSH host (same branch as `nixos`/`debian`), **not** like `windows` (which tunnels through Git Bash via PowerShell's call operator).

- [x] **Step 1: Read the current platform branching** — see the table above.

- [x] **Step 2-3: Write the failing tests, confirm they fail**

Three assertions, because one alone does not discriminate. `eq "$(fleet_platform air)" "darwin"` in `fleet-profile.test.sh` only exercises a JSON lookup — it goes green the instant the manifest entry lands, without ever proving a `darwin` arm exists. The load-bearing ones:

- `provision/tests/roles.test.sh` — asserts each role executor's output does **not** contain `no posix executor for platform`, i.e. `darwin` reached a real arm. Also regression-guards that `nixos` still *deliberately* defers `agents`/`dotfiles` to home-manager (a real arm, not the fallthrough).
- `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh` — with the file's documented `SSH` mock hook, asserts `fd_probe air darwin` emits `bash -c true` and contains **no** `bash.exe`, and that `fd_run air darwin` produces the identical `bash -s --` shape as `nixos`.

Observed on first run: `fleet_platform air` → `null`, all three roles → skip arm. The dispatch test passed immediately (already-correct behaviour, now pinned).

- [x] **Step 4: Add the `air` entry to `fleet.json`**

```json
    "air": {
      "platform": "darwin",
      "tailnet": { "ip": "100.64.0.7" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "air" }
    },
```

**`100.64.0.7`, not `.5`.** The original `.5` claim assumed the fleet was hub/.1, latitude/.2, server/.3, desktop/.4. Live `headscale nodes list` (2026-07-27) shows two more nodes: **`.5` is `ipheoryt12`** (the iPhone) and **`.6` is `desktop-ubuntu26`** (the self-declared WSL host). Booking `.5` would not have failed here — it would have failed silently at Task 5 Step 3, after the Mac had already joined on a different address.

No `ssh.user` is set, so `modules/home/ssh.nix:34` emits no `User` override and the block defaults to **`me`**. If the macOS account name is not `me`, add `"ssh": { "user": "<name>" }` — see Task 5.

- [x] **Step 5: Add the `darwin` arms** — per-role reasoning, not one mechanical arm:

| File | Arm | Why |
|---|---|---|
| `roles/agents.sh` | `wsl\|debian\|darwin)` | Groups with the POSIX hosts, **not** `nixos`. No home-manager owns the config on macOS, and `agents/bootstrap.sh:25` already branches on `uname -s` and handles Darwin — so the dispatcher must run it. |
| `roles/dotfiles.sh` | `wsl\|debian\|darwin)` | chezmoi is the *only* dotfiles mechanism on macOS. `get.chezmoi.io` serves a darwin/arm64 build, so `_dotfiles_ensure_chezmoi` works unchanged. |
| `roles/repos.sh` | `nixos\|wsl\|debian\|darwin)` | `provision/repos.sh` is host-agnostic plain git; cloning is imperative, so unlike agents/dotfiles this is not a nixos no-op either. |

- [x] **Step 5b: Commit `agents/hosts/air.md` — in THIS task, not Task 6**

`provision/tests/tiers.test.sh:75-79` iterates `.machines[].detect.hostname` and asserts a committed stub at **`agents/hosts/<hostname>.md`**. Adding `air` to `fleet.json` turns that suite red until the stub exists. It is not cosmetic: `agents/bootstrap.sh` seeds a missing stub *inside the repo*, leaving the tree dirty and permanently disabling `fleet-selfpull`'s clean-tree gate on that box.

**This also resolves Task 6 Step 2's flagged unknown.** The path is `agents/hosts/air.md` — **not** `~/machines/hosts/air.md`. Top-level `hosts/` holds NixOS/Windows machine configs (`hosts/latitude/nixos/…`); per-host *memory* lives under `agents/hosts/`, symlinked to `~/.claude/host-memory.md`.

- [x] **Step 6: Run the tests** — all 8 test files in the repo, not just the three listed:

```bash
for t in provision/tests/*.test.sh agents/plugin/skills/lib/tests/*.test.sh \
         provision/fleet-selfpull.test.sh provision/ssh-wsl.test.sh provision/tailscale-wsl.test.sh; do
  printf '%-52s ' "$t"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL
done
```

Expected: all PASS.

> **Pre-existing red baseline, fixed in `1c29ecb` before this task.** `tiers.test.sh` had been failing since the hermes commits (`9494167`, `5a35479`) added `hermes` to the agent-CLI tier and appended `tier_hermes_config` / `tier_hermes_dashboard` to the workstation list in `provision/linux.sh:67-68` without updating the test's expected string. Any task gating on "tests pass" would have been blocked by it.

- [x] **Step 7: Validate the Nix side** — locally, from the worktree. See the Global Constraint on the broken `ssh latitude 'git pull'` idiom.

```bash
nix build --dry-run '.#nixosConfigurations.latitude.config.system.build.toplevel'
nix build --no-link --print-out-paths \
  '.#nixosConfigurations.latitude.config.home-manager.users.me.home.file.".ssh/config".source'
```

Expected: evaluates clean, `hm_.sshconfig.drv` appears in the rebuild set (proof the manifest change reached `ssh.nix`), and the built file contains a `Host air` block. Confirmed 2026-07-27.

- [x] **Step 8: Commit** — `62babbd`.

---

### Task 4: Add a macOS provisioning path `[machines]` — ✅ DONE (`04c0309`)

`provision/` is apt-Linux/WSL only (`provision/README.md` says so explicitly). `agents/bootstrap.sh` already branches on `uname -s` and handles macOS, so only the tool-install tier needs a Darwin sibling.

> **Correction — `provision.sh` never calls `linux.sh`.** This task was written assuming a platform dispatcher that does not exist. There are two independent entry points:
>
> | Entry point | What it is | How it runs |
> |---|---|---|
> | `provision/linux.sh` | The **tier driver** — a standalone script whose tier list lives in `provision/lib/tiers.sh`. Installs the toolchain. | `bash provision/linux.sh` directly (per `provision/README.md:29`). Preview with `MACHINES_TIERS_DRY_RUN=1`. |
> | `provision/provision.sh` | The **role front door** — reads `fleet.json`, loops `roles[]`, calls `role_<name>` from `provision/roles/*.sh`. Never invokes a tier driver. | `bash provision/provision.sh --machine air --dry-run` |
>
> So `macos.sh` is a **standalone sibling of `linux.sh`**, invoked as `bash provision/macos.sh`. There is no `darwin → macos.sh` arm to add to `provision.sh`; the role-side `darwin` work was Task 3 Step 5 and is already done.
>
> **The argv in the original Step 4 (`provision/provision.sh air dry-run`) is not the real interface** — `provision.sh:19-25` parses `--machine <name>` / `--dry-run` / `--apply` and exits 2 with `unknown arg: air` on a bare positional. Same error is repeated in Task 6 Step 1.

**Files:**
- Create: `provision/macos.sh` (standalone tier driver, sibling of `linux.sh`)
- Modify: `provision/README.md` (add a macOS section)
- Modify: `provision/lib/tiers.sh` **only if** a tier body needs a Darwin branch (see Step 2)

**Interfaces:**
- Consumes: `fleet_platform` returning `darwin` (Task 3) — used by `provision.sh`'s role loop, which already works for `air` as of Task 3.
- Produces: `provision/macos.sh`, honouring the same `MACHINES_TIERS_DRY_RUN=1` / `MACHINES_PROFILE=<p>` env contract as `linux.sh` so `tiers.test.sh`-style assertions can drive it.

- [ ] **Step 1: Read `provision/linux.sh` end to end**

```bash
cat provision/linux.sh
```

It is the template. `macos.sh` mirrors its structure and its CORE/best-effort split; only the package manager changes.

- [ ] **Step 2: Write `provision/macos.sh`**

Same CORE set as Linux (`git`, `curl`, `python3`, `ripgrep`, `fd`, `fzf`, `jq`), installed with Homebrew instead of apt; same best-effort set (`gortex` pinned to `pkgs/gortex.nix`, `claude`, `codex`, `gh`, `starship`, `direnv`, `fish`, `uv`, `git-delta`, `bat`). Keep the same abort-on-CORE-failure, warn-on-best-effort semantics. Two Darwin differences to handle explicitly:

- `fd` and `bat` install under their real names via brew — the Debian `fdfind`/`batcat` aliasing in `provision/lib/tiers.sh` must not run.
- `git-autofetch` is scheduled with a systemd user timer on Linux; on macOS use a `launchd` LaunchAgent plist in `~/Library/LaunchAgents/`.

- [ ] **Step 3: (superseded)** — no `provision.sh` change. The `darwin` role arms landed in Task 3 Step 5; see the correction box above.

- [ ] **Step 4: Dry-run both entry points**

```bash
# tier driver (the new file)
MACHINES_TIERS_DRY_RUN=1 bash provision/macos.sh

# role front door — note the flag syntax, not bare positionals
bash provision/provision.sh --machine air --dry-run
```

Expected: the tier driver prints its planned tier list and writes nothing; the front door prints `▸ Machine: air   platform: darwin   mode: dry-run` and a plan line per role, with **no** `no posix executor for platform 'darwin'` anywhere in the output.

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

- [ ] **Step 1b: Verify the hostname is BARE `air`, not `air.local`**

```bash
hostname
uname -n
```

Both must print exactly `air`. macOS frequently keeps handing back `air.local` (or a DHCP-assigned name) even after `scutil`, and `fleet_detect` / `fleet_profile_for_host` match `detect.hostname` with **exact string equality**. If it returns `air.local`, three things break quietly:

1. `provision/macos.sh` prints `profile: workstation (default)` instead of `(from fleet.json)` — it still works, but it is no longer manifest-driven.
2. `provision/provision.sh` cannot auto-detect the machine and drops to the interactive `select` prompt.
3. `agents/bootstrap.sh` seeds a **second** stub at `agents/hosts/air.local.md` *inside the repo*, dirtying the tree and permanently disabling `fleet-selfpull`'s clean-tree gate — exactly the failure `tiers.test.sh` exists to prevent.

If `.local` persists, the reliable fix is to also clear the DHCP-supplied name: `sudo scutil --set HostName air` again after a reboot, and check `sudo scutil --get HostName`. Do not paper over it by adding an `air.local` entry to `fleet.json`.

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

Expected: **`100.64.0.7`** (`.5` is `ipheoryt12`, `.6` is `desktop-ubuntu26` — see Task 3 Step 4). If Headscale assigned something else, either reassign it there or update `fleet.json` — they must agree.

- [ ] **Step 3b: Check the macOS account name against the SSH default**

```bash
whoami
```

`modules/home/ssh.nix:34` only emits a `User` line when `fleet.json`'s `ssh.user` differs from the default `me`, and `air` currently sets none — so the generated `Host air` block resolves to `me`. If `whoami` is anything else, add `"ssh": { "user": "<name>" }` to the `air` entry and re-run the dry-build, or every `ssh air` from another fleet member authenticates as the wrong user.

- [ ] **Step 4: Verify reachability both ways**

```bash
ping -c2 latitude.gg.ez && ping -c2 desktop.gg.ez
```

> **`ssh latitude` will NOT work at this point, and that is expected.** The bare-name blocks come from `~/.ssh/config`, which on a Mac nothing has written yet. On NixOS `modules/home/ssh.nix` generates it; on a WSL distro `provision/ssh-wsl.sh` does; macOS has neither, and `tier_ssh_accounts` is **not** a substitute — it writes only the GitHub-account blocks. Without a fleet block, `ssh latitude` resolves via the MagicDNS search suffix at best and then authenticates as the local macOS account with no identity file.
>
> This is closed by **`tier_fleet_ssh`**, which runs inside `provision/macos.sh` in Task 6 Step 1. It reuses `ssh-wsl.sh`'s renderer (via its `SSH_WSL_LIB_ONLY` hook) so all three platforms emit the same blocks from the same `fleet.json`. Defer the outbound check to Task 6 Step 1b.

Inbound only for now — from latitude, after Step 5: `ssh air 'echo ok'`.

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
git clone git@github.com:metheoryt/machines.git ~/machines
cd ~/machines

# 1. toolchain (standalone tier driver — preview first)
MACHINES_TIERS_DRY_RUN=1 bash provision/macos.sh
bash provision/macos.sh

# 2. roles (front door — flag syntax, NOT `provision.sh air apply`)
bash provision/provision.sh --machine air --apply
```

Expected: CORE tools installed, `agents/bootstrap.sh` runs, `~/.claude` and `~/.codex` get the shared symlink set (memory stores, `CLAUDE.md`, `plugin/`, `agents/hosts/air.md` → `host-memory.md`).

- [x] **Step 2: Create the per-host memory file** — ✅ already done in Task 3 Step 5b.

The path is **`agents/hosts/air.md`** (committed in `62babbd`), not `~/machines/hosts/air.md`. Top-level `hosts/` holds NixOS/Windows machine configs; per-host memory lives under `agents/hosts/`. It had to ship with the `fleet.json` entry because `provision/tests/tiers.test.sh:75-79` asserts a committed stub per manifest hostname — and because `bootstrap.sh` seeding a missing one would dirty the repo and disable `fleet-selfpull`'s clean-tree gate. Nothing to do here; just confirm the symlink resolves after Step 1:

```bash
readlink ~/.claude/host-memory.md   # → …/machines/agents/hosts/air.md
```

- [ ] **Step 1b: Register the generated SSH keys BEFORE any further clone** ⚠️

`macos.sh` runs `tier_ssh_accounts`, which writes a `~/.ssh/config` block with **`IdentitiesOnly yes`** pointing at freshly generated keys (`~/.ssh/id_metheoryt`, `~/.ssh/id_cyphy671`) that GitHub has never seen. `IdentitiesOnly` means ssh will offer *only* that key — so from this moment every `git clone`/`push` over SSH fails until the key is registered. This is the documented hazard that makes the `hub` profile skip the tier entirely (`provision/lib/tiers.sh`, `tier_ssh_accounts` header). The tier does warn, but the warning scrolls past inside a 13-tier run.

The Step 1 clone of `machines` itself is fine — it happens before `macos.sh` runs. Everything after is not.

```bash
gh auth login          # SSH → select ~/.ssh/id_metheoryt.pub
ssh -T git@github.com  # expect: "Hi metheoryt! You've successfully authenticated"
ssh -T git@github-cyphy
```

- [ ] **Step 1c: Verify outbound fleet SSH now works**

`tier_fleet_ssh` (also in the `macos.sh` run) writes the fleet host blocks that Task 5 Step 4 deliberately deferred:

```bash
grep -A3 '^Host latitude$' ~/.ssh/config
ssh latitude 'echo ok'
```

It also generates `~/.ssh/id_fleet` and prints an **ENROLLMENT NEEDED** warning with the public key. Until that key is in `provision/fleet-authorized-keys` and pulled on the other members, no fleet box will accept an inbound connection from the Mac:

```bash
cat ~/.ssh/id_fleet.pub >> ~/machines/provision/fleet-authorized-keys
cd ~/machines && git add provision/fleet-authorized-keys \
  && git commit -m "feat(fleet): trust air's fleet key" && git push
# then on each other member: git pull  (NixOS: plus a rebuild so keyFiles re-reads)
```

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
  boot.supportedFilesystems.ntfs = true;
```

On 25.05 this option takes the attrset form. If the dry-build in Step 7 rejects it, the list form (`boot.supportedFilesystems = ["ntfs"];`) is the older spelling — use whichever the evaluator accepts.

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

Dropped: `dev`, `desktop`, `laptop`, `repos`. Added: `backup-hub` (taken from `server`), `services`.

> **Resolved 2026-07-27 (was flagged unconfirmed).** `provision/roles/` contains exactly three executors — `agents`, `dotfiles`, `repos` (each with a `.sh` and a `.ps1`). There is **no `role_services`**, and none of `base`, `ssh-server`, `backup-hub`, `backup-client`, `laptop`, `desktop`, `dev` has one either. `provision.sh:72-78` handles that gracefully: on `--dry-run` it prints `• <role> — plan: would converge via the <platform> executor for '<role>'`, and on `--apply` it prints `✗ <role> — apply: not yet implemented (skipped)` and moves on. So adding `services` is declarative-only and breaks nothing — it documents intent for a future executor. Add it; do not block on writing one.

- [ ] **Step 7: Validate**

```bash
just quick
nix build --dry-run '.#nixosConfigurations.latitude.config.system.build.toplevel'
```

Note `just quick` treats `nix flake check` failures as non-fatal — the `nix build --dry-run` is the real gate. Run it **locally from the worktree**, not through `ssh latitude 'git pull …'` — see the Global Constraint.

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

- [ ] **Step 0: Retire Forgejo**

Staying on GitHub. Safe to delete outright — verified 2026-07-27 that the container is stopped, `forgejo_data` is 4.0 K with no repositories, and no config anywhere uses `git.cyphy.kz` as a remote.

```bash
cd /home/me/my/vps
git rm -r homeserver/forgejo
```

Also drop the `git.cyphy.kz` row from the service tables in `README.md` and `CLAUDE.md:90`. The Caddyfile deletions are Task 9 Step 5; the DNS record cleanup is Task 9 Step 6.

If you later change your mind, the compose file is one `git revert` away — but the data is gone either way, because there never was any.

- [ ] **Step 1: Fix the mount layout now, in one place**

| Old (Windows) | New (Linux) | Backing |
|---|---|---|
| `D:\ImmichMedia\library` | `/srv/immich/ImmichMedia/library` | Kingston NVMe (enclosure), NTFS |
| `D:\ImmichMedia\postgres` | *(not reused — see below)* | **latitude internal NVMe, ext4** |
| `D:\ImmichMedia\library\backups` | `/srv/immich/ImmichMedia/library/backups` | Kingston NVMe, NTFS |
| *(new)* | `/var/lib/immich/postgres` | **latitude internal NVMe, ext4** |
| `E:\admin\<year>` | `/srv/immich-years/admin/<year>` | WD10 dock bay, NTFS |
| `G:\backup-homeserver\...` | `/srv/backup-1/backup-homeserver/...` | ST1000LM024 dock bay, NTFS |
| `F:\...` (`qb`, `restic-repos`, `secrets`) | `/srv/public/...` | ST320LT020 dock bay, NTFS |
| `H:\backup-homeserver\...` | *(off-site, not mounted)* | HGST, set aside in Task 2 |

**Every mount point is a volume root, and the volume's own top-level directory is preserved.** The Kingston mounts at `/srv/immich`, so `D:\ImmichMedia\library` becomes `/srv/immich/**ImmichMedia**/library` — the `ImmichMedia` level does not disappear. Same rule for the others: `E:\admin\2019` → `/srv/immich-years/admin/2019`, `G:\backup-homeserver\…` → `/srv/backup-1/backup-homeserver/…`, `F:\qb` → `/srv/public/qb`. Getting this wrong is silent: Docker creates a missing bind-mount source as an empty directory, Immich comes up with zero assets, and it looks like a database problem.

Postgres on the internal ext4 NVMe is not optional — a database on an NTFS-over-USB HDD would make Immich miserable, and it is the one dataset small enough (tens of GB) to fit latitude's 329 G free.

- [ ] **Step 2: Rewrite `homeserver/immich/.env.dist`**

```ini
UPLOAD_LOCATION=/srv/immich/ImmichMedia/library
DB_BACKUPS_LOCATION=/srv/immich/ImmichMedia/library/backups
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

`navidrome/compose.yml:12-13` uses `NAVIDROME_DATA_ABS_PATH` and `NAVIDROME_LIBRARY_ABS_PATH`; `restic-server/compose.yml:8` uses `RESTIC_DATA_PATH`. Point them at `/srv/...` paths consistent with Step 1. `tugtainer`, `telegrind`, `embedthat` use named Docker volumes only (`tugtainer_data`, `pgdata`, `redis_data`) — those live under `/var/lib/docker` and need no path change, but see Task 13 for migrating their contents. (`forgejo_data` is not in that list — Forgejo is retired in Step 0.)

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
- Modify: `vps/caddy/Caddyfile` — deletions only (Forgejo l4 + site blocks)

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

- [ ] **Step 5: Delete the two Forgejo blocks from the Caddyfile**

These are the *only* Caddyfile edits in this plan. Every surviving `reverse_proxy` line stays byte-identical, because latitude keeps `10.0.0.2`.

Delete the entire global l4 block at the top (`vps/caddy/Caddyfile:1-11`):

```
{
    layer4 {
        :2222 {
            route {
                proxy {
                    upstream 10.0.0.2:2222
                }
            }
        }
    }
}
```

And delete the `git.cyphy.kz` site block (line 13 onward):

```
git.cyphy.kz {
    reverse_proxy 10.0.0.2:3000
}
```

**Do not** repurpose the `:2222` listener for host SSH. It was Forgejo's git-over-SSH (`homeserver/forgejo/compose.yml:8` published `0.0.0.0:2222:22`); pointing it at port 22 would publish latitude's host sshd to the open internet, which `modules/system/ssh-server.nix:34` deliberately prevents by binding to `tailscale0` + LAN only. With Forgejo gone, nothing should listen on 2222 at all.

- [ ] **Step 6: Verify what remains, then deploy**

```bash
grep -n "10.0.0.2\|layer4\|:2222" vps/caddy/Caddyfile
```

Expected: five `reverse_proxy` lines — 2283 (Immich), 2282 (LibreSpeed), 8084 (qBittorrent), 4533 (Navidrome), 9412 (Tugtainer) — and **no** `layer4` block, **no** `:2222`, **no** `git.cyphy.kz`.

```bash
ssh hub 'cd /path/to/vps/vps && sudo caddy validate --config caddy/Caddyfile && sudo bash deploy-caddy.sh'
```

`setup-caddy.sh` installs Caddy with the `caddy-l4` plugin. With the l4 block gone the plugin is unused, but leave it installed — it costs nothing and re-adding it later is a rebuild.

- [ ] **Step 7: Remove the `git.cyphy.kz` DNS record**

At your DNS provider. Do this *after* the Caddy deploy succeeds, so a stale record never points at a listener that no longer answers.

- [ ] **Step 8: Commit**

```bash
git add backup/ vps/caddy/Caddyfile
git commit -m "feat(backup): port homeserver profiles to Linux; drop Forgejo routes"
```

*(Renumbered: this task previously had two steps labelled "Step 6" — the Caddy verify/deploy and the commit. The deploy is Step 6, the DNS cleanup Step 7, this is Step 8.)*

---

## Phase D — G15 → latitude (the physical move)

### Task 10: Quiesce the G15 and take the final backup `[remote-box]`

- [ ] **Step 1: Record the Immich asset count — while the database is still up**

Task 12 Step 5 and the sale gate in Task 16 both compare against this number. There is no way to recover it after shutdown.

```powershell
docker exec -t immich_postgres psql -U postgres -d immich -c "select count(*) from assets;"
```

Write the number in the migration log.

- [ ] **Step 2: Export the Docker named volumes — while Docker is still running**

`tugtainer_data`, `pgdata` (telegrind), and `redis_data` (embedthat) live inside Docker's storage on `C:`. They do **not** travel on any of the drives you are moving. Export them now; the import happens in Task 13 Step 4. `forgejo_data` is deliberately absent — Forgejo is retired (Task 8 Step 0) and the volume is empty anyway.

```powershell
foreach ($v in @("tugtainer_data","pgdata","redis_data")) {
  docker run --rm -v "${v}:/from" -v "F:\volume-export:/to" alpine tar cf "/to/$v.tar" -C /from .
}
dir F:\volume-export
```

Expected: three non-empty `.tar` files. `F:` travels to latitude, so they come with it.

- [ ] **Step 3: Stop every service cleanly**

```powershell
docker compose -f homeserver\immich\compose.yml down
# repeat for navidrome, restic-server, tugtainer, speedtest, beat, telegrind, embedthat
# (forgejo is already stopped and is being retired — leave it down)
docker ps
```

Expected: no running containers.

- [ ] **Step 4: Dump the Immich database**

Do **not** copy the PostgreSQL data directory across operating systems. Dump it — this is also what the existing `immich-postgres` restic profile does.

```powershell
docker compose -f homeserver\immich\compose.yml up -d database
docker exec -t immich_postgres pg_dumpall -U postgres > D:\immich-final-dump.sql
docker compose -f homeserver\immich\compose.yml down
```

Verify the dump is non-trivial in size and ends with `-- PostgreSQL database cluster dump complete`.

- [ ] **Step 5: Run a final backup of everything**

```powershell
resticprofile --name immich-media backup
resticprofile --name immich-postgres backup
```

Expected: `snapshot <id> saved` for each. Record the snapshot IDs in the migration log.

- [ ] **Step 6: Disable Windows fast startup and shut down fully**

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

- [ ] **Step 7: Order Docker after the mounts**

`nofail` is right for boot, but it means a slow dock enumeration can let `docker.service` start first. `virtualisation.docker` auto-starts, Immich bind-mounts directories that do not exist yet, Docker creates them empty, and Immich comes up with zero assets — and new uploads land on the root filesystem instead of the Kingston. Add:

```nix
  # Never let Docker start before the media volumes are mounted — an early
  # start silently bind-mounts empty directories and writes uploads to /.
  systemd.services.docker.unitConfig.RequiresMountsFor = [
    "/srv/immich"
    "/srv/immich-years"
    "/srv/backup-1"
    "/srv/public"
  ];
```

- [ ] **Step 8: Apply and verify**

```bash
sudo nixos-rebuild switch --flake .#latitude
findmnt /srv/immich /srv/immich-years /srv/backup-1 /srv/public
ls /srv/immich/ImmichMedia/library | head
ls /srv/immich-years/admin | head -25
```

Expected: four mounts present; the library directory and 19 year directories visible. If `ls /srv/immich/ImmichMedia/library` is empty or missing, stop — the mount-point arithmetic is wrong, and nothing downstream will work. If a mount fails with "volume is dirty", go back to Task 10 Step 6 — the G15 did not shut down fully. Recover with `sudo ntfsfix /dev/sdX` (and re-do the clean shutdown if the G15 is still available).

- [ ] **Step 9: Reboot and confirm the mounts survive re-enumeration**

```bash
sudo reboot
# then, after it comes back:
findmnt /srv/immich /srv/immich-years /srv/backup-1 /srv/public
ls /srv/immich/ImmichMedia/library | head
systemctl show docker -p After | tr ' ' '\n' | grep srv
```

Expected: all four mounted from the same UUIDs regardless of `/dev/sdX` assignment, the library still visible, and Docker ordered after the four `.mount` units. Once Task 13 has run, repeat this reboot and assert **Immich still reports its full asset count** — that, not `findmnt`, is the real proof the ordering guard works.

- [ ] **Step 10: Commit**

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

- [ ] **Step 4: Import the named volumes exported in Task 10 Step 2**

The three tarballs are at `/srv/public/volume-export/` (they rode over on `F:`). Import each:

```bash
for v in tugtainer_data pgdata redis_data; do
  docker volume create "$v"
  docker run --rm -v "$v:/to" -v /srv/public/volume-export:/from alpine \
    tar xf "/from/$v.tar" -C /to
done
docker volume ls
```

Expected: three volumes present and non-empty (`docker run --rm -v tugtainer_data:/d alpine ls /d`). If the tarballs are missing, the G15 must still be intact to re-export — another reason Task 16 is gated.

- [ ] **Step 5: Start the rest**

```bash
for s in navidrome restic-server tugtainer speedtest beat telegrind embedthat; do
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

- [ ] **Step 4: Confirm the Caddy deploy from Task 9 Step 6 is live**

The surviving routes still target `10.0.0.2` — only the machine answering at that address changed, so no further Caddy edit is needed here. Just confirm the Forgejo-removal deploy landed:

```bash
ssh hub 'sudo caddy validate --config /etc/caddy/Caddyfile && systemctl is-active caddy'
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
| `https://git.cyphy.kz` | **fails to resolve / no route** — Forgejo is retired |
| `nc -vz cyphy.kz 2222` | **connection refused** — the l4 listener is gone |

The last two are negative checks. A shell prompt on port 2222 would mean the l4 block was repointed at host SSH instead of deleted — stop and fix that before going further.

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
for t in provision/tests/*.test.sh agents/plugin/skills/lib/tests/*.test.sh; do
  printf '%-52s ' "$t"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL
done
nix build --dry-run '.#nixosConfigurations.latitude.config.system.build.toplevel'
```

`tiers.test.sh` is the one that catches a half-done host removal: it asserts a committed `agents/hosts/<hostname>.md` per `fleet.json` entry, so dropping `server` without deleting `agents/hosts/g513ie.md` (and its `methe-server.md` symlink) leaves an orphan the suite will not flag — grep for those two by name.

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

Then confirm no Forgejo remnants survived Task 8 Step 0 and Task 9 Step 5:

```bash
grep -rn "forgejo\|git.cyphy.kz\|2222" --include='*.md' --include='*.yml' --include='Caddyfile' . | grep -v '\.git/'
```

Expected: no hits. Any that remain are docs — `README.md`'s service table and `CLAUDE.md:90` are the likely stragglers.

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
- ~~The exact per-host memory path `agents/bootstrap.sh` reads is flagged for confirmation in Task 6 Step 2.~~ **Resolved 2026-07-27:** `agents/hosts/<detect.hostname>.md`, asserted by `provision/tests/tiers.test.sh:75-79`. Stub committed in `62babbd`.
- ~~Whether a `services` role has an implementation in `provision/roles/`.~~ **Resolved 2026-07-27:** it does not; only `agents`/`dotfiles`/`repos` exist, and `provision.sh:72-78` degrades gracefully on an unimplemented role. Declaring `services` is safe. See Task 7 Step 6.
- Navidrome's music library location was never inventoried on the G15 — Task 8 Step 4 assigns it a `/srv` path, but which physical drive holds the music today must be checked before that mount is declared.
- The `qb` (qBittorrent) download path and the `telegrind`/`embedthat`/`beat` env requirements are covered generically in Tasks 8 and 13; each needs its `.env.dist` read before that task runs.
- The macOS account name is unverified — Task 5 Step 3b checks `whoami` against the `me` default that `modules/home/ssh.nix` bakes into the generated `Host air` block.

**Execution log:**

| Date | Commit | What |
|---|---|---|
| 2026-07-27 | `1c29ecb` | Pre-work: fixed the repo's red `tiers.test.sh` baseline (stale expectation since the hermes tiers landed); gitignored `.claude/worktrees/`. |
| 2026-07-27 | `62babbd` | **Task 3** complete — `darwin` platform, `air` member at `100.64.0.7`, role-executor arms, `agents/hosts/air.md`, new `roles.test.sh`, dispatch pinned. All 8 test files green; latitude toplevel dry-builds; `Host air` present in the generated SSH config. |
| 2026-07-27 | `1fc2015` | Plan corrections folded in; Task 1 Steps 2-3 recorded (Kingston pending). |
| 2026-07-27 | `04c0309` | **Task 4** complete — `provision/macos.sh` + the darwin half of `lib/tiers.sh` (brew tiers, launchd branches, per-platform gortex asset, zsh init). Shared library, not a fork. shellcheck clean; plists validated with `plistlib`. |
| 2026-07-27 | *(next)* | `tier_fleet_ssh` — closes a gap that would have broken Task 5 Step 4. See below. |

**Gap found and closed after Task 4 (outbound fleet SSH on a non-Nix, non-WSL box).** `~/.ssh/config` is generated by `modules/home/ssh.nix` on NixOS and by `provision/ssh-wsl.sh` on WSL. macOS has neither, and `tier_ssh_accounts` only writes GitHub-account blocks — so the Mac would have had **no fleet host blocks at all** and `ssh latitude` would have failed, silently invalidating Task 5 Step 4's verification. Rather than write a third renderer that would drift from the other two, `tier_fleet_ssh` sources `ssh-wsl.sh`'s pure helpers through its existing `SSH_WSL_LIB_ONLY=1` hook (the WSL-specific apt/systemd/Windows-key parts all live below that guard) and merges the rendered block under `ssh-wsl.sh`'s own markers. Darwin-only in the tier list, because adding it on Linux would fight `ssh-wsl.sh` over the same marked span. `provision/tests/fleet-ssh-tier.test.sh` runs the real tier against a throwaway `$HOME` and asserts the per-member blocks, the `*.gg.ez` wildcard, `IdentityFile` on every block, 0600 perms, idempotency, and coexistence with a foreign `ssh_accounts` block.

**Decision recorded (Task 4):** `macos.sh` shares `provision/lib/tiers.sh` rather than carrying its own tier bodies. The alternative — a self-contained `macos.sh` — was rejected because it duplicates six portable tiers (`agents_config`, `hermes_config`, `git_base`, `agent_clis`, `ssh_accounts`, `ssh_trust`) that would then need every fix applied twice. `tiers.test.sh` now asserts the two drivers' tier lists are identical once the package tiers are stripped, so the sharing is enforced rather than merely intended.

Work happens on branch `worktree-fleet-migration-mac-primary` (worktree at `.claude/worktrees/fleet-migration-mac-primary`), per the Global Constraint against committing on `main`.
