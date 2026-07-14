# Fleet reachability over the tailnet: SSH aliases + name resolution

_Design — 2026-07-14_

## Problem

The fleet's mesh transport migrated from AmneziaWG (`10.0.0.0/24`) to
Headscale/Tailscale (`100.64.0.0/10`). Two pieces of the SSH/name story did not
follow the transport and are now half-migrated:

1. **SSH aliases.** `modules/home/ssh.nix` generates each fleet member's SSH
   `HostName` from its AmneziaWG mesh IP (`fleet.json` `mesh.ip`, exposed as
   `params.hosts.<name>`). But `homeserver` has AWG *removed* and `latitude5520`
   has its AWG spoke *disabled* — both are tailnet-only now — so those
   `10.0.0.x` HostNames route nowhere. From a NixOS box, `ssh homeserver` dials a
   tunnel that no longer exists.

2. **Name resolution generally.** There is no fleet-wide way to reach a box by
   name outside SSH (`ping homeserver`, `curl homeserver:8001`, a browser).
   MagicDNS could provide it but requires `--accept-dns` plus a working resolver
   on each box — not configured, and a live interference risk (latitude already
   disabled `meshVpn` over split-tunnel/DNS trouble).

## Goals

- `ssh <member>` from any fleet box reaches that box over the **tailnet**.
- Every fleet box resolves every other box **by name** (`homeserver`,
  `g614jv`, `vps`, `latitude5520`) for *all* tools, not just SSH — without a DNS
  resolver or `--accept-dns`.
- `fleet.json` remains the single source of truth for fleet addressing.

## Non-goals / out of scope

- **No AWG changes.** `mesh.ip` and the AWG params in `mesh-vpn-params.nix` stay
  untouched — the VPS still runs AWG for relatives, and that config reads them.
- **No MagicDNS.** Explicitly rejected (see Decisions).
- **Not removing the dormant AWG Nix module.** `fleet.meshVpn` is now enabled on
  zero boxes (latitude `false`; the rest are Windows/Debian with no Nix AWG
  module), so the AWG *Nix* module is dormant — but ripping it out is a separate
  roadmap item.

## Decisions

1. **Full-tailnet SSH, no dual-stack.** Among our own boxes, AWG SSH reaches
   nothing the tailnet doesn't: the VPS answers on its public `cyphy.kz`,
   g614jv answers on its tailnet IP, latitude/homeserver AWG is gone. One target.

2. **Raw tailnet IPs (`100.64.0.x`), not MagicDNS names.** Headscale assigns
   stable per-node IPs, so the "names survive IP churn" upside barely applies to
   a 4-box fleet, and an IP change is the same one-line `fleet.json` edit we
   already make for `mesh.ip`. MagicDNS needs `--accept-dns` + a resolver
   (neither configured; DNS interference is a live risk class on latitude), and
   nothing needs names at the DNS layer (RustDesk uses IDs, Caddy already targets
   `100.64.0.3`). Raw IPs always route and mirror today's pattern.

3. **The hub (VPS) SSH stays on its public hostname `cyphy.kz`.** The VPS *is*
   the Headscale control server; SSHing to it over the tailnet would make
   managing it depend on the transport it hosts. Public hostname keeps it
   reachable even when the tailnet/DERP is down. (This is the existing
   `mesh.role == "hub"` branch in `ssh.nix` — unchanged.)

4. **`fleet.json` gains a parallel `tailnet` block**, alongside (not replacing)
   `mesh`:

   ```json
   "homeserver": {
     "mesh":    { "ip": "10.0.0.2", ... },
     "tailnet": { "ip": "100.64.0.3" }
   }
   ```

5. **Two propagation mechanisms, matching this repo's declarative-vs-executor
   split** (as `agents`/`dotfiles` already do): NixOS is handled declaratively in
   Nix; Windows/Debian are handled by a provisioner role executor that is a
   **no-op on NixOS**.

## Source of truth

`fleet.json` `tailnet.ip` per machine, keyed by the fleet name. Tailnet IPs:

| Name | tailnet.ip |
|---|---|
| vps | `100.64.0.1` |
| latitude5520 | `100.64.0.2` |
| homeserver | `100.64.0.3` |
| g614jv | `100.64.0.4` |

Every member needs `tailnet.ip` present: `ssh.nix` and the hosts generator both
`mapAttrs` over all machines, and a missing attribute throws at eval. The hub's
`tailnet.ip` is added for consistency and hosts-file use even though the SSH
generator never forces it (Nix `if` is lazy).

