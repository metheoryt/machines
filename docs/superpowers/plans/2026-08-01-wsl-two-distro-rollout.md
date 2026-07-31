# WSL Two-Distro Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do NOT use subagent-driven-development for this plan.** Every task mutates live machines — a renamed distro, a moved repo, a deleted VHD. A fresh subagent per task cannot see what the previous one actually did to the box, and several tasks are irreversible. Execute inline, with the user at the checkpoints.

**Goal:** Turn the single personal WSL distro into two — `desktop-wsl` (personal) and `desktop-pure` (work) — each running a headless `orca serve` daemon reachable from the Windows Orca UI and from `air`.

**Architecture:** Both distros live in one WSL2 utility VM sharing one network namespace, so they share `tailscaled` and `100.64.0.6` and are separated by port, not by IP. `desktop-wsl` owns the tailnet node and `:22`; `desktop-pure` has neither and is reached through the Windows parent. Windows Orca registers zero local repos — every repo lives in its own distro's Linux `orca serve` registry.

**Tech Stack:** WSL2 (`wsl --import`, `wsl --manage`), systemd user units + `loginctl enable-linger`, Headscale/Tailscale, the dotfiles bare repo, Orca AppImage, `rsync`.

**Spec:** `docs/superpowers/specs/2026-08-01-two-distro-orca-design.md`

**Prerequisite:** every task in `docs/superpowers/plans/2026-08-01-wsl-two-distro-machinery.md` must be merged and green first. This plan calls `provision-wsl.sh --no-tailscale`, `wsl-fixes.sh`, and `fleet-local.sh --dispatch`, none of which exist before that.

## Global Constraints

- **Secrets never reach a repo file, a memory store, or a commit.** That covers pairing URLs, device tokens, runtime `authToken`s, and OAuth credential blobs. Two pairings means two device tokens. `~/.local/state/orca-serve.log` contains a live `deviceToken` in its pairing URL — that path stays untracked in **both** distros.
- **Never weaken the dotfiles `.gitignore` deny block** for key material.
- **Never run `dotfiles checkout main` on either distro.** Host-local paths are tracked on the machine branch and absent from `main`, so the checkout deletes them from `$HOME` — `~/.ssh/config` included.
- **Run `dotfiles status` after any `rm -rf` under `$HOME`.** See Task 9.
- **Port allocation is fixed by the spec.** `desktop-wsl`: `orca serve` 6768, sshd 22. `desktop-pure`: `orca serve` 6769, no sshd. A third daemon extends the spec's table; never pick a port ad hoc.
- **The Windows box has no Nix.** No `nix flake check` / `nix build --dry-run` step belongs in this plan; defer any Nix gate to `latitude5520`.
- **Out-of-band escape hatch.** If WSL interop dies mid-task (`cannot execute binary file: Exec format error` from `wsl.exe` / `cmd.exe` / `powershell.exe`), recover without it:
  ```bash
  ssh desktop "wsl.exe -d <distro> -u root -- systemctl restart systemd-binfmt"
  ```
  Verified 2026-08-01. `ssh desktop` does not depend on local interop.

---

### Task 1: Pre-flight inventory

Two irreversible later tasks depend on lists that only exist on live machines right now. Capture them before anything is renamed.

**Files:**
- Create: `~/wsl-split-inventory/` (scratch, outside any repo — never committed)

- [ ] **Step 1: Record the Windows-runtime Orca repo registry**

This is the list Task 7 must reproduce. Anything missing from it silently disappears from the Orca UI once Windows-local registration goes away.

