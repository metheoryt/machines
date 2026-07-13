# Headscale fleet-mesh probe — design

**Date:** 2026-07-13
**Status:** approved, pre-implementation
**Scope:** validation probe only — not a fleet-wide migration

## Context

The fleet mesh today is a single AmneziaWG network (hub on the VPS at
`10.0.0.1`, `/24`). That one network does double duty: it is both the
fleet's SSH-over-mesh spoke layer *and* the transport Caddy uses to reach the
homeserver's Docker services at `10.0.0.2`. The fleet-mesh half is codified but
only partially activated, hand-edited peers have drifted from the on-disk
config, and roaming laptops behind NAT are awkward to reach.

Headscale (self-hosted Tailscale control server) is the candidate replacement
for the **fleet transport**: a dynamic, self-healing WireGuard mesh with a
single authoritative registry (no hand-edited peers), automatic NAT traversal
(hole-punching + DERP relay fallback), and location-independent addressing.

AmneziaWG stays in the picture for a different job: obfuscated,
censorship-resistant VPN access for relatives in Russia. That is not something
Headscale/WireGuard can do (RU DPI fingerprints vanilla WireGuard). So the end
state is a **split**: Headscale for our own fleet, AmneziaWG for the relatives.

Before committing the whole fleet to that split, this probe validates the real
unknowns — NAT type per ISP, NAT-to-NAT hole-punching, same-LAN direct paths,
DERP fallback through our own relay, and RustDesk-over-tailnet — on two real
machines.

## Goal

Stand up Headscale + self-hosted embedded DERP on the VPS, enroll **latitude**
(NixOS) and **homeserver / g15** (Windows), and run a validation checklist that
answers whether Headscale is trustworthy as the fleet transport. Nothing
load-bearing is torn down.

## Decisions

- **Domain:** `cc.cyphy.kz`, fronted by the existing Caddy on the VPS.
- **DERP:** embedded in Headscale. Fall back to a standalone `derper` only if
  the embedded relay misbehaves.
- **AWG on latitude:** turned **off first**. Its `awg0` spoke carries nothing
  load-bearing (latitude's roles are dev/desktop/backup-client, and backups go
  over LAN, not the mesh), and we execute the probe while sitting on latitude,
  so there is no remote-lockout risk. Turning it off lets Tailscale be tested on
  the raw ISP network with no split-tunnel interference.
- **AWG on the homeserver:** **kept running.** The homeserver's AWG tunnel is
  `10.0.0.2` — the path Caddy uses to reach every public service. Dropping it
  would take down immich, navidrome, forgejo, emby, jellyfin, qb. Tailscale is
  installed *alongside* it; the two coexist cleanly (`100.64.0.0/10` vs
  `10.0.0.0/24`, split-tunnel), so services stay up and the probe still
  exercises NAT-to-NAT, LAN-direct, and RustDesk.
- **Relatives' AmneziaWG hub on the VPS:** untouched.
- **Auth:** pre-auth keys minted on the VPS (`headscale preauthkeys create`).
  SQLite DB. No OIDC.
- **Execution:** interactive, driven from latitude (SSH to the VPS from there).

## Architecture

```
                 Headscale control + embedded DERP (VPS, cc.cyphy.kz via Caddy)
                        ▲                         ▲
                   register                   register
                        │                         │
   latitude (NixOS, NAT) ◄───── tailnet ─────► homeserver (Windows, NAT)
   awg0 OFF                                    awg0 KEPT (services @ 10.0.0.2)

   VPS also joins its own tailnet as a test endpoint.
   Relatives ──► AmneziaWG hub on VPS (separate, untouched).
```

- Tailnet addressing: `100.64.0.0/10` (Tailscale default). Disjoint from the
  AmneziaWG `10.0.0.0/24`, so the two networks run side by side.
- Traffic path selection is automatic: direct LAN when co-located, direct P2P
  (hole-punched) across NATs, DERP relay over HTTPS/443 as fallback.

## Work, by repo

**`~/my/vps/vps/` (server side)**
- `setup-headscale.sh` — install Headscale, write config (SQLite, embedded DERP
  region, base domain `cc.cyphy.kz`), install + enable a systemd unit. Sits next
  to `setup-awg.sh`, same idempotent-script pattern.
- Headscale config template (committed; secrets/keys never committed).
- Caddyfile block for `cc.cyphy.kz` → Headscale (reverse proxy; the block must
  also carry the embedded-DERP endpoint — verify current Headscale docs for the
  exact reverse-proxy requirements at implementation time).
- VPS joins its own tailnet as a node (test endpoint).

**`~/my/machines/` (client side)**
- Disable `fleet.meshVpn` on latitude and add a minimal Tailscale enablement
  (`services.tailscale.enable = true;`), then `switch`.
- The `awg0` bring-down is handled by the switch + an explicit interface-down
  step in the runbook.
- Homeserver joins manually: install the Tailscale Windows client, `tailscale up
  --login-server=https://cc.cyphy.kz --authkey=<preauth>`. No declarative
  Windows provisioning in this increment.

## Validation checklist (the point of the probe)

Run from latitude and the homeserver:

1. `headscale nodes list` shows latitude, homeserver, and the VPS.
2. `tailscale netcheck` on latitude and homeserver — **record the NAT type per
   ISP** (answers the open question that governs how often we ride direct P2P
   vs. DERP).
3. latitude ↔ VPS: ping the tailnet IP; `ssh` over the tailnet.
4. **NAT-to-NAT:** with latitude and homeserver on different networks,
   `tailscale ping` reports `direct` (hole-punch succeeded).
5. **LAN-direct:** with latitude and homeserver on the same home WiFi,
   `tailscale ping` shows the direct LAN path, not a relay.
6. **Forced DERP:** force relay and confirm traffic flows through *our* embedded
   DERP (looks like HTTPS) — validates the worst-case path we intend to rely on.
7. **RustDesk:** Direct IP Access to the homeserver's `100.x` works remotely,
   and resolves to the LAN path when co-located.

Probe is "passed" when 1–3 and 6 work and 4/5/7 are observed at least once.

## Out of scope (later increments)

- Dropping AWG on the homeserver / migrating the Caddy service path onto the
  tailnet.
- Full-fleet rollout (g614jv, and declarative Windows Tailscale provisioning).
- Wiring skep's fleetd registry to consume the Headscale netmap.
- ACL policy / access hardening (default open mesh for the probe).

## Risks / notes

- **Homeserver outage risk** is avoided by *not* touching its AWG tunnel; the
  one thing to double-check during execution is that enabling Tailscale on
  Windows does not alter the routing table for `10.0.0.0/24`.
- **KZ/DPI** is not exercised by this probe unless a node is on a censored
  network at test time; the embedded-DERP-over-443 path is the best-effort
  answer, but AmneziaWG-grade obfuscation is explicitly not a Headscale feature.
- **Headscale config specifics evolve**; verify embedded-DERP + Caddy
  reverse-proxy config against current Headscale docs at implementation time
  rather than from memory.
