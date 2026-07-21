# Design: split `desktop` into two fleet members (Windows-native + WSL)

- **Date:** 2026-07-21
- **Status:** approved (design), pending implementation plan
- **Author:** Maxim + Claude

## Problem

The desktop box (`g614jv`) holds **two** independent `machines` clones:

| clone | filesystem | kept fresh by |
|---|---|---|
| `/home/me/machines` | WSL Ubuntu-26.04 ext4 | `/ship` fleet-pull (accidentally) |
| `C:\Users\methe\machines` (`/mnt/c/Users/methe/machines`) | Windows NTFS | `fleet-selfpull` scheduled task only |

`/ship`'s `fleet-pull.sh` runs `ssh desktop bash -s`. On desktop, `bash` resolves
to `C:\Windows\System32\bash.exe` (the WSL launcher), which wins on PATH over the
installed Git Bash — so the remote script always lands in WSL and pulls
`/home/me/machines`. The Windows-native clone is never touched by `/ship`; it only
catches up via the separate `fleet-selfpull` Scheduled Task (~10 min).

We want **both** clones reachable and updated by `/ship`.

## Key findings (verified live 2026-07-21)

- `desktop` OpenSSH `DefaultShell` is **already** PowerShell. The blocker is `bash`
  resolution, not the default shell.
- Git Bash **is** installed at `C:\Program Files\Git\bin\bash.exe` (just not first
  on PATH). Its `$HOME` is `/c/Users/methe`.
- WSL Ubuntu-26.04 is **already a tailnet node** at `100.64.0.6`, headscale node
  name `desktop-ubuntu26`; `desktop-ubuntu26.gg.ez` resolves via MagicDNS.
- WSL sshd is **live** on `0.0.0.0:22` but its `authorized_keys` lacks the fleet
  keys → `ssh methe@100.64.0.6` gives `Permission denied (publickey)`.
- `provision/linux.sh` **already** installs a `fleet-selfpull` systemd-user timer
  (~10 min) and a fetch-only `git-autofetch` timer, but does **not** wire
  ssh-server `authorized_keys`.
- Both `fleet-pull.sh` (/ship) and `fleet-gather.sh` (kb-refresh) enumerate
  `fleet.json` members and dispatch `bash -s` — so the fix must be shared.

## Decisions

1. **Windows dispatch = Git Bash, platform-driven.** `fleet-pull`/`fleet-gather`
   read each member's `platform` from `fleet.json`; for `platform: windows` they
   invoke Git Bash explicitly so the generic remote script runs against the
   Windows-native clone. (Rejected: reusing `fleet-selfpull.ps1` — pulls all repos,
   different table token; reordering PATH — global/invasive.)
2. **WSL between-ship freshness = the selfpull timer already in `linux.sh`.** Just
   ensure it's active in the distro; no new timer code. (User asked to "add" it;
   discovered it already exists.)
3. **Shared dispatch helper.** Extract the platform-aware remote-bash selection
   into one lib sourced by both tools, so `desktop`=Windows-native and
   `desktop-ubuntu26`=WSL behave consistently across `/ship` and kb-refresh.

## Design

### Fleet model

Two members, each mapping to exactly one clone:

| Member | Tailnet IP | SSH lands in | Clone `/ship` updates |
|---|---|---|---|
| `desktop` | 100.64.0.4 | PowerShell → Git Bash | `C:\Users\methe\machines` |
| `desktop-ubuntu26` | 100.64.0.6 | WSL sshd → bash | `/home/me/machines` |

### 1. `fleet.json` + SSH alias

Add member:

```json
"desktop-ubuntu26": {
  "platform": "linux",
  "tailnet": { "ip": "100.64.0.6" },
  "roles": ["base", "ssh-server", "agents", "dotfiles", "repos"],
  "detect": { "hostname": "desktop-ubuntu26" }
}
```

- No `ssh.user` — WSL user is `me` (the fleet default), so `ssh.nix` emits no User
  override.
- `ssh.nix`/`fleet.nix` auto-generate the `desktop-ubuntu26` client alias; HostName
  comes from MagicDNS (`desktop-ubuntu26.gg.ez`), so no `ssh.host` override.
