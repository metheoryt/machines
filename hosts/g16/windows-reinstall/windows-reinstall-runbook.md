# Windows Clean Reinstall — Runbook

Generated 2026-07-05. Machine: single 2 TB NVMe (disk 0), currently C: (976 GB Windows) + 884 GB Linux dual-boot (to be removed).

**End state:** one Windows 11 install on the full 2 TB disk, Linux dual-boot gone, WSL for Linux work.

**Backup target:** Kingston XS2000 1 TB USB SSD → **`R:` (partition "data", Disk 1)**, ~700 GB free. Backup lives in `R:\backup`; automated by `backup.ps1`. Note: on the freshly reinstalled Windows the SSD may get a **different drive letter** — check Explorer and substitute in the Phase 4 restore paths.

**Where this runbook + script live:** in the **`nix` repo** at `hosts/g16/windows-reinstall/` (this machine is `g16`). They're committed and pushed to `github.com/metheoryt/nix`, so they survive the wipe — after reinstall, `git clone` nix to get them back (no dependency on the broken OneDrive). Each backup run also drops standalone copies on the SSD: `R:\backup\windows-reinstall-runbook.md` and `R:\windows-reinstall\backup.ps1`. Run the script from the repo: `cd C:\Users\methe\GitHub\nix\hosts\g16\windows-reinstall`.

---

## ⛔ THE ONE RULE

**Preserve → VERIFY the backup opens → only THEN wipe.**
Do not delete a single partition until Phase 2 passes. A copy command exiting `0` is not proof; opening the file is.

---

## Phase 0 — Inventory (non-destructive)

Run in **PowerShell**. Write outputs to the SSD.

```powershell
mkdir R:\backup\inventory -Force
winget export -o R:\backup\inventory\winget-packages.json          # winget-sourced apps only (used by `winget import`)
winget list > R:\backup\inventory\winget-list-full.txt              # readable list of EVERYTHING (incl. Steam/ARP/Store apps winget can't reinstall)
code --list-extensions > R:\backup\inventory\vscode-extensions.txt
# WSL apt package list (also captured inside the export, this is a readable copy)
wsl -d Ubuntu-24.04 -- bash -c "dpkg --get-selections" > R:\backup\inventory\wsl-apt-selections.txt
wsl -d Ubuntu-24.04 -- bash -c "pipx list --short 2>/dev/null; uv tool list 2>/dev/null; npm -g ls --depth=0 2>/dev/null" > R:\backup\inventory\wsl-global-tools.txt
```

**⚠️ OneDrive + Google Drive sync is unreliable on this machine — do NOT treat the cloud as a backup.** We copy their local folders to the SSD directly (step 1e). Both are fully present on disk (no online-only stubs), so a copy captures real content.
- [ ] Optional: open the OneDrive and Google Drive **web UIs** and glance for anything that exists only in the cloud (created on another device, never pulled down) — copy those down before wiping, since they're not on this machine to back up.
- [ ] Chrome: `chrome://settings/syncSetup` shows sync ON (restores bookmarks/passwords/extensions after reinstall)
- [ ] JetBrains: Settings Sync enabled (Settings → Settings Sync)

---

## Phase 1 — Preserve

> **All of Phase 1 is automated by `backup.ps1`** (in this folder: `nix/hosts/g16/windows-reinstall/`). Run it from an elevated PowerShell — `cd C:\Users\methe\GitHub\nix\hosts\g16\windows-reinstall`, then `.\backup.ps1 -WhatIf` first, then `.\backup.ps1`. The steps below document what it does and why. Backup target is `R:\backup` (the Kingston USB SSD, Disk 1 — survives the wipe; the script hard-stops if pointed at Disk 0).

### 1a. Git repos — full copy, no push

Windows repos (`C:\Users\methe\GitHub`) are copied **in full including `.git`** — so stashes, uncommitted, and unpushed commits are all preserved — minus `.venv`/`node_modules`/caches. **Nothing is pushed.** Current repos: **airdrome, nix, qaz-law, vasya** (the rest moved to WSL). WSL-side repos are captured wholesale by the WSL export (1b), so they need no separate handling.

### 1b. WSL — full export (no slim)

With ~700 GB free on the SSD there's no need to slim first — export the whole distro as-is (non-destructive, live env untouched):

```powershell
wsl --shutdown
wsl --export Ubuntu-24.04 R:\backup\wsl\ubuntu-2404.tar
```

One archive = all projects, `~/.ssh`, `~/.gnupg` (GPG keys), `.kube`, dotfiles, apt state. Drop the other distros (Debian, 2nd Ubuntu, docker-desktop) — nothing to save there.