## Components

### 1. SSH alias generator — `modules/home/ssh.nix`

One functional line changes. `mkBlock name m` already iterates
`params.machines`, so it reads `m.tailnet.ip` directly — **no** new derived map
in `mesh-vpn-params.nix`:

```nix
HostName =
  if m.mesh.role == "hub"
  then params.endpoint   # cyphy.kz — hub SSH must not depend on the transport it hosts
  else m.tailnet.ip;     # was: params.hosts.${name}  (the dead AWG IP)
```

Plus a header-comment rewrite (it currently describes keying HostName on the AWG
mesh IP). `mesh-vpn-params.nix` needs no edit — it already exposes `machines`.

### 2. NixOS name resolution — a generated `networking.hosts`

A small system module builds NixOS's `networking.hosts`
(`attrsOf (listOf str)`, IP → hostnames) from `fleet.json`, reusing the existing
single `fromJSON` site (import `mesh-vpn-params.nix`, map `m.tailnet.ip → name`
over `.machines`). Imported by the NixOS host config; applied by
`nixos-rebuild switch`. Result on the box:

```
100.64.0.1   vps
100.64.0.2   latitude5520
100.64.0.3   homeserver
100.64.0.4   g614jv
```

Self-entries are included uniformly (harmless; `localhost` still covers real
loopback).

### 3. Cross-platform name resolution — a new `hosts` provisioner role

`provision/roles/hosts.{sh,ps1}`, wired like the existing roles (generic
`role_<name>` dispatch in `provision.sh`; one `$RoleExecutors` map entry in
`provision.ps1`). Behavior:

- **NixOS:** no-op (the Nix module in Component 2 owns it), same as
  `agents`/`dotfiles`.
- **Windows / Debian:** rewrite a **marker-delimited managed block** in the
  system hosts file (`C:\Windows\System32\drivers\etc\hosts` / `/etc/hosts`):

  ```
  # BEGIN fleet hosts (managed by provision — do not edit)
  100.64.0.1   vps
  100.64.0.2   latitude5520
  100.64.0.3   homeserver
  100.64.0.4   g614jv
  # END fleet hosts
  ```

  The executor strips any existing block between the markers and writes a fresh
  one from `fleet.json`, so re-runs converge and content outside the block is
  never touched. Honors `DRY_RUN` (prints the intended block/diff, mutates
  nothing) and the per-role confirm-gate. Writing the file needs admin/root.

The `hosts` role is added to each machine's `roles` in `fleet.json`.

## The hub name quirk (intentional)

`ssh vps` resolves via the `ssh.nix` Host alias → `cyphy.kz` (Decision 3), while
`ping vps` / `curl vps` resolve via the hosts file → `100.64.0.1`. The ssh Host
alias's explicit `HostName` overrides the hosts file for SSH only; every other
tool uses the tailnet IP. Each path is correct for its purpose; documented here
so the divergence is expected, not a bug.

## Verification scope

- **Session-verifiable (declarative):** `fleet.json` `tailnet.ip` fields, the
  `ssh.nix` change, and the `networking.hosts` module — via `nix flake check` and
  `nix eval` of the generated SSH config and hosts map, in **both** the NixOS-HM
  and standalone-home contexts (the Phase 5a acceptance gate).
- **Session-verifiable (executor):** the `hosts` role — POSIX/PowerShell parse,
  `DRY_RUN` prints the correct managed block and mutates nothing, converged
  re-run is clean, confirm-gate skips on "n" with rc=0.
- **Real-box (runbook, not session-verified):** actual `ssh homeserver` from
  latitude after `switch`; `getent hosts homeserver` on latitude;
  `hosts` role `--apply`/`-Apply` (answer y) on g614jv/homeserver (Windows,
  admin) and vps (Debian, root), then resolve a fleet name with a non-SSH tool.

## Implementation staging

- **Stage 1 — declarative (fully session-verifiable):** `fleet.json` `tailnet.ip`
  + `ssh.nix` one-liner + `networking.hosts` module.
- **Stage 2 — the `hosts` role executor (mostly real-box):** `hosts.{sh,ps1}`,
  wiring, and `fleet.json` `roles` entries. Session tests as above; apply is a
  per-box runbook item.

## What consumes this

`ssh.nix` and the `networking.hosts` module are NixOS/home-manager, so in
practice they render on **latitude5520** and the standalone-home flake-check
target — Stage 1 changes latitude's *outbound* SSH plus its local name
resolution. The `hosts` role is what carries name resolution to the
Windows/Debian boxes.
