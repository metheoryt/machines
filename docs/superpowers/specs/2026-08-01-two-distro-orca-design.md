# Two-distro Orca on desktop: one WSL distro per Claude account

**Date:** 2026-08-01
**Status:** design approved — not yet implemented
**Branch:** `metheoryt/Pure-WSL`

## Goal

One WSL distro per Claude account, each running a headless `orca serve` daemon,
both reached as remote servers from the Windows Orca UI on `desktop` and from
the `air` laptop.

| distro | account | holds |
|---|---|---|
| `desktop-wsl` (renamed from `Ubuntu-26.04`) | metheoryt@gmail.com | personal repos |
| `desktop-pure` (new) | maxim.romanyuk@pure.app | `~/pure/*` |

The shape generalizes: one distro per client, one for me. Each distro is its own
account, its own repos, its own encapsulation boundary, and sessions on both run
at the same time.

## Findings that shaped the design

All established by live probe on 2026-08-01, not assumed. Several **invert
premises documented elsewhere in this repo** — read this section before
designing anything adjacent.

### WSL2 distros share ONE network namespace

Proven three ways:

1. `readlink /proc/self/ns/net` returns `net:[4026531833]` in **both**
   `Ubuntu-26.04` and `Ubuntu-24.04`.
2. `ss -ltn` inside 24.04 lists 26.04's listeners — `hermes:9119`,
   `100.64.0.6:61927`, `*:8100`, `*:5436` — none of which run in 24.04.
3. Neither `ss` shows a Process column for the other's sockets: shared network
   namespace, separate PID namespace.

**This makes `provision/tailscale-wsl.sh`'s header comment false.** It claims:

> Model: one tailscaled PER distro (NOT host mirrored-networking), so N distros
> on one Windows host each get a distinct identity with no port juggling.

There is no such isolation. The script was only ever run one-distro-at-a-time.
Correcting that comment is a deliverable of this spec — a false premise left in
a provisioning script is how a future session rebuilds this wrong.

Consequences:
- Two `orca serve` instances cannot both bind `6768`. Ports are allocated.
- A second `tailscaled` cannot create a second `tailscale0`. The work distro
  gets no tailnet node of its own.
- `:22` is held by one distro only.

*Method note for future sessions:* a cross-distro `bind()` test was run first
and reported "separate netns". It was wrong — the backgrounded listener in the
other distro never came up, so the successful bind measured nothing. Compare
`ns/net` inodes and listener tables instead.

### Per-distro netns was considered and rejected

Restoring per-distro tailnet identity would mean `ip netns add`, a veth pair into
the shared init namespace, MASQUERADE, `/etc/netns/<n>/resolv.conf`, and
`NetworkNamespacePath=` drop-ins on `tailscaled` / `sshd` / `orca-serve` — with
`orca serve`'s PTY children inheriting the namespace, so every agent session's
DNS, git-over-SSH, Docker, and outbound HTTPS ride on it. The veth peer and
netfilter rules would land in the **shared** namespace, visible to the other
distro. Rejected as disproportionate; colocation on the shared namespace with
distinct ports achieves the same user-visible result.

### Orca's WSL managed-account machinery is irrelevant here

Reverse-engineered from
`/mnt/c/Users/methe/AppData/Local/Programs/orca/resources/app.asar`
(Orca 1.4.162, Windows).

`getPreparation(target)` has three WSL branches. The **managed-account** branch
is the destructive one — it points `CLAUDE_CONFIG_DIR` at an auth-only slot, so
that slot becomes the entire profile: no settings, no plugins, no memory, no
statusline. But it is only reached when a WSL managed account is active. With
none active, the fall-through gives:

```js
configDir:         join(wslHome, ".claude"),
wslLinuxConfigDir: `${linuxPath}/.claude`,
envPatch:          {},          // no CLAUDE_CONFIG_DIR override
stripAuthEnv:      true,
provenance:        `wsl:${distro}:system`
```

That is the distro's native `~/.claude` — full profile intact.

Stronger still, and decisive for this topology: **`orca serve` runs inside the
distro**, so `process.platform === "linux"`. `getDefaultAccountSelectionTarget()`
guards its WSL branch on `process.platform === "win32"`, so it returns
`{runtime: "host"}` and `configDir` resolves to `paths.configDir` — that distro's
own `~/.claude`. The entire WSL managed-account apparatus is a Windows-local
concern and is never consulted in the remote-server topology.

`stripAuthEnv: true` is set on every branch, but its consumer deletes only
`CLAUDE_AUTH_ENV_VARS` (the `ANTHROPIC_API_KEY` family) plus
`ANTHROPIC_CUSTOM_HEADERS`. OAuth credentials in `~/.claude/.credentials.json`
are unaffected.

