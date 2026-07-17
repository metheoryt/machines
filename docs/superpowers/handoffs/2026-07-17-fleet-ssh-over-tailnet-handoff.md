# Handoff: fleet SSH-server over the Headscale tailnet

Date: 2026-07-17
For: the NEXT session. Start with the **brainstorming** skill (design → spec →
plan → implement). This is a real design pass touching provisioning + firewall
/ security posture on every box — not an ad-hoc patch.

## One-line problem

The AWG→Headscale migration moved the fleet's **transport** (Headscale tailnet)
but left the **SSH-server role** — sshd enablement + firewall scoping — pinned to
the retired AmneziaWG mesh (`10.0.0.0/24` / `awg0`). So SSH-over-the-tailnet does
not actually work fleet-wide. Re-home the SSH-server role onto the tailnet
(`100.64.0.0/10` / `tailscale0`), keys-only, on both NixOS and Windows.

## How we got here (context)

This came out of shipping `provision/ssh-wsl.sh` (a WSL2 leaf node that SSHes
*out* to the fleet). That feature is **DONE and merged** — do not redo it. See
`docs/superpowers/specs/2026-07-17-ssh-wsl-fleet-design.md` and
`docs/superpowers/plans/2026-07-17-ssh-wsl-fleet.md`. While verifying `ssh
<host>` *from* the WSL box, we found the fleet's SSH targets aren't reachable
over the tailnet.

## Evidence (verified this session)

**NixOS side — `modules/system/mesh-vpn.nix`:**
- The whole config is `config = lib.mkIf cfg.enable { … }` where
  `cfg = config.fleet.meshVpn`. Inside that block live **all three** of:
  `services.openssh.enable = true`, the port-22 firewall rules, and
  `users.users.me.openssh.authorizedKeys.keyFiles = [ ../../provision/mesh-authorized-keys ]`.
- Firewall opens 22 on **`awg0`** only (`networking.firewall.interfaces.awg0.allowedTCPPorts = [22]`)
  plus LAN `192.168.8.0/24` via `extraCommands` iptables. **Never `tailscale0`.**
- `hosts/latitude/nixos/configuration.nix:84-87` sets `fleet.meshVpn.enable = false;`
  (headscale cutover). ⇒ latitude has **no sshd at all** (`systemctl is-active sshd`
  → inactive; unit not-found), and `mesh-authorized-keys` is **not loaded**. Only
  `services.tailscale.enable = true` (tailnet transport, joined imperatively).

**Windows side — `provision/windows.ps1`** (confirmed by running it on `desktop`
this session):
- Creates firewall rule `OpenSSH-Server-Mesh-LAN` allowing 22 from `10.0.0.0/24`
  (AWG) + `192.168.8.0/24` (LAN), and **disables** the default
  `OpenSSH-Server-In-TCP` (Any) rule.
- Net effect: tailnet peers (`100.64.0.0/10`) are **blocked**. Running it on
  desktop actually *regressed* tailnet SSH (it was open before via the Any rule).
- sshd itself runs fine (keys-only: PasswordAuthentication no,
  KbdInteractiveAuthentication no), default shell PowerShell, and
  `administrators_authorized_keys` is regenerated from `mesh-authorized-keys`
  (ACL-locked). Only the **firewall scoping** is wrong for the tailnet era.

## What works / doesn't (from the WSL box, `ssh <alias>`)

| Target | sshd? | Trusts id_fleet? | Tailnet-reachable :22? | `ssh <host>` today |
|---|---|---|---|---|
| `hub` (debian@cyphy.kz) | yes | yes (added by hand this session) | yes (public) | ✅ verified `HUB_OK` |
| `server` (Windows, 100.64.0.3) | yes | **windows.ps1 NOT yet run** | no (AWG/LAN-scoped once run) | ❌ |
| `desktop` (Windows, 100.64.0.4) | yes | yes (windows.ps1 ran) | **no — firewall now AWG/LAN only** | ❌ (regressed) |
| `latitude` (NixOS, 100.64.0.2) | **no sshd** | no (keyFiles gated off) | no | ❌ |

`hub` works only because it's plain Debian outside this scheme (its
`~debian/.ssh/authorized_keys` is hand-managed; `id_fleet` was appended manually
and is not part of the module work below).

## Scope of the fix

Re-home the SSH-server role onto the tailnet, decoupled from `fleet.meshVpn`:

1. **NixOS** — a way to run keys-only sshd reachable on the tailnet, independent
   of the (disabled, legacy) AWG mesh, with the `mesh-authorized-keys` trust.
   Open 22 from `100.64.0.0/10` **or** trust the `tailscale0` interface. Must
   apply to every NixOS member (latitude, g16).
2. **Windows (`windows.ps1`)** — allow 22 from `100.64.0.0/10` (the tailnet)
   instead of / in addition to `10.0.0.0/24`. Decide whether to keep the LAN
   rule and whether to retire the AWG range entirely for our machines.