### 1c. qaz-law database — NOT backed up (recreatable)

The 100 GB qaz-law Postgres volume is **dropped**: the data can be re-ingested after reinstall, so there's no backup. After the fresh install, bring the stack up (empty DB) and re-run your ingestion. This removes the single largest and slowest backup item.

### 1d. Windows configs & creds → `R:\backup\home`

**Inclusive sweep with a blocklist:** every dotfile/dotdir in the profile is copied (`.ssh` incl. `config`+`known_hosts`, `.claude.json`, `.config`, `.kube`, `.gcm`, `.agents`, `.claude`, `.codex`, shell histories, etc.), so no config is missed — minus `node_modules`/`.venv` inside them. Plus loose `AGENTS.md`. (Repos → 1a; WSL secrets → 1f.)

> **Agent config symlinks:** `.claude`/`.codex` contain symlinks into the **`nix` repo** (`agents/…`: `CLAUDE.md`, `settings.json`, `memory/*`, `hooks/*`, `skills/*`, `cyphy` plugin). Those are the source of truth and are backed up via the nix repo in 1a — the sweep uses `/XJ` so it does **not** duplicate them. The backup keeps only the **machine-local** real files in `.claude`/`.codex` (`.credentials.json`, `settings.local.json`, `projects/` history). See Phase 4.2 for the restore order.

**Excluded** (recreatable caches, dropped apps, or explicitly not wanted): `.cache`, `.lmstudio`, `.vscode`, `.codeium`, `.windsurf`, `.zcode`, `.zed_server`, `.openclaude`(+`.json`), `.marvin`, `.junie`, `.gortex`, `.boto`, `.gsutil`, `.gemini`, `.k8slens`, `.docker` (Docker Desktop rebuilds it; re-`docker login` for registries).

### 1e. User data + cloud folders (sync is unreliable — backed up directly)