This also settles the open question about `settings.localAccountWslDistro` being
a single global value: nothing in this design reads it. It stays unset.

### WSL interop is intermittently lost at runtime

The persisted fix `/usr/lib/binfmt.d/WSLInterop.conf` containing
`:WSLInterop:M::MZ::/init:PF` **does not work and should not be carried
forward.**

`systemd-binfmt` on WSL 2.7.10 carries a WSL-injected `ExecStartPost`:

```sh
/bin/sh -c (echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop) ;
           (echo ":WSLInterop:M::MZ::/init:P" > /proc/sys/fs/binfmt_misc/register)
```

It runs *after* `systemd-binfmt` applies `/usr/lib/binfmt.d/*.conf`, unregistering
and re-registering. Evidence the conf file is inert: it declares flags `PF`, but
the live registration always reads `flags: P` — WSL's, never ours. Ubuntu-24.04
has no conf file at all, runs systemd, and interop works there.

But interop **does** die at runtime. It was lost mid-session on 2026-08-01 in
`Ubuntu-26.04` (`cmd.exe`, `wsl.exe`, `powershell.exe` all
`cannot execute binary file: Exec format error`) while the conf file was in
place, and the user hit the same failure on 2026-07-31. `journalctl -u
systemd-binfmt` shows the unit had not run since boot, so nothing in the boot
path removed it. Cause unidentified.

Explicitly **tested and ruled out**: starting a second distro does not cause it.

| step | 26.04 state |
|---|---|
| baseline | `WSLInterop` PRESENT |
| after `wsl -t Ubuntu-24.04` | PRESENT |
| after starting `Ubuntu-24.04` | PRESENT |
| +5 s | PRESENT |

Recovery is verified: `systemctl restart systemd-binfmt` restores it. When local
interop is the thing that is dead, drive it out-of-band:

```console
ssh desktop "wsl.exe -d desktop-wsl -u root -- systemctl restart systemd-binfmt"
```

This matters beyond convenience. `wslopen` shells out to Windows, so dead interop
breaks `claude auth login` — and there will now be two distros to log in.

### Disk

`Ubuntu-26.04` `/` is 42 G used of 48 G (92%). The breakdown says moving work
repos out frees nothing:

| path | size |
|---|---|
| `~/.hermes` | 23 G |
| `~/.cache` | 12 G |
| `~/.local` | 1.5 G |
| `~/my` | 1.2 G |
| `~/pure` | **100 M** |

`Ubuntu-24.04` is 13 G used, 33 G free. The 23 G `~/.hermes` is flagged as an
observation only — cleaning it is a separate decision, deliberately not folded
into this project.

C: has 1.17 TB free and `.wslconfig` sets `defaultVhdSize=52428800000` with
`sparseVhd=true`, so a third VHD is affordable.

### Dispatch through the Windows parent works

Verified end to end:

```console
$ printf 'echo "ok: arg1=$1 host=$(hostname) distro=$WSL_DISTRO_NAME"' \
    | ssh desktop "wsl.exe -d Ubuntu-24.04 -- bash -s -- HELLO"
ok: arg1=HELLO host=g614jv distro=Ubuntu-24.04
```

stdin-piped script, positional args, correct distro. This is the mechanism
`fd_run` needs, and `fd_wsl_hosts` already uses the same shape for discovery.

### The rename is cheap right now

`desktop-ubuntu26` appears **only under `docs/`** — zero occurrences in any
`.sh`, `.ps1`, `.nix`, or `.json`. Its live bindings are:

- the Headscale node name (`tailscale set --hostname`)
- `fleet.local.json` (gitignored, regenerated by `fleet-local.sh`)
- the dotfiles branch, plus its guard at `~/.local/state/dotfiles-sync/branch`
- MagicDNS usage, which resolves through the catch-all `Host *.gg.ez` — there is
  no per-WSL-host block in `~/.ssh/config`

WSL has no `--rename`; the distro name lives at
`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\{guid}\DistributionName`.
Its two real consumers — the Windows-side `\\wsl.localhost\Ubuntu-26.04\…` repo
registrations and the `activeClaudeManagedAccountIdsByRuntime.wsl["Ubuntu-26.04"]`
key — are both being deleted by this project anyway, so the timing is ideal.

## Target architecture

