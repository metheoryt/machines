# Design: reach & update every host's `machines` clone via `/ship` (Windows + WSL)

- **Date:** 2026-07-21
- **Status:** approved (design), pending implementation plan
- **Author:** Maxim + Claude

## Problem

The desktop box (`g614jv`) holds **two** independent `machines` clones:

| clone | filesystem | kept fresh by |
|---|---|---|
| `$HOME/machines` (WSL Ubuntu-26.04, ext4) | WSL | `/ship` fleet-pull (accidentally) |
| `$HOME/machines` (Windows, `C:\Users\methe\machines`) | NTFS | `fleet-selfpull` scheduled task only |

`/ship`'s `fleet-pull.sh` runs `ssh desktop bash -s`. On desktop, `bash` resolves
to `C:\Windows\System32\bash.exe` (the WSL launcher, first on PATH over Git Bash),
so the remote script always lands in WSL and pulls the WSL clone. The
Windows-native clone is never touched by `/ship`. We want **both** reachable and
updated by `/ship` — and, generally, every host (including WSL distros) to be a
first-class fleet host whose clone is its own config dir.

## Key findings (verified live 2026-07-21)

- `desktop` OpenSSH `DefaultShell` is **already** PowerShell; the blocker is `bash`
  resolution, not the default shell.
- Git Bash **is** installed at `C:\Program Files\Git\bin\bash.exe` (`$HOME`
  = `/c/Users/methe`); it just isn't first on PATH.
- WSL Ubuntu-26.04 is **already a tailnet node** at `100.64.0.6`, headscale node
  name `desktop-ubuntu26`; `desktop-ubuntu26.gg.ez` resolves via MagicDNS.
- WSL sshd is **live** on `0.0.0.0:22` but its `authorized_keys` lacks the fleet
  keys → `Permission denied (publickey)`.
- **Usernames differ:** Windows user `methe`, WSL user `me`. Any frozen
  `…/methe/…` or `/home/me/…` path is a latent bug → use `$HOME`-relative paths.
- `provision/linux.sh` already installs a `fleet-selfpull` systemd-user timer
  (~10 min) + a fetch-only `git-autofetch` timer, but does **not** wire ssh-server
  `authorized_keys`.
- Both `fleet-pull.sh` (/ship) and `fleet-gather.sh` (kb-refresh) enumerate
  `fleet.json` members and dispatch `bash -s` → the fix must be shared.

## Decisions

1. **Windows dispatch = Git Bash, platform-driven.** Tools read each member's
   `platform` from `fleet.json`; `platform: windows` → invoke Git Bash so the
   generic remote script runs against the Windows-native clone. (Rejected:
   reusing `fleet-selfpull.ps1`; reordering PATH.)
2. **Shared dispatch helper.** Extract platform-aware remote-bash selection into
   `agents/plugin/skills/lib/fleet-dispatch.sh`, sourced by both tools.
3. **WSL freshness between ships = the selfpull timer already in `linux.sh`** —
   ensure active; no new timer code.
4. **Every host is first-class; WSL hosts self-declare, parent enumerates.**
   Ephemeral WSL distros are NOT committed to `fleet.json`. Each WSL host's own
   clone carries a self-declaration in its gitignored `$HOME/machines/fleet.local.json`;
   the Windows parent discovers them live via `wsl -l -q` + reading each distro's
   marker. (Rejected: committed fleet.json entries; a hand-maintained parent-side
   child list that can drift; flat per-orchestrator registry.)
5. **Canonical path stays `$HOME/machines`.** `~/.machines` rename is a separate
   future project (touches bootstrap.sh, claude.nix, justfile, all docs/clones).
6. **Multi-clone topology.** The Windows clone is the box's driver repo (holds
   nothing special beyond being the declared host you run provision/ship from);
   each fleet WSL distro keeps its own fast ext4 clone at `$HOME/machines`.
7. **`machines` located by canonical path, not scan.** Drop the `/mnt/c/Users/*/`
   cross-filesystem root from fleet-pull's search (it's what let a WSL host reach
   the Windows clone). Other fleet-sync repos keep the existing root search (no
   relocation of `~/my/*` etc.).
8. **No frozen usernames** — `$HOME/machines` everywhere.

## Design

### Membership tiers

- **`fleet.json` (committed):** durable declared hosts only — `latitude`,
  `desktop`, `server`, `hub`. WSL distros never go here.
- **`$HOME/machines/fleet.local.json` (gitignored, per host):** that host's local
  state / config. For a non-committed host (a WSL distro) it carries the
  self-declaration, e.g.:
  ```json
  { "self": { "nickname": "desktop-ubuntu26", "fleet": true, "platform": "linux" } }
  ```
  `nickname` = the host's tailnet node name (so `<nickname>.gg.ez` is reachable).

### Clone topology (per box)

- Windows box: driver clone at `$HOME/machines` (`C:\Users\methe\machines`) — a
  declared host; you run `provision-wsl` / `/ship` from it.
- Each fleet WSL distro: its own ext4 clone at `$HOME/machines`
  (`/home/me/machines`) — first-class host; Orca worktrees branch from it; `/ship`
  keeps it fresh.

### Shared dispatch helper