Keep: keys-only (`PasswordAuthentication no`), the single committed
`provision/mesh-authorized-keys` trust file, no public-interface exposure.

## Open questions for brainstorming (decide these)

- **NixOS structure:** new dedicated module (e.g. `fleet.sshServer`) imported by
  all NixOS hosts, vs. un-gating/refactoring `mesh-vpn.nix`? A new module cleanly
  separates "SSH-server role" from "AWG mesh" (which is now legacy for our boxes).
- **Firewall method:** source-CIDR `100.64.0.0/10` (mirrors the existing LAN
  `extraCommands` pattern) vs. interface-based
  (`networking.firewall.interfaces.tailscale0.allowedTCPPorts` /
  `trustedInterfaces = ["tailscale0"]`). Interface-based is cleaner but depends on
  `tailscale0` being up; consider the nixpkgs `services.tailscale` firewall hooks.
- **AWG retirement:** AmneziaWG stays ONLY as the obfuscated VPN for RU
  relatives/friends on the VPS hub — our own machines don't use the AWG *mesh*
  anymore. Should the AWG-scoped SSH rules be removed outright, or left behind the
  (off) `fleet.meshVpn` flag as dormant legacy?
- **Windows LAN rule:** keep `192.168.8.0/24`, or tailnet-only?

## Fleet facts (constants the design must respect)

- Control server: `https://cc.cyphy.kz` (Headscale v0.29.2, embedded DERP region
  999). MagicDNS suffix **`gg.ez`** (NOT `fleet.mesh` — stale in some old docs).
  Tailnet CGNAT range **`100.64.0.0/10`**. Interface `tailscale0`.
- Fleet IPs: hub `100.64.0.1`, latitude `100.64.0.2`, server `100.64.0.3`,
  desktop `100.64.0.4`, WSL leaf `100.64.0.6`.
- `provision/mesh-authorized-keys` = the single committed public-keys trust file,
  consumed by NixOS (`authorizedKeys.keyFiles`) and Windows
  (`windows.ps1` → `administrators_authorized_keys`). It now contains the WSL leaf
  key `me@wsl-desktop`.
- `fleet.json` is the source of truth (read via `mesh-vpn-params.nix`,
  `builtins.fromJSON`). Members: latitude/desktop/server/hub. The WSL box is a
  **leaf**, deliberately NOT in `fleet.json`.
- `modules/home/ssh.nix` generates `~/.ssh/config` client blocks from `fleet.json`
  (HostName only for the hub → cyphy.kz; bare MagicDNS names otherwise; `User`
  when `ssh.user != me`; `StrictHostKeyChecking accept-new`). Don't break it.

## Verification (definition of done for the next session)

After the change + `nixos-rebuild switch` on NixOS hosts + re-running
`windows.ps1` on the Windows hosts, from the WSL box (or any tailnet node):
- `ssh -o BatchMode=yes latitude true` → succeeds
- `ssh -o BatchMode=yes server true` → succeeds
- `ssh -o BatchMode=yes desktop true` → succeeds
- No regression to existing LAN/other access.

## Executor / environment notes

- The assistant's Bash tool runs on **latitude5520** (100.64.0.2, NixOS). `sudo`
  there needs a **password** — the assistant cannot `nixos-rebuild switch`
  autonomously; the user runs it (`cd ~/machines && just switch`, or via the `!`
  prefix so output is visible).
- SSH reachable from latitude: `me@100.64.0.6` (WSL box), `debian@cyphy.kz` (hub,
  **passwordless sudo**), `methe@100.64.0.3` (server), `methe@100.64.0.4`
  (desktop). Windows changes need Administrator → user runs `windows.ps1`.
- Shell for the Bash tool is **fish**: use bash-compatible one-liners; avoid fish
  `for … end` loops (they mis-parse); `<<<` here-strings only inside a `bash`
  script/file. shellcheck via `nix run nixpkgs#shellcheck -- <files>` (no system
  shellcheck).
- Repo workflow: work on `main`, commit + push when ready. Commit trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Pre-commit hooks run
  shellcheck/alejandra/whitespace/end-of-file-fixer.
- `just switch` gotcha seen this session: Home Manager aborts if profile symlinks
  in `~/.codex` / `~/.claude` point into a transient worktree (a bootstrap run
  from a worktree). Fix: remove the stray worktree-pointing symlinks, re-switch.

## Immediate cleanup still pending (independent of the design)

- **server:** `windows.ps1` has NOT been run there yet (only desktop). Whenever it
  is, the same firewall-scoping fix applies — so fold it into this work rather than
  running the current (AWG-scoped) script.
- **desktop:** its firewall is currently AWG/LAN-scoped (tailnet blocked) from this
  session's `windows.ps1` run — the fix restores tailnet reachability.