```
air (MacBook, thin UI)  ──ws──┐
                              ├─▶ 100.64.0.6 : 6768   desktop-wsl   (personal)
Windows Orca UI (desktop) ────┘   100.64.0.6 : 6769   desktop-pure  (work)

  ┌─ WSL2 utility VM — ONE network namespace ──────────────────────────┐
  │                                                                    │
  │  desktop-wsl                        desktop-pure                   │
  │   tailscaled  → 100.64.0.6  ◀── the VM's node, shared by both      │
  │   sshd :22                          (no tailscaled, no sshd)       │
  │   orca serve :6768                  orca serve :6769               │
  │   ~/.claude  (personal OAuth)       ~/.claude  (work OAuth)        │
  │   gortex daemon (personal repos)    gortex daemon (~/pure/* only)  │
  │   ~/my/*, ~/machines, …             ~/pure/*                       │
  └────────────────────────────────────────────────────────────────────┘
```

Windows Orca registers **zero local repos**. Every repo lives in its own distro's
Linux `orca serve` runtime registry. The `orca repo list` registry is
per-runtime — queried from a WSL shell it returned empty on 2026-07-31 precisely
because the repos were registered in the Windows runtime.

## Components

### 1. Port and identity allocation

| resource | `desktop-wsl` | `desktop-pure` |
|---|---|---|
| `orca serve` | `6768` (default) | `6769` (`--port`) |
| gortex daemon | existing port, unchanged | distinct port — shared netns |
| sshd | `:22` | none |
| tailnet node | owns `100.64.0.6` | none |
| fleet dispatch | direct `ssh desktop-wsl.gg.ez` | via Windows parent |
| dotfiles branch | `desktop-wsl` | `desktop-pure` |

`DEFAULT_WS_PORT = 6768` and a `--port` flag are both confirmed present in the
Orca bundle.

### 2. Deliberate asymmetry in fleet dispatch

`desktop-wsl` is dispatched directly over SSH; `desktop-pure` is dispatched
through the Windows parent. This is a decision, not drift.

`desktop-wsl` owns the VM's `tailscaled` and the `:22` bind, so its direct path
already works and is proven. `desktop-pure` cannot have either. Routing it
through the parent was chosen over giving it sshd on an alternate port for two
reasons:

- **Discovery already requires the parent.** `fd_wsl_hosts` enumerates a distro
  by `ssh <windows-member> "wsl.exe -d $d -- bash -lc 'cat …/fleet.local.json'"`.
  If the Windows box is down the distro is never enumerated, so it is never
  dispatched to either. The "direct SSH survives Windows being down" argument
  buys nothing on this code path.
- **It does not scale.** Consumers build the SSH target themselves as
  `"$nick${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}"`, resolved by the catch-all
  `Host *.gg.ez`. A port-bearing distro would need a fabricated
  `Host desktop-pure.gg.ez` → `HostName desktop-wsl.gg.ez` / `Port 2222` block —
  a name that is not DNS — added to **three** generators (`provision/lib/tiers.sh`,
  `provision/lib/fleet-ssh-config.ps1`, `modules/home/ssh.nix`), repeated for
  every future client distro. Parent routing costs zero fleet-wide config per
  distro.

Parent routing also means **no sshd in the work distro at all** — no alternate
port, no inbound surface.

A third distro joins via parent routing like `desktop-pure`. The direct path
stays a one-off for the node owner.

### 3. `provision/wsl-fixes.sh` (new)

Idempotent, safe to re-run, added as a step in the `provision-wsl.sh` chain —
**not** in `linux.sh`, which is shared with the Debian VPS `hub`.

1. Install `~/.local/bin/wslopen` plus its `xdg-open` and `wslview` symlinks.
   Currently untracked and machine-local on 26.04; this is what makes
   `claude auth login --claudeai` complete instead of hanging for the full
   `LOGIN_TIMEOUT_MS = 18e4`. (Not `wslu` — absent from the Ubuntu 26.04 archive.)
2. Install a **binfmt watchdog**: a root systemd timer that re-registers
   `WSLInterop` when it goes missing, replacing the inert
   `/usr/lib/binfmt.d/WSLInterop.conf`. Recovery action is the verified
   `systemctl restart systemd-binfmt`.
3. Note 26.04's existing `WSLInterop.conf` as removable.

### 4. Documentation corrections in `provision/`

- `tailscale-wsl.sh` header: the per-distro-tailscaled claim is false; distros
  share one network namespace and one node.
- `provision-wsl.sh` header: "The nickname is BOTH the tailnet node name and the
  `fleet.local.json` nickname" holds only for the node-owning distro. For every
  other distro the nickname is a fleet identity and dispatch key only.

### 5. Per-distro Claude profile