- Set the WSL OS hostname to `desktop-ubuntu26` (`hostnamectl` / `/etc/hostname`;
  currently `g614jv`). fleet-pull's `self_alias()` matches by tailnet IP so this is
  cosmetic, but it removes the `g614jv` collision with the Windows member and makes
  `detect.hostname` truthful.

### 2. WSL ssh-server `authorized_keys` (the real gap)

Add an ssh-server step to `provision/linux.sh` that merges
`provision/fleet-authorized-keys` into `~/.ssh/authorized_keys` (create with
`0700 ~/.ssh`, `0600` the file, dedup so re-runs are idempotent). Mirrors
`modules/system/ssh-server.nix` (NixOS) and `windows.ps1` step 7 (Windows). This is
what makes `ssh desktop-ubuntu26` succeed from every fleet member. Gate it on the
`ssh-server` role being declared for the box (or run unconditionally in `linux.sh`,
matching how it already installs the selfpull timer unconditionally — decide in the
plan; leaning unconditional for simplicity since `linux.sh` is WSL/dev-box scoped).

### 3. Shared platform-aware dispatch helper

New `agents/plugin/skills/lib/fleet-dispatch.sh`, sourced by `fleet-pull.sh` and
`fleet-gather.sh`. Responsibility: given a member alias + its `platform`, produce
the correct remote-bash invocation.

- `linux` → `ssh <opts> <alias> bash …` (unchanged).
- `windows` → `ssh <opts> <alias> '& "C:\Program Files\Git\bin\bash.exe" …'` —
  PowerShell's call operator launches Git Bash; `$HOME=/c/Users/methe` so the
  existing remote script finds `C:\Users\methe\machines` first.

Interface (to finalize in the plan): a function that both callers use to run a
remote bash reading its script from stdin, supporting the two shapes in use today
(`bash -s -- <args>` and `bash -lc "'<cmd>'"`). Both callers gain a read of
`.machines[].platform` alongside the existing key enumeration.

**Correctness of first-match under the split:** `desktop` runs in Git Bash where
`$HOME=/c/Users/methe` → matches `/c/Users/methe/machines` (no `/mnt/c` in Git
Bash). `desktop-ubuntu26` runs in WSL where `$HOME=/home/me` → matches
`/home/me/machines` first. No overlap; each member updates exactly its own clone.

**To verify in implementation:** stdin piping through PowerShell's `&` operator
into `bash -s` (ssh forwards local stdin to the remote command; PowerShell `&`
should inherit it). If problematic, fall back to a here-string or a temp-file
transfer for Windows members.

### 4. WSL freshness between ships

Already provided by `linux.sh`'s `fleet-selfpull` systemd-user timer (~10 min).
Design action: verify it's active in Ubuntu-26.04; if `linux.sh` hasn't been fully
run there, run it. The Windows `fleet-selfpull` Scheduled Task (C: clone) is
unchanged.

### 5. Docs / memory / tests

- Correct the global-memory bullet added 2026-07-21 (it says the C: clone "must be
  pulled manually" / that WSL vs Windows aren't both covered) to describe the new
  two-member model.
- Update the fleet section + two-layer-hostname convention in `AGENTS.md`
  (→`CLAUDE.md`) and `provision/README.md` to list `desktop-ubuntu26`.
- Extend `fleet-pull.test.sh` (+ gather tests) with a `platform: windows` → Git
  Bash dispatch case using the mock `SSH` override.
- Live verification: `ssh desktop-ubuntu26` works after the keys step; one `/ship`
  produces distinct OK rows for both `desktop` and `desktop-ubuntu26`, and both
  clones advance to the pushed HEAD.

## Out of scope (YAGNI)

- The `docker-desktop` and `Ubuntu-24.04` distros stay off the fleet.
- No `.wslconfig` / WSL networking changes (inbound already works via DERP).
- No PATH reordering on Windows.
- No `just provision` role executor for WSL — `linux.sh` remains its provisioner.

## Risks

- **PowerShell `&` + stdin** into Git Bash `-s` may need a fallback (noted above).
- **WSL sshd persistence:** the node must be up for `/ship` to reach it; if the
  distro/sshd is down, fleet-pull reports `SKIP unreachable` (acceptable — same as
  any offline member).
- **Two members, one physical box:** both share `g614jv` at the OS level until the
  WSL hostname is changed; mitigated by IP-based `self_alias` and the rename.