Copied to `R:\backup`: **Downloads**; **OneDrive** — ⚠️ **sync is broken on this PC, so the cloud is NOT trusted**; the script copies the local `C:\Users\methe\OneDrive` folder **directly** (incl. your redirected **Documents**, **Pictures**, and **Desktop** = `OneDrive\Рабочий стол`). Currently **all 13,527 files / 3.6 GB are fully on disk, 0 online-only stubs**, so the direct copy is complete. The step re-checks for stubs at backup time and, if any appear (a broken engine may dehydrate files), writes `R:\backup\OneDrive-STUBS-NOT-ON-DISK.csv` and warns — those must be pulled from onedrive.live.com before wiping. Also: **GoogleDrive**; **Obsidian** vault(s) (path read from `%APPDATA%\obsidian\obsidian.json`); and **RustDesk config** (`%APPDATA%\RustDesk\config` → `R:\backup\home\AppData\RustDesk\config` — your RustDesk ID, private key/device identity, saved peers, and relay/ID-server settings; the noisy `log\` folder is skipped). The script also drops a copy of this runbook onto the SSD.
> Keep the runbook readable while the PC is down — it's pushed to `github.com/metheoryt/nix` (`hosts/g16/windows-reinstall/`), so you can open it there from your phone or any device. The SSD also has a copy at `R:\backup\windows-reinstall-runbook.md`. (Do **not** rely on the broken OneDrive to deliver it.)

**App configs** (`AppData`, not caught by the profile-root dotfile sweep) → `R:\backup\home\AppData\…`:
- **Windows Terminal** `settings.json` (profiles, color schemes, keybinds)
- **PowerToys** settings (FancyZones layouts, keyboard remaps, EnvironmentVariables, ColorPicker) — `Updates` payload skipped
- **NCALayer** — the `.der` cert + settings (kept app); bundled `jre`/caches skipped
- **AIMP** — playlists (`PLS`), library, custom genres/moods, skins, `AIMP.ini` (the music *curation*; the files themselves are on methe-server)
- **Telegram Desktop `tdata`** — so **AyuGram** can import your session/drafts on the fresh install

**System settings:** **Wi-Fi profiles** with cleartext passwords → `R:\backup\secrets\wifi\*.xml` (via `netsh wlan export`, so they ride the mandatory off-SSD second copy); **user environment variables** (incl. custom `PATH`) → `R:\backup\inventory\hkcu-environment.reg`.

**Dropped on purpose (no backup):** Music (already on methe-server), torrents, all Docker images + all Docker volumes (incl. qaz-law DB — re-ingest after reinstall), caches, `.venv`/`node_modules` in repos.

### 1f. Second copy of the irreplaceable secrets  ⭐ (do NOT skip — the SSD is a single point of failure)

Your GPG keys live inside the WSL export on one SSD. If that SSD is dead when you plug it back in, GPG keys are **gone forever** (unlike SSH, they can't be regenerated — you'd lose the ability to decrypt anything old). So the script also extracts the tiny secret set as loose files to **`R:\backup\secrets\`** (WSL `.ssh`/`.gnupg`/`.gitconfig` via `\\wsl.localhost`, plus Windows SSH keys) — independently restorable without unpacking the big tar.

**Your manual job (the script won't do this):** copy `R:\backup\secrets\` to a **second location independent of the SSD** — methe-server (`scp`/`rsync`), a password-manager attachment, or an encrypted archive emailed to yourself. Two independent copies of the few MB that can't be re-derived.
- [ ] Second copy of `secrets/` confirmed on methe-server (or other independent location)

---

## Phase 2 — VERIFY  ✅ (gate — do not proceed until every box is checked)

- [ ] `R:\backup\repos\` has all 4 repos (airdrome, nix, qaz-law, vasya), each with a `.git` folder inside (confirms stashes/uncommitted came along)
- [ ] Open 2–3 files **directly from `R:\`** — a repo file, the Obsidian vault, a Download — they actually open
- [ ] `R:\backup\wsl\ubuntu-2404.tar` exists and is ~25–31 GB (full export, not 0)
- [ ] `R:\backup\secrets\` has a **second copy** off the SSD (see 1f) — the one thing whose loss is unrecoverable
- [ ] `R:\backup\inventory\winget-packages.json` is present and non-empty
- [ ] `.ssh` keys (id_ed25519, id_rsa) present under `R:\backup\home\.ssh`
- [ ] `R:\backup\OneDrive` and `R:\backup\GoogleDrive` copied — open a file from each on the SSD to confirm real content (not 0-byte). OneDrive folder includes your Documents + Pictures + **Desktop** (`Рабочий стол`) — confirm the Desktop subfolder is there.
- [ ] **OneDrive sync is broken** → confirm **no** `R:\backup\OneDrive-STUBS-NOT-ON-DISK.csv` was created (its presence means some files were online-only and got missed — recover them from onedrive.live.com first). Ideally also spot-check the SSD's OneDrive file count ≈ 13,527.
- [ ] **This runbook is readable from a device other than this PC** — confirm it's on `github.com/metheoryt/nix` (`hosts/g16/windows-reinstall/`, pushed) AND at `R:\backup\windows-reinstall-runbook.md` on the SSD (don't trust OneDrive to deliver it)

**Belt-and-suspenders:** optionally `rsync`/copy the whole `R:\backup` folder to methe-server too. Costs little, means the network *and* the SSD would both have to fail to lose anything.

---

## Phase 3 — Wipe & install  🔥 (point of no return)

1. Create a Windows 11 install USB (Media Creation Tool) on another machine or before you start.
2. **Unplug the backup SSD** before installing (so it can't be selected by mistake).
3. Boot the USB → Custom install.
4. On the disk screen: **delete ALL partitions on Disk 0** (this removes the Linux dual-boot + its bootloader and reclaims the 884 GB) until it's one block of unallocated space.
5. Select the unallocated space → Next. Installer creates the partitions and uses the full 2 TB.
6. Complete setup (local or MS account per preference).

---

## Phase 4 — Restore

1. **Windows apps:** first delete the dropped IDs from `winget-packages.json` (see Appendix B → *Dropped*), then `winget import R:\backup\inventory\winget-packages.json`. Reinstall the non-winget keepers (JetBrains Toolbox → PyCharm, NCALayer) by hand.
2. **SSH + configs (Windows):** copy `R:\backup\home\.ssh` → `C:\Users\<you>\.ssh`, then fix perms (icacls: remove inherited, grant your user only). Restore the other dotfiles (`.gitconfig`, `.wslconfig`, `.kube`, `.gcm`, `.config`, `.claude.json`, shell histories, etc.).
   - **Agent config (`.claude`/`.codex`) — bootstrap, don't copy verbatim:** clone the `nix` repo, then run `just agent-bootstrap` (and `agent-bootstrap-work` if used) to recreate the symlinks + `cyphy` plugin. **Then** restore only the machine-local bits from `R:\backup\home\.claude`: `.credentials.json`, `settings.local.json`, and `projects/` (session history) if you want it. Do NOT overwrite the freshly-bootstrapped `.claude`/`.codex` wholesale.
3. **WSL:** install WSL + Ubuntu, then either
   - `wsl --import Ubuntu-24.04 C:\WSL\Ubuntu R:\backup\wsl\ubuntu-2404.tar` to restore wholesale, **or**
   - fresh Ubuntu + restore only `~/.ssh`, `~/.gnupg`, dotfiles from the tar and re-clone repos (cleaner). Rebuild venvs (`uv sync` / `pip install`).
4. **Windows repos:** copy `R:\backup\repos\*` back to `C:\Users\<you>\GitHub\` — they weren't pushed, so this backup **is** the source of truth for their stashes/uncommitted work. Recreate `.venv`s (`uv sync`). (WSL repos come back inside the WSL import in step 3.)
5. **Docker + qaz-law DB:** install Docker Desktop, `git clone`/restore qaz-law, bring the stack up (empty DB), then **re-run your ingestion** to repopulate. No restore from backup — the DB was intentionally not backed up.
6. **User data:** copy `Downloads` and the Obsidian vault back. **RustDesk:** install it, close it, then copy `R:\backup\home\AppData\RustDesk\config\*` into `%APPDATA%\RustDesk\config\` (overwrite), and start it — your ID, saved peers, and server settings come back. (If you'd rather keep a fresh ID, restore only `peers.toml` + `peers\` + `RustDesk2.toml` for the peer list and custom server.)
   - **App configs** (install each app first, close it, then drop files back into the matching `%APPDATA%`/`%LOCALAPPDATA%` path):
     - **Windows Terminal:** `…\home\AppData\WindowsTerminal\Microsoft.WindowsTerminal_*\settings.json` → its `…\LocalState\`.
     - **PowerToys:** `…\home\AppData\Local\PowerToys\*` → `%LOCALAPPDATA%\Microsoft\PowerToys\`.
     - **NCALayer / AIMP:** copy back into `%APPDATA%\NCALayer` and `%APPDATA%\AIMP` (reinstall regenerates the `jre`/caches that were skipped).
     - **AyuGram:** point its "import from Telegram Desktop" at `…\home\AppData\Telegram Desktop\tdata` (or drop it where AyuGram expects tdata).
   - **Wi-Fi:** re-add networks by hand from `R:\backup\secrets\wifi\*.xml`, or `netsh wlan add profile filename="…\WiFi-<name>.xml"`.
   - **Env vars:** review `R:\backup\inventory\hkcu-environment.reg` and re-apply the custom entries you still want (don't blindly merge — some paths won't exist yet).
7. **Cloud folders:** **OneDrive was broken — the SSD copy is the source of truth, not the cloud.** After reinstall, set OneDrive up fresh; once it settles, compare its folder against `R:\backup\OneDrive` and copy back anything missing (a broken account may still be missing files in the cloud). If OneDrive stays unreliable, just restore `R:\backup\OneDrive\*` into a plain local folder and stop depending on it. Re-install Google Drive and let it sync, then compare against `R:\backup\GoogleDrive` the same way. In all cases the SSD copy is authoritative.
8. **Sign back in:** Chrome (sync pulls bookmarks/passwords/extensions), JetBrains Settings Sync.
9. Reconnect the SSD only after the fresh OS is trusted; keep the backup until you've confirmed everything restored (including cloud-folder comparison in step 7), then reclaim the space.

---

## Backup manifest (what must exist on E: before wiping)

| Path | What | Recoverable elsewhere if lost? |
|---|---|---|
| `R:\backup\wsl\ubuntu-2404.tar` | Entire WSL: projects, GPG keys, dotfiles | No |
| `R:\backup\secrets\` (+ 2nd copy off-SSD) | GPG + SSH keys — irreplaceable | No |
| `R:\backup\home\.ssh` | Windows SSH keys | No |
| `R:\backup\home\.{kube,gcm,docker,claude,codex,agents}` + gitconfig | Creds/configs | Partly |
| `R:\backup\repos\*` | All Windows repos, full incl `.git` (stashes/uncommitted) | No (local-only state) |
| `R:\backup\Downloads` | Downloads | No |
| `R:\backup\Obsidian\*` | Notes | No |
| `R:\backup\home\AppData\RustDesk\config` | RustDesk ID, key, saved peers, server | No |
| `R:\backup\home\AppData\*` | Terminal, PowerToys, NCALayer, AIMP, Telegram tdata | No |
| `R:\backup\secrets\wifi\*.xml` | Wi-Fi SSIDs + passwords | From router |
| `R:\backup\inventory\hkcu-environment.reg` | User env vars / custom PATH | Convenience |
| `R:\backup\OneDrive` | OneDrive incl. Documents + Pictures (sync unreliable) | **No — don't trust cloud** |
| `R:\backup\GoogleDrive` | Google Drive folder (sync unreliable) | **No — don't trust cloud** |
| `R:\backup\windows-reinstall-runbook.md` | This runbook | Also email/phone |
| `R:\backup\inventory\*` | winget/vscode/apt lists | Convenience |

**Already safe (not on SSD):** git repos pushed to GitHub · Music on methe-server · Chrome/JetBrains via account sync.
**No longer trusted as safe:** OneDrive (Documents/Pictures) and Google Drive — sync is unreliable, so they're backed up to the SSD above.

---

## Appendix B — Software inventory (what to reinstall)

Curated from `winget list` + WSL packages on 2026-07-05. **Excluded as auto/noise** (don't reinstall by hand): NVIDIA/Intel/Realtek/Thunderbolt drivers, VC++ redistributables, .NET runtimes, WindowsAppRuntimes, UI.Xaml, codec/video extensions, and built-in Store apps (Photos, Paint, Calculator, Xbox, etc.).

### Restored automatically
- **`winget import R:\backup\inventory\winget-packages.json`** → everything winget-sourced below.
- **Chrome / JetBrains** → account sync (bookmarks, passwords, IDE settings).

### Dev — IDEs & editors
PyCharm (via **JetBrains Toolbox** — install Toolbox first, then IDEs; not winget) · Zed

### Dev — terminals & CLI
Windows Terminal · PowerShell 7 · PowerToys · Git · GitHub CLI · delta · Just · Docker Desktop · WSL + Ubuntu 24.04 · Python 3.13 + Launcher · Node.js (native) · restic + resticprofile · **NCALayer** (Kazakh PKI signing — manual, from pki.gov.kz)

### AI / LLM
Claude Desktop · Codex · LM Studio · (WSL: `@openai/codex` via npm)

### Browsers
Google Chrome · Edge (built-in)

### Communication
Slack · AyuGram (your Telegram client) · WhatsApp · Discord · Zoom · RustDesk

### VPN / network
AmneziaVPN + AmneziaWG · Cloudflare WARP

### Media / creation
Shutter Encoder · VLC · AIMP · Spotify · MusicBrainz Picard · Elgato Camera Hub

### Utilities
7-Zip · CrystalDiskInfo · WizTree · NetSpot · Logitech G HUB · NVIDIA App · MyASUS · Intel DSA

### ✂️ Dropped — do NOT reinstall
Strip these winget IDs from `winget-packages.json` **before** running `winget import` (or just skip them):
`Warp.Warp` · `SublimeHQ.SublimeText.4` · `Exafunction.Windsurf` · `ZhipuAI.ZCode` · `Google.CloudSDK` · `GitHub.GitHubDesktop` · `Telegram.TelegramDesktop` · `TeamViewer.TeamViewer` · `Proton.ProtonVPN` · `OpenVPNTechnologies.OpenVPNConnect` · `WireGuard.WireGuard` · `OBSProject.OBSStudio` · `CrystalDewWorld.CrystalDiskMark.AoiEdition` · `WinDirStat.WinDirStat` · `Fastfetch-cli.Fastfetch`

Not winget-managed (just don't reinstall): **VS Code** · **Chrome Remote Desktop** · **Supersonic** · **Recuva** · **Tablecruncher**

Notes: Windows `Google.CloudSDK` dropped, but WSL keeps `google-cloud-cli` (gcloud still available in Ubuntu). Terminal = Windows Terminal (Warp gone). Since VS Code is dropped, the `vscode-extensions.txt` export is moot — harmless to leave.

### Cloud storage
OneDrive · Google Drive (re-add accounts; reconcile against SSD copies per Phase 4.6)

### Gaming (re-download, don't back up)
Steam (+ games: Conan Exiles, GTA V, Grounded, Icarus, Metal Hellsinger, NieR Replicant, Portal, Raft, Sons of the Forest, Slay the Princess, Tokyo Xtreme Racer, Wallpaper Engine) · Rockstar Launcher · Xbox
> Save games: mostly Steam Cloud, but check `%USERPROFILE%\Saved Games`, `Documents\My Games`, and `AppData` for any local-only saves you care about before wiping.

### WSL (Ubuntu) — rebuild
Captured wholesale in `ubuntu-2404.tar`; for a clean rebuild use `wsl-apt-selections.txt`. Key apt packages: `clang ffmpeg gdal-bin gh google-cloud-cli jq just keychain ncdu npm restic resticprofile` + build libs (`libavif-dev libcairo2-dev libheif-dev libjpeg-dev pkg-config zlib1g-dev`). Toolchains: Python 3.12, Node 18, gcloud, gh, codex. **Reinstall `uv`** (Astral — used by every project's venv; not an apt package). npm globals: `@openai/codex`, `vot-cli`.