Native `~/.claude` in each distro, one `claude auth login --claudeai` each. The
redundant WSL managed account `4e09ba8b-…` is deleted;
`settings.localAccountWslDistro` stays unset; no managed account is created
again.

### 6. Orca Linux runtime, per distro

- Move `~/.local/bin/orca-ide` aside first. The serve log proves it blocks
  serve's own CLI install: `orca CLI install skipped: Refusing to replace
  non-Orca command at /home/me/.local/bin/orca-ide`.
- Clear stale `~/.config/orca/` leftovers.
- Install the Linux Orca AppImage to `~/.local/opt/orca` (currently empty in both
  distros; `~/.local/bin/orca` is gone).
- `orca serve` as a systemd **user** unit with `loginctl enable-linger me`, so a
  distro with no interactive session stays alive.

**Linger is unverified for `desktop-pure` and must be proven in Phase 4.** It is
known to work on `desktop-wsl`, which is opened interactively all the time. The
work distro's whole premise is the opposite: it runs untouched while `air` talks
to it over the tailnet, and WSL's boot path is not a normal one — a distro that
is never `wsl -d`'d may not start its user manager at all. Fallback if linger
does not hold: a **system** unit with `User=me`. Rejecting per-distro netns freed
that option, since `NetworkNamespacePath=` is no longer needed.

### 7. `desktop-pure` creation

Fresh Ubuntu-26.04 rootfs via `wsl --import`, own 52 GB sparse VHD.
`/etc/wsl.conf`: `[boot] systemd=true`, `[user] default=me`. `Ubuntu-24.04` is
left untouched.

Provisioned with `just provision-wsl desktop-pure`, **minus** the
`tailscale-wsl.sh` step — it has no tailnet node. `provision-wsl.sh` hardcodes
its four-step chain, so this needs a `--no-tailscale` flag that skips step 1 and
is threaded through the `just` recipe. Without it the script would try to enroll
a second `tailscaled` into the shared namespace.

### 8. Dotfiles

New branch `desktop-pure` off `main`, its own `~/.claude/host-memory.md`. The
existing branch `desktop-ubuntu26` is renamed to `desktop-wsl`, including the
guard file at `~/.local/state/dotfiles-sync/branch` — the sync timer refuses to
run when HEAD is not on the recorded branch.

**Neither distro may ever run `dotfiles checkout main`**: host-local paths are
tracked on the machine branch and absent from `main`, so the checkout deletes
them from `$HOME`, `~/.ssh/config` included.

### 9. Gortex

A second gortex daemon in `desktop-pure`, tracking `~/pure/*` only, so the work
index never sees personal repos and vice versa. Its listener shares the netns, so
it needs a port distinct from `desktop-wsl`'s daemon.

## The move

rsync at **identical paths**, so every Claude session slug stays byte-identical
and no `cwd` rewrite is needed — unlike the 2026-07-31 air→desktop migration,
where `/Users/me` → `/home/me` forced a per-transcript rewrite.

| what | size | note |
|---|---|---|
| `~/pure/{backend-api,backend-core,backend-schema-registry,claude-plugins}` | 100 M | working tree copied verbatim — preserves local branches, stashes, untracked files |
| `~/orca/workspaces/{backend-api,claude-plugins}` | small | one live worktree, `backend-api/test-worktree-setup` |
| `~/.claude/projects/-home-me-pure-backend-api` | 3.2 M | slug identical, straight copy |
| `~/.claude/projects/-home-me-pure-claude-plugins` | 8.3 M | same |

Then register the four repos in `desktop-pure`'s Linux `orca serve` registry, and
all ten personal repos in `desktop-wsl`'s — the Windows-local registry goes away
entirely, so anything not re-registered disappears from the UI. Per-repo worktree
setup/teardown config is re-done in the new runtime.

Deletion from `desktop-wsl` happens **only after** the work distro is proven, and
`dotfiles status` is checked immediately afterward.

> **`rm -rf ~/pure` will delete a dotfiles-tracked file.**
> `pure/backend-api/.claude/memory/project.md` is tracked on `main` at its real
> `$HOME` path, because the bare repo's work-tree *is* `$HOME`. Nothing errors —
> `dotfiles status` just shows a lone ` D`. Left alone, the sync timer's `add -u`
> stages the deletion, commits it to this machine's branch, and the next
> `/dotfiles-promote` offers to propagate it fleet-wide. This exact failure
> already happened on `air` on 2026-07-31. Recover with `dotfiles checkout --`.
> Corollary: the file arrives on `desktop-pure` via that distro's own branch
> checkout, never by copying.

## Phases

**Phase 0 — persist the fixes.** `provision/wsl-fixes.sh` with `wslopen` and the
binfmt watchdog; header corrections in `tailscale-wsl.sh` and `provision-wsl.sh`;
backfill by re-running on `desktop-wsl`. New `just` recipes need both
`[group('…')]` and `[doc('…')]` or `provision/tests/justfile.test.sh` fails.

**Phase 1 — rename.** `Ubuntu-26.04` → `desktop-wsl` in the Lxss registry;
tailnet node, `fleet.local.json`, dotfiles branch and its guard file. Re-enable
Docker Desktop's WSL integration for the renamed distro. Two steps that are easy
to discover mid-phase rather than plan for:

- The dotfiles branch has a **remote**. Push `desktop-wsl` and delete
  `origin/desktop-ubuntu26` — renaming the local branch and its guard file alone
  leaves the machine pushing to a branch nobody else expects.
- Verify `desktop-wsl.gg.ez` resolves through MagicDNS before relying on direct
  dispatch again, and check the old node name is gone from Headscale rather than
  lingering alongside the new one.

**Phase 2 — create and provision `desktop-pure`.** `wsl --import`, `wsl.conf`,
`provision-wsl.sh` minus the tailscale step, dotfiles branch off `main`.

**Phase 3 — parent routing.** `fleet.local.json` gains a routing hint;
`fd_probe` / `fd_run` learn to route WSL hosts through the Windows parent;
update the two consumer call sites in `agents/plugin/skills/ship/fleet-pull.sh`
and `agents/plugin/skills/kb-refresh/fleet-gather.sh`, plus the dispatch tests.

**Phase 4 — Orca runtime.** Move `orca-ide` aside, clear stale config, install
the AppImage, `orca serve` under systemd user units with linger, on both distros.
Register all repos in each distro's Linux runtime.

**Phase 5 — move.** rsync repos, workspaces, and session history to
`desktop-pure`. Verify `claude --resume` lists the transcripts there.

**Phase 6 — accounts and pairing.** `claude auth login` per distro; pair the
Windows Orca UI and `air` to both daemons; delete managed account `4e09ba8b-…`.

**Phase 7 — teardown.** Remove `~/pure` and the work workspaces from
`desktop-wsl`, only after the user confirms the work distro runs. Check
`dotfiles status` immediately after.

Ordering constraint: the `~/pure` move must happen with no active work sessions,
since this session runs from a worktree inside the distro being modified.

## Secrets

Pairing URLs, device tokens, runtime `authToken`s, and OAuth credential blobs
never reach a repo file, a memory store, or a commit. Two pairings means two
device tokens.

`~/.local/state/orca-serve.log` contains a live `deviceToken` in its pairing URL.
That path is never tracked, in either distro. The dotfiles `.gitignore` deny
block for key material stays exactly as it is.

## Risks

| risk | mitigation |
|---|---|
| `rm -rf ~/pure` silently deletes a `main`-tracked dotfiles path | `dotfiles status` immediately after; documented precedent from 2026-07-31 |
| `desktop-wsl` stopped ⇒ `desktop-pure` unreachable from `air` | it owns the VM's only `tailscaled`; it hosts the personal daemon and stays running, but the dependency is real |
| WSL interop dies at runtime, breaking `claude auth login` | binfmt watchdog in Phase 0; out-of-band recovery via `ssh desktop "wsl.exe -d <distro> -u root -- systemctl restart systemd-binfmt"` |
| A repo missed during re-registration vanishes from the Orca UI | enumerate the Windows-runtime registry before Phase 4 and check it off |
| `desktop-wsl` root at 92% | the move frees nothing (`~/.hermes` 23 G, `~/.cache` 12 G) — separate cleanup call, deliberately not folded in |
| Port collision from a third daemon in the shared netns | ports are allocated centrally in this spec's table; extend it, never pick ad hoc |
| Parent-routing dispatch regression in `/ship` and kb-refresh | `fd_wsl_hosts` now returns two nicknames; dispatch tests updated in Phase 3 |

## Accepted debt

- **`desktop-wsl` + `desktop-pure` mixes naming schemes** — one VM-scoped, one
  purpose-scoped. It is honest: `desktop-wsl` owns the tailnet node for the whole
  VM, and the personal distro happens to be its owner.
- **`Ubuntu-24.04` stays** on disk, stopped, holding an older work checkout. The
  2026-07-31 spec slated it for retirement; retiring it would reclaim a 48 GB VHD
  and is a separate call.
- **Dispatch is asymmetric** between the two distros, justified in §2.