New `agents/plugin/skills/lib/fleet-dispatch.sh`, sourced by `fleet-pull.sh` and
`fleet-gather.sh`. Given a member alias + `platform`, produce the correct remote
bash:

- `linux` → `ssh <opts> <alias> bash …` (unchanged).
- `windows` → `ssh <opts> <alias> '& "C:\Program Files\Git\bin\bash.exe" …'` —
  PowerShell's call operator launches Git Bash, whose `$HOME=/c/Users/methe`, so
  the existing remote script finds `$HOME/machines` (the Windows clone).

The Git Bash **program** path is user-independent (fine to hardcode; probe both
`Program Files` locations in the plan). *(Verify in implementation: stdin piping
through PowerShell `&` into `bash -s`; fall back to here-string/temp-file if
needed.)*

### Discovery + pull flow

For each **declared** member (in `fleet.json`):

1. Pull its own `$HOME/machines` — Windows → Git Bash dispatch; Linux → normal
   `bash`. (Remote script keys off `$HOME`; `machines` is at `$HOME/machines` — no
   subfolder scan, no `/mnt/c`.)
2. If `platform: windows`: over ssh, `wsl.exe -l -q`; for each distro `D`,
   `wsl -d D -- bash -lc 'cat "$HOME/machines/fleet.local.json" 2>/dev/null'`;
   collect the `nickname` of any distro whose marker has `fleet: true`.
3. For each collected WSL host, the orchestrator opens a **direct** ssh to
   `<nickname>.gg.ez` and pulls `$HOME/machines` (same remote-script contract as
   any member — OK/conv token).

No central child list → no drift. Generalizes to `server` (also Windows) for free.
`fleet-gather.sh` uses the same helper + discovery so kb-refresh harvests WSL
hosts too.

### Half-provision command (new)

`just provision-wsl <nickname>` → `provision/provision-wsl.sh`, run from the driver
clone; for the target distro:

1. enroll on the tailnet (`tailscale-wsl.sh`, node name = `<nickname>`),
2. install the WSL fleet SSH **client** keys (`ssh-wsl.sh`) so the host can ssh
   out to other fleet members,
3. provision software + timers (`linux.sh` — includes the existing selfpull +
   git-autofetch timers),
4. **new ssh-server step in `linux.sh`:** merge `provision/fleet-authorized-keys`
   into `~/.ssh/authorized_keys` (`0700 ~/.ssh`, `0600` file, dedup, idempotent) —
   mirrors `ssh-server.nix` / `windows.ps1` step 7,
5. write the distro's **own** `$HOME/machines/fleet.local.json` self-declaration.

Nothing touches committed files. This is the "connect to tailnet + provision soft +
you pick the nickname + record locally, not a committed member" flow.

**No orca-serve step** — `provision/orca-serve.sh` was removed (commit `f95cb3f`)
now that Orca runs on the Windows host and opens the WSL project directly. The
provision chain is `tailscale-wsl.sh → ssh-wsl.sh → linux.sh`; `provision-wsl` is
the orchestrating wrapper over it plus the self-declaration.

### SSH reachability to WSL hosts

Add a wildcard `Host *.gg.ez` block (User `me`, fleet `IdentityFile`) to generated
ssh config (`ssh.nix` for NixOS; the provision ssh-config writer for others), so
any orchestrator reaches any current/future WSL host by MagicDNS name with no
per-distro regen. Declared members keep their own per-host blocks (e.g. `desktop`
→ User `methe`).

### Docs / memory / tests

- Rewrite the global-memory bullets added 2026-07-21 (the "must be pulled
  manually" / "reached by neither mechanism" claims) to the new model.
- Update the fleet section + two-layer-hostname convention in `AGENTS.md`
  (→`CLAUDE.md`) and `provision/README.md`: WSL hosts are self-declaring
  first-class hosts; document `provision-wsl` and `fleet.local.json`.
- `.gitignore`: add `fleet.local.json`.
- Extend `fleet-pull.test.sh` (+ gather tests): `platform: windows` → Git Bash
  dispatch; WSL enumerate-and-pull discovery (mock `SSH` + `wsl`); `/mnt/c` root
  removed.
- Live verification: `ssh desktop-ubuntu26.gg.ez` works after the keys step; one
  `/ship` from latitude updates the Windows clone AND every self-declared WSL host
  (distinct rows), all advancing to the pushed HEAD.

## Out of scope (YAGNI)

- `docker-desktop` / `Ubuntu-24.04` as fleet hosts (only self-declared distros
  participate).
- No `.wslconfig` / WSL networking changes (inbound works via DERP).
- No PATH reordering on Windows.
- No `~/.machines` rename.
- No `just provision` role executor for WSL — `linux.sh` (wrapped by
  `provision-wsl`) remains its provisioner.

## Risks

- **PowerShell `&` + stdin** into Git Bash `-s` may need a fallback (noted above).
- **`~` expansion under `wsl -d D -- …`** — use `bash -lc "'… \$HOME …'"` so the
  distro's shell expands it, not the calling shell.
- **Host down** → fleet-pull reports `SKIP unreachable` (same as any offline
  member; acceptable).
- **Marker drift within a distro** — if a distro is a fleet host but its marker is
  missing (e.g. clone reset without re-provision), it's silently skipped;
  `provision-wsl` re-writes it. Acceptable for throwaway distros.