From the Windows side (Orca's registry is per-runtime; a WSL shell returns empty):

```bash
mkdir -p ~/wsl-split-inventory
ssh desktop "orca repo list" > ~/wsl-split-inventory/orca-repos-windows.txt
cat ~/wsl-split-inventory/orca-repos-windows.txt
```

Expected: the ten personal repos plus the four `pure` ones, all as `\\wsl.localhost\Ubuntu-26.04\home\me\…` paths.

- [ ] **Step 2: Record per-repo worktree setup/teardown config**

Task 7 re-does this in the Linux runtime. If `orca repo list` does not print it, export whatever the Windows Orca settings file holds:

```bash
ssh desktop "type %LOCALAPPDATA%\\orca\\orca-data.json" \
  > ~/wsl-split-inventory/orca-data-windows.json 2>/dev/null || \
  echo "capture orca-data.json by hand from the Windows box"
```

- [ ] **Step 3: Record the current fleet and tailnet state**

```bash
tailscale status > ~/wsl-split-inventory/tailscale-before.txt
cat ~/machines/fleet.local.json > ~/wsl-split-inventory/fleet-local-before.json
git --git-dir=$HOME/.dotfiles --work-tree=$HOME branch --show-current \
  > ~/wsl-split-inventory/dotfiles-branch-before.txt
cat ~/.local/state/dotfiles-sync/branch >> ~/wsl-split-inventory/dotfiles-branch-before.txt
cat ~/wsl-split-inventory/dotfiles-branch-before.txt
```

Expected: `desktop-ubuntu26` twice — the branch and its sync guard must match.

- [ ] **Step 4: Confirm the dotfiles tree is clean before any move**

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --short
```

Expected: empty. If not, stop and resolve — Task 9 depends on being able to spot a lone ` D` against a clean baseline.

- [ ] **Step 5: Checkpoint**

Show the user the repo registry and confirm it looks complete before proceeding. Nothing has changed yet; this is the last free stopping point.

---

### Task 2: Backfill the fixes onto the existing distro

Prove `wsl-fixes.sh` works on a distro that already exists before betting a new distro's provisioning on it.

**Files:**
- Modify: `~/.local/bin/{wslopen,xdg-open,wslview}`, `/etc/systemd/system/wsl-binfmt-watchdog.{service,timer}`, removal of `/usr/lib/binfmt.d/WSLInterop.conf`

- [ ] **Step 1: Pull the merged machinery**

```bash
cd ~/machines && git pull
ls provision/wsl-fixes.sh provision/assets/wslopen
```

Expected: both paths exist. If not, Plan A is not merged — stop.

- [ ] **Step 2: Run the installer**

```bash
bash ~/machines/provision/wsl-fixes.sh
```

Expected: `✓ installed …/wslopen`, two `✓ linked` lines, `✓ wsl-binfmt-watchdog.timer enabled`, and `✓ removed inert /usr/lib/binfmt.d/WSLInterop.conf`.

- [ ] **Step 3: Verify the opener works end to end**

```bash
command -v xdg-open wslview wslopen
xdg-open 'https://example.com/?a=1&b=2'
```

Expected: all three resolve to `~/.local/bin`, and the URL opens in the Windows browser **with both query parameters intact** — that is what the UTF-16LE/base64 encoding is for.

- [ ] **Step 4: Verify the watchdog actually recovers**

Simulate the failure rather than waiting for it:

```bash
sudo sh -c 'echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop'
ls /proc/sys/fs/binfmt_misc/WSLInterop 2>&1   # expect: No such file or directory
sleep 75
cat /proc/sys/fs/binfmt_misc/WSLInterop
```

Expected after the sleep: the entry is back, `interpreter /init`, `flags: P`. If it does not return, check `systemctl status wsl-binfmt-watchdog.timer` and `journalctl -u wsl-binfmt-watchdog.service` before continuing — every later task assumes interop is durable.

- [ ] **Step 5: Checkpoint**

Report both verifications to the user. This is the first task that changed a live box.

---

### Task 3: Rename the distro, the tailnet node, and the dotfiles branch

Done now because its two real consumers — Windows-side `\\wsl.localhost\Ubuntu-26.04\…` repo registrations and Orca's `activeClaudeManagedAccountIdsByRuntime.wsl["Ubuntu-26.04"]` key — are both deleted later in this plan anyway. Renaming after they are rebuilt would mean rebuilding them twice.

WSL has no `--rename`; the name lives in the registry.

**Files:**
- Modify: `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\{guid}\DistributionName`, the Headscale node name, `~/machines/fleet.local.json`, the dotfiles branch and `~/.local/state/dotfiles-sync/branch`

- [ ] **Step 1: Shut the distro down cleanly**

Close Orca and any session with a shell in the distro first. From the Windows box:

```bash
ssh desktop "wsl.exe --shutdown"
```

- [ ] **Step 2: Rename in the registry**

From the Windows box, find the GUID whose `DistributionName` is `Ubuntu-26.04` and set it to `desktop-wsl`:

```powershell
$root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss'
Get-ChildItem $root | Where-Object {
  (Get-ItemProperty $_.PSPath).DistributionName -eq 'Ubuntu-26.04'
} | ForEach-Object {
  Set-ItemProperty $_.PSPath -Name DistributionName -Value 'desktop-wsl'
}
wsl.exe -l -v
```

Expected: `desktop-wsl` appears in the list; `Ubuntu-26.04` is gone.

- [ ] **Step 3: Re-enable Docker Desktop's WSL integration**

Docker Desktop's integration toggle is per distro name, so the rename turns it off. In Docker Desktop → Settings → Resources → WSL Integration, enable `desktop-wsl`. Then, inside the distro:

```bash
docker version
```

Expected: both Client and Server report. The 07-31 spec established the backend-api stack is all-Docker, so this must work before the work distro is built.

- [ ] **Step 4: Rename the tailnet node**

```bash
sudo tailscale set --hostname desktop-wsl
sleep 5
tailscale status | head -3
```

Then confirm MagicDNS has caught up, from another fleet member:

```bash
ssh air "ping -c1 desktop-wsl.gg.ez"
```

Expected: resolves to `100.64.0.6`. Also check the Headscale console that the old `desktop-ubuntu26` node is gone rather than lingering as a duplicate — a stale node keeps answering DNS and sends dispatch to a dead address.

- [ ] **Step 5: Rewrite the self-declaration**

```bash
bash ~/machines/provision/fleet-local.sh --nickname desktop-wsl \
  --dispatch direct --repo ~/machines
jq . ~/machines/fleet.local.json
```

Expected: `nickname: "desktop-wsl"`, `fleet: true`, `platform: "linux"`, `dispatch: "direct"`.

- [ ] **Step 6: Rename the dotfiles branch, locally and on the remote**

The branch has a remote; renaming only the local branch leaves this box pushing to a name nobody else expects.

```bash
D="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
$D branch -m desktop-ubuntu26 desktop-wsl
$D push origin desktop-wsl
$D push origin --delete desktop-ubuntu26
$D branch --set-upstream-to=origin/desktop-wsl desktop-wsl
echo desktop-wsl > ~/.local/state/dotfiles-sync/branch
$D status --short && $D branch -vv
```

Expected: clean tree, `desktop-wsl` tracking `origin/desktop-wsl`. The sync timer refuses to run when HEAD is not the branch recorded in that guard file, so the two must agree.

- [ ] **Step 7: Verify the sync timer still runs**

```bash
systemctl --user status dotfiles-sync.timer 2>/dev/null || \
  systemctl status dotfiles-sync.timer
```

Expected: active. If it reports a branch mismatch, re-check Step 6.

- [ ] **Step 8: Checkpoint**

Report the rename to the user. `fd_wsl_hosts` will now report `desktop-wsl` — confirm `/ship` still reaches this box from another member before moving on:

```bash
ssh air "cd ~/machines && bash agents/plugin/skills/ship/fleet-pull.sh \
  git@github.com:metheoryt/machines.git" | grep desktop-wsl
```

---

### Task 4: Create and provision `desktop-pure`

**Files:**
- Create: a new WSL distro `desktop-pure` with its own VHD

- [ ] **Step 1: Fetch a clean Ubuntu 26.04 rootfs**

From the Windows box, pick a download directory with room and fetch the cloud image rootfs:

```powershell
mkdir C:\wsl-images -Force
# Ubuntu 26.04 WSL rootfs, from the Ubuntu cloud-images WSL directory.
# Confirm the current filename at https://cloud-images.ubuntu.com/wsl/ before running.
curl.exe -L -o C:\wsl-images\ubuntu-26.04-wsl-amd64.rootfs.tar.gz `
  https://cloud-images.ubuntu.com/wsl/releases/26.04/current/ubuntu-26.04-wsl-amd64-wsl.rootfs.tar.gz
```

If that URL 404s, use `wsl.exe --install Ubuntu-26.04 --name desktop-pure` if the installed WSL supports `--name`, and skip to Step 3.

- [ ] **Step 2: Import as a new distro**

```powershell
mkdir C:\wsl\desktop-pure -Force
wsl.exe --import desktop-pure C:\wsl\desktop-pure `
  C:\wsl-images\ubuntu-26.04-wsl-amd64.rootfs.tar.gz --version 2
wsl.exe -l -v
```

Expected: `desktop-pure` listed, Version 2. It gets its own sparse VHD sized by `.wslconfig`'s `defaultVhdSize=52428800000`.

- [ ] **Step 3: Create the user and set `wsl.conf`**

An imported distro starts as root with no default user.

```bash
ssh desktop "wsl.exe -d desktop-pure -u root -- bash -lc \"
  adduser --disabled-password --gecos '' me &&
  usermod -aG sudo me &&
  printf '[boot]\nsystemd=true\n\n[user]\ndefault=me\n' > /etc/wsl.conf
\""
ssh desktop "wsl.exe -t desktop-pure"
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'whoami; ps -p 1 -o comm='"
```

Expected: `me` and `systemd`. Set a password for `me` interactively if sudo will need one — several later steps use `sudo`.

- [ ] **Step 4: Clone `machines` into the new distro**

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc '
  sudo apt-get update && sudo apt-get install -y git jq curl rsync &&
  git clone https://github.com/metheoryt/machines.git ~/machines'"
```

Use the HTTPS URL here — SSH keys do not exist in this distro yet; `ssh-wsl.sh` creates them in the next step.

- [ ] **Step 5: Provision, without tailscale**

WSL2 distros share one network namespace, so a second `tailscaled` cannot create a second `tailscale0`. This is the flag Plan A Task 3 added.

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc \
  'cd ~/machines && bash provision/provision-wsl.sh desktop-pure --no-tailscale'"
```

Expected: four steps run (`ssh-wsl.sh`, `linux.sh`, `fleet-local.sh`, `wsl-fixes.sh`), and the closing line reads `No tailnet node of its own — reached through its Windows parent.`

- [ ] **Step 6: Set the dispatch mode to `parent`**

`provision-wsl.sh` writes `dispatch=direct` by default. This distro has no node:

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc \
  'bash ~/machines/provision/fleet-local.sh --nickname desktop-pure \
     --dispatch parent --repo ~/machines && jq . ~/machines/fleet.local.json'"
```

Expected: `dispatch: "parent"`.

- [ ] **Step 7: Verify no port or node collisions**

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'ss -ltn | head -20'"
tailscale status | grep -c desktop
```

Expected: the listener table is the **same** as `desktop-wsl`'s — that is the shared namespace working as designed, not a bug. Exactly one `desktop-*` tailnet node.

If `sshd` came up in `desktop-pure` it will have failed to bind `:22`, which `desktop-wsl` holds. Disable it — the work distro is reached through the parent:

```bash
ssh desktop "wsl.exe -d desktop-pure -u root -- bash -lc \
  'systemctl disable --now ssh 2>/dev/null; true'"
```

- [ ] **Step 8: Checkpoint**

Report to the user before wiring dotfiles.

---

### Task 5: Dotfiles branch for `desktop-pure`

**Files:**
- Create: dotfiles branch `desktop-pure`, `~/.claude/host-memory.md` in the new distro

- [ ] **Step 1: Clone the bare repo and check out a new branch off `main`**

Inside `desktop-pure`:

```bash
git clone --bare git@github.com:metheoryt/dotfiles.git ~/.dotfiles
D="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
$D config status.showUntrackedFiles no
$D checkout -b desktop-pure origin/main
$D push -u origin desktop-pure
```

`checkout -b … origin/main` is safe here in a way `dotfiles checkout main` never is: this `$HOME` has no host-local tracked paths yet, so nothing can be deleted.

- [ ] **Step 2: Verify the shared memory stores arrived**

```bash
ls -l ~/.claude/memory/global.md ~/.claude/memory/personality/ ~/CLAUDE.md
```

Expected: all present — they are real files on `main`, not symlinks.

- [ ] **Step 3: Create this distro's host-local memory**

```bash
cat > ~/.claude/host-memory.md <<'EOF'
# Host memory: desktop-pure

Work WSL distro on `desktop` (g614jv). Pure account
(maxim.romanyuk@pure.app). Holds `~/pure/*`.

## Topology

- Shares one network namespace with `desktop-wsl`. No tailnet node and no
  sshd of its own — reached as `wsl.exe -d desktop-pure` through the Windows
  parent. `fleet.local.json` records `dispatch: parent`.
- `orca serve` listens on **6769**; `desktop-wsl` holds 6768.
- Never run `dotfiles checkout main` here.
EOF
```

- [ ] **Step 4: Track it**

`~/.gitignore` is allow-only, so a new file needs an allow-line before it can be added. `host-memory.md` is host-local, so anchor the pattern with a leading slash — an unanchored pattern would also un-ignore a stray copy inside any project checkout under `$HOME`.

```bash
D="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
grep -q '^!/.claude/host-memory.md$' ~/.gitignore || \
  echo '!/.claude/host-memory.md' >> ~/.gitignore
$D add ~/.gitignore ~/.claude/host-memory.md
$D commit -m "desktop-pure: host memory"
$D push
```

- [ ] **Step 5: Verify the deny block is intact**

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME check-ignore -v ~/.ssh/id_ed25519
```

Expected: a match against the deny block. If it reports nothing, **stop** — the key material guard is broken.

- [ ] **Step 6: Checkpoint**

---

### Task 6: Orca Linux runtime and `orca serve` on both distros

The `orca-ide` shim must move first. The serve log from 2026-07-17 records exactly what happens otherwise:

```
[serve] orca CLI install skipped: Refusing to replace non-Orca command at /home/me/.local/bin/orca-ide.
```

**Files:**
- Modify: `~/.local/bin/orca-ide` (moved aside), `~/.config/orca/` (cleared), `~/.local/opt/orca/` (installed), `~/.config/systemd/user/orca-serve.service` (created), in **both** distros

- [ ] **Step 1: Move the shim aside and clear stale config, on `desktop-wsl`**

```bash
mv ~/.local/bin/orca-ide ~/.local/bin/orca-ide.windows-bridge.bak
rm -rf ~/.config/orca
ls ~/.local/opt/ ~/.local/bin/orca* 2>&1
```

Expected: `~/.local/opt` empty, no `orca` or `orca-ide` on `PATH`.

- [ ] **Step 2: Install the Linux Orca runtime on `desktop-wsl`**

```bash
mkdir -p ~/.local/opt/orca && cd ~/.local/opt/orca
# Download the Linux AppImage for the version matching the Windows client (1.4.162).
curl -fL -o orca.AppImage "<orca-linux-appimage-url>"
chmod +x orca.AppImage
./orca.AppImage --appimage-extract >/dev/null
ln -sfn ~/.local/opt/orca/squashfs-root/resources/bin/orca ~/.local/bin/orca
orca --version
```

Expected: `1.4.162` or the version the user chose. Get the URL from Orca's own download page; do not guess it.

- [ ] **Step 3: Start `orca serve` by hand once, on `desktop-wsl`**

Confirm it binds before wrapping it in a unit.

```bash
orca serve --port 6768 2>&1 | tee -a ~/.local/state/orca-serve.log
```

Expected: `Orca server ready: ws://0.0.0.0:6768` and a pairing URL. **Do not copy the pairing URL anywhere** — it embeds a live `deviceToken`. Leave it in the terminal for Task 8, then Ctrl-C.

- [ ] **Step 4: Wrap it in a systemd user unit, on `desktop-wsl`**

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/orca-serve.service <<'EOF'
[Unit]
Description=Orca headless server
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/orca serve --port 6768
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now orca-serve
loginctl enable-linger me
systemctl --user status orca-serve --no-pager | head -5
ss -ltn | grep 6768
```

Expected: active, listening on `0.0.0.0:6768`.

- [ ] **Step 5: Repeat Steps 1–4 on `desktop-pure`, with port 6769**

Same sequence inside `desktop-pure`. `desktop-pure` has no `orca-ide` shim to move, so Step 1 reduces to `rm -rf ~/.config/orca`. In the unit, use `--port 6769`.

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'ss -ltn | grep 6769'"
```

Expected: listening on `0.0.0.0:6769`.

- [ ] **Step 6: Prove linger actually holds for `desktop-pure`**

This is the spec's one untested assumption. `desktop-wsl` is opened interactively all the time; the work distro's whole premise is that it runs untouched. WSL's boot path is not a normal one, and a distro nobody `wsl -d`s may never start its user manager.

```bash
ssh desktop "wsl.exe -t desktop-pure"
sleep 5
ssh desktop "wsl.exe -d desktop-pure -u root -- systemctl is-active user@1000.service"
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'ss -ltn | grep 6769'"
```

Expected: `active`, and 6769 listening — **without** anyone having opened an interactive shell.

If it fails, switch to a system unit with `User=me`. Rejecting per-distro network namespaces freed that option, since `NetworkNamespacePath=` is no longer needed:

```bash
ssh desktop "wsl.exe -d desktop-pure -u root -- bash -lc \"cat > /etc/systemd/system/orca-serve.service <<'EOF'
[Unit]
Description=Orca headless server
After=network-online.target

[Service]
Type=simple
User=me
ExecStart=/home/me/.local/bin/orca serve --port 6769
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now orca-serve\""
```

Then re-run the terminate-and-check above.

- [ ] **Step 7: Checkpoint**

Report which mechanism held — user unit with linger, or the system-unit fallback. Record the answer; it belongs in the spec's §6.

---

### Task 7: Register every repo in the Linux runtimes

Windows-local registration goes away entirely, so anything not registered here vanishes from the UI. Task 1 Step 1 captured the list this must reproduce.

**Files:**
- Modify: each distro's Linux Orca repo registry

- [ ] **Step 1: Register the ten personal repos in `desktop-wsl`**

For each path in `~/wsl-split-inventory/orca-repos-windows.txt` that is not under `pure/`, register its Linux path:

```bash
orca repo add /home/me/machines
orca repo add /home/me/my/buton
# … one per repo from the inventory
orca repo list
```

Expected: `orca repo list` from inside the distro now returns the full set — it returned empty before, because the registry is per-runtime.

- [ ] **Step 2: Re-apply per-repo worktree setup/teardown**

Using `~/wsl-split-inventory/orca-data-windows.json` as the reference, re-configure the setup and teardown scripts for each repo that had them. For repos carrying a committed `.orca/worktree-setup.sh`, the `/orca-setup` skill prints the one-liner to paste.

- [ ] **Step 3: Do NOT register the pure repos yet**

They are still on `desktop-wsl` and have not moved. Registering them here would create exactly the Windows-local-equivalent duplication this task is removing. They get registered in `desktop-pure` in Task 8, after the move.

- [ ] **Step 4: Remove the Windows-local registrations**

Only after Step 1 verifies. From the Windows box, remove each `\\wsl.localhost\…` repo from Orca's registry so the UI is not double-listing.

- [ ] **Step 5: Checkpoint**

Diff the registered set against the inventory and show the user. A missed repo is silent.

---

### Task 8: Accounts and pairing

**Files:**
- Modify: `~/.claude/.credentials.json` in each distro (written by `claude auth login`), Orca's Windows settings (managed account deleted)

- [ ] **Step 1: Log in to the personal account on `desktop-wsl`**

```bash
claude auth login --claudeai
```

Expected: `wslopen` hands the URL to the Windows browser and the flow completes on its own via `redirect_uri=http://localhost:<port>/callback`. Without an opener it would fall back to a URL nobody sees and hang for the full 180 s.

Verify the profile is the real one, not an auth-only slot:

```bash
echo "${CLAUDE_CONFIG_DIR:-<unset>}"
ls ~/.claude/settings.json ~/.claude/memory/global.md
```

Expected: `CLAUDE_CONFIG_DIR` unset, and both files present. If `CLAUDE_CONFIG_DIR` points into `claude-accounts/<id>/auth`, a managed account is still active — go to Step 3 first.

- [ ] **Step 2: Log in to the work account on `desktop-pure`**

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'claude auth login --claudeai'"
```

Use maxim.romanyuk@pure.app. Verify the same two things inside that distro.

- [ ] **Step 3: Delete the redundant WSL managed account**

`4e09ba8b-…` exists only to switch accounts within one distro, which this design no longer does. In the Windows Orca settings, remove it from `claudeManagedAccounts` and clear its entry from `activeClaudeManagedAccountIdsByRuntime.wsl`. Leave `settings.localAccountWslDistro` unset.

This is safe because `orca serve` runs inside each distro, so `process.platform === "linux"`, `getDefaultAccountSelectionTarget()` returns `{runtime: "host"}`, and the launch resolves to that distro's own `~/.claude`. The WSL managed-account path is never consulted.

- [ ] **Step 4: Pair the Windows Orca UI to both daemons**

Add `100.64.0.6:6768` and `100.64.0.6:6769` as remote servers, using each daemon's pairing URL from its own terminal. Two daemons means two device tokens. Do not paste either into a file, a commit, or a memory store.

- [ ] **Step 5: Pair `air` to both daemons**

Same two endpoints from `air`. Verify from `air` first that both are reachable:

```bash
ssh air "nc -z 100.64.0.6 6768 && echo 6768 ok; nc -z 100.64.0.6 6769 && echo 6769 ok"
```

- [ ] **Step 6: Verify both accounts run at once**

Open a Claude session in each distro simultaneously and confirm each reports its own account. This is the whole point of the project — do not accept "it works one at a time".

- [ ] **Step 7: Checkpoint**

---

### Task 9: Move the work repos

**Files:**
- Create: `/home/me/pure/*` and `/home/me/orca/workspaces/{backend-api,claude-plugins}` in `desktop-pure`
- Create: `~/.claude/projects/-home-me-pure-*` in `desktop-pure`
- Delete (last, and only after confirmation): the same paths on `desktop-wsl`

Paths stay identical, so every Claude session slug is byte-identical and no `cwd` rewrite is needed — unlike the 2026-07-31 air→desktop move, where `/Users/me` → `/home/me` forced a per-transcript rewrite.

- [ ] **Step 1: Stop work sessions**

Close every Orca pane and Claude session touching `~/pure` on `desktop-wsl`. This plan is executed from a worktree inside that distro; moving repos out from under a live session corrupts nothing but confuses everything.

- [ ] **Step 2: Copy the working trees verbatim**

Copying rather than re-cloning preserves local branches, stashes, and untracked files. `desktop-pure` has no sshd, so push from `desktop-wsl` through the parent is not available — use a tar stream through the Windows parent instead:

```bash
tar -C /home/me -cf - pure orca/workspaces/backend-api orca/workspaces/claude-plugins \
  | ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'tar -C /home/me -xf -'"
```

Verify on the far side:

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc '
  ls ~/pure && du -sh ~/pure &&
  git -C ~/pure/backend-api worktree list'"
```

Expected: four repos, ~100 MB, and the `test-worktree-setup` worktree listed.

- [ ] **Step 3: Copy the session history**

```bash
tar -C /home/me/.claude/projects -cf - \
  -home-me-pure-backend-api -home-me-pure-claude-plugins \
  | ssh desktop "wsl.exe -d desktop-pure -- bash -lc \
      'mkdir -p ~/.claude/projects && tar -C /home/me/.claude/projects -xf -'"
```

Verify the transcripts are readable and the slugs resolve:

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc '
  du -sh ~/.claude/projects/-home-me-pure-*;
  for f in ~/.claude/projects/-home-me-pure-backend-api/*.jsonl; do
    head -1 \"\$f\" | jq -e .cwd >/dev/null || echo \"BAD: \$f\";
  done; echo transcript-check-done'"
```

Expected: `3.2M` and `8.3M`, no `BAD:` lines.

- [ ] **Step 4: Register the work repos in `desktop-pure`'s runtime**

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc '
  orca repo add /home/me/pure/backend-api &&
  orca repo add /home/me/pure/backend-core &&
  orca repo add /home/me/pure/backend-schema-registry &&
  orca repo add /home/me/pure/claude-plugins &&
  orca repo list'"
```

- [ ] **Step 5: Set up the work gortex daemon**

Own daemon, own index, `~/pure/*` only — so the work index never sees personal repos. It shares the network namespace, so it needs a port distinct from `desktop-wsl`'s daemon.

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc '
  gortex track ~/pure/backend-api &&
  gortex track ~/pure/backend-core &&
  gortex track ~/pure/backend-schema-registry &&
  gortex track ~/pure/claude-plugins &&
  gortex daemon start --detach && gortex daemon status'"
```

If the daemon reports a port conflict, set a distinct port in that distro's `~/.gortex/config.yaml` and record it in the spec's port table.

- [ ] **Step 6: Prove the stack runs before deleting anything**

```bash
ssh desktop "wsl.exe -d desktop-pure -- bash -lc \
  'cd ~/pure/backend-api && docker compose -f compose.shared.yml up -d && docker compose ps'"
```

Expected: the shared infra services come up. Also open an Orca pane against a work repo through the `6769` daemon and run a Claude session in it.

- [ ] **Step 7: CHECKPOINT — explicit confirmation required before any deletion**

Ask the user directly whether the work distro is proven. The earlier approval of this plan is **not** standing authorization for `rm -rf`. Stop here until they say so.

- [ ] **Step 8: Delete from `desktop-wsl`**

```bash
git -C ~/pure/backend-api worktree remove ~/orca/workspaces/backend-api/test-worktree-setup
rm -rf ~/pure ~/orca/workspaces/backend-api ~/orca/workspaces/claude-plugins
rm -rf ~/.claude/projects/-home-me-pure-backend-api \
       ~/.claude/projects/-home-me-pure-claude-plugins
```

- [ ] **Step 9: Check `dotfiles status` immediately**

`rm -rf ~/pure` **will** delete a dotfiles-tracked file: `pure/backend-api/.claude/memory/project.md` is tracked on `main` at its real `$HOME` path, because the bare repo's work-tree *is* `$HOME`. Nothing errors — status just shows a lone ` D`. Left alone, the sync timer's `add -u` stages the deletion, commits it to this machine's branch, and the next `/dotfiles-promote` offers to propagate it fleet-wide. This exact failure already happened on `air` on 2026-07-31.

```bash
D="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
$D status --short
```

If a ` D` appears for that path, restore it — it belongs on `main` and reaches `desktop-pure` via that distro's own branch checkout, never by copying:

```bash
$D checkout -- pure/backend-api/.claude/memory/project.md 2>/dev/null || \
  $D rm --cached pure/backend-api/.claude/memory/project.md
$D status --short
```

Expected: clean.

- [ ] **Step 10: Checkpoint**

---

### Task 10: Verify the fleet end to end

**Files:**
- Modify: none

- [ ] **Step 1: Both distros are discovered with correct routing**

From another fleet member:

```bash
ssh air "cd ~/machines && source agents/plugin/skills/lib/fleet-dispatch.sh && \
  fd_wsl_hosts desktop windows"
```

Expected exactly two rows:

```
desktop-wsl	desktop-wsl.gg.ez	linux
desktop-pure	desktop:desktop-pure	wsl
```

- [ ] **Step 2: Both are reachable via their own routes**

```bash
ssh air "cd ~/machines && source agents/plugin/skills/lib/fleet-dispatch.sh && \
  fd_probe desktop-wsl.gg.ez linux && echo 'direct ok'; \
  fd_probe desktop:desktop-pure wsl && echo 'parent ok'"
```

Expected: both `ok` lines.

- [ ] **Step 3: `/ship` reaches both**

```bash
ssh air "cd ~/machines && bash agents/plugin/skills/ship/fleet-pull.sh \
  git@github.com:metheoryt/machines.git"
```

Expected: both `desktop-wsl` and `desktop-pure` appear with a real result, not a timeout.

- [ ] **Step 4: Both daemons survive a full WSL restart**

The single most likely way this setup silently degrades.

```bash
ssh desktop "wsl.exe --shutdown"
sleep 30
ssh desktop "wsl.exe -d desktop-wsl -- bash -lc 'ss -ltn | grep 6768'"
ssh desktop "wsl.exe -d desktop-pure -- bash -lc 'ss -ltn | grep 6769'"
tailscale status | head -3
```

Expected: both ports listening, tailnet node up. Note the ordering dependency from the spec: `desktop-wsl` owns the only `tailscaled`, so if it is down, `desktop-pure` is unreachable from `air` regardless of its own health.

- [ ] **Step 5: Update the spec's status**

Record in `docs/superpowers/specs/2026-08-01-two-distro-orca-design.md`: mark it implemented, record which supervision mechanism held for `desktop-pure` (Task 6 Step 6), and record the gortex port if a distinct one was needed.

```bash
git add docs/superpowers/specs/2026-08-01-two-distro-orca-design.md
git commit -m "docs(specs): two-distro Orca rollout complete"
```

- [ ] **Step 6: Final checkpoint**

Report to the user: both accounts running simultaneously, both daemons paired from Windows and from `air`, fleet dispatch reaching both.

---

## Self-Review

**Spec coverage.** §1 port allocation → Tasks 4, 6, 9. §2 asymmetric dispatch → Tasks 3, 4, 10. §5 per-distro Claude profile and managed-account deletion → Task 8. §6 Orca Linux runtime, `orca-ide` shim, linger → Task 6. §7 `desktop-pure` creation → Task 4. §8 dotfiles branches → Tasks 3, 5. §9 gortex → Task 9 Step 5. The move → Task 9. Phase 1 rename incl. the branch remote and MagicDNS propagation → Task 3 Steps 4 and 6.

Deliberately **not** here: the `~/exactly` archive and retiring `Ubuntu-24.04`, which the spec records as a separate decision, gated on its own; and `~/.hermes`, which stays.

**Irreversibility.** Three tasks cannot be undone by re-running them: Task 3 (registry rename), Task 9 Step 8 (`rm -rf`), and Task 8 Step 3 (managed-account deletion). Task 9 Step 8 is gated behind an explicit confirmation that the plan's own approval does not grant.

**Assumption flagged rather than assumed.** Task 6 Step 6 tests linger on a never-opened distro instead of trusting it, and carries the system-unit fallback inline.
