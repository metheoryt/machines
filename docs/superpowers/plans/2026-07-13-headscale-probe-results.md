# Headscale fleet-mesh probe — results

**Date:** 2026-07-13
**Verdict:** ✅ PASS — proceed to fleet-wide rollout (with eyes open on the CGNAT/DERP finding below)
**Spec:** `docs/superpowers/specs/2026-07-13-headscale-fleet-mesh-probe-design.md`
**Plan:** `docs/superpowers/plans/2026-07-13-headscale-fleet-mesh-probe.md`

## What is live

- **VPS:** Headscale 0.29.2 + embedded DERP (region 999, STUN 3478), served at
  `https://cc.cyphy.kz` behind Caddy (Let's Encrypt cert issued). `derp.urls: []`
  → all relayed traffic rides our own DERP. SQLite DB. User `fleet` (id 1),
  reusable pre-auth key.
- **Tailnet nodes:** `vps-test` `100.64.0.1`, `latitude` `100.64.0.2`,
  `homeserver` `100.64.0.3` — all online.
- **AmneziaWG untouched:** relatives' hub still running; homeserver's `10.0.0.2`
  service tunnel unchanged (services reachable throughout). latitude's `awg0`
  spoke disabled (raw ISP networking).

## Validation matrix

| # | Validation | Result |
|---|-----------|--------|
| 1 | All nodes registered/online | ✅ vps-test, latitude, homeserver |
| 2 | NAT type per ISP | ⚠️ latitude (hotspot) **and** homeserver share public IP `37.99.47.9` → same **carrier-grade NAT (CGNAT)**; UDP works, no UPnP/PMP (`PortMapping` empty) |
| 3 | latitude ↔ VPS SSH over tailnet | ✅ `ssh debian@100.64.0.1` landed on the VPS |
| 4 | NAT-to-NAT hole-punch (different networks) | ❌ **did NOT reach direct** — 8/8 pongs stayed `via DERP(headscale)`. Hole-punch fails behind the shared CGNAT. |
| 5 | LAN-direct (same WiFi) | ✅ homeserver↔latitude direct via `192.168.8.x`, **3ms**, not relayed |
| 6 | Relay through **our** DERP | ✅ full cross-network session relayed via embedded DERP at 14–24ms; latitude↔vps first pong also `via DERP(headscale)` |
| 7 | RustDesk over tailnet (Direct IP → `100.64.0.3`) | ✅ works both on-LAN and cross-network |

"Pass" bar (spec: items 1–3 & 6 work; 4/5/7 observed) — met.

## Key finding: CGNAT forces cross-network traffic onto DERP

The most important result. When two fleet machines are on **different** networks
behind this ISP's CGNAT, Tailscale **cannot** hole-punch a direct tunnel — it
falls back to relaying through our embedded DERP. Implications:

- **Not a regression.** Today ~all fleet traffic already transits the VPS; DERP
  relay is the same shape, now automatic, encrypted-looking (HTTPS/443), and
  self-healing.
- **The "direct P2P saves VPS bandwidth" upside does not materialize** for
  cross-network fleet traffic on this carrier. Plan VPS bandwidth accordingly;
  bulk transfers (e.g. RustDesk screen streaming) over DERP are usable but not
  snappy.
- **LAN-direct is excellent** (3ms) whenever machines are co-located.
- **DERP reliability is the payoff** — the path that "just works" behind hostile
  NAT, which is exactly why we bet on it.

## Improvement leads (post-probe, not blocking rollout)

1. **Get direct-to-homeserver from anywhere:** the homeserver is a fixed
   location but `netcheck` shows no port mapping. Enable **UPnP/PCP** on the home
   router (or forward Tailscale's UDP port to the homeserver) → roaming machines
   could reach it **directly** instead of via DERP. Highest-value next step.
2. **Watch VPS DERP bandwidth** once more machines relay through it.
3. Consider ACLs before rollout widens (default-open mesh today).

## Go / no-go

**GO for fleet-wide rollout.** Headscale is a solid replacement for the fleet
transport: control plane is reliable, enrollment is trivial, LAN-direct is fast,
SSH + RustDesk over the tailnet work, and DERP fallback through our own relay is
dependable even in the worst (CGNAT) case. AmneziaWG stays the obfuscated VPN for
the RU relatives. Next increments (per spec "out of scope"): roll out to
`g614jv`, declarative Windows Tailscale provisioning, migrate the homeserver's
Caddy service path onto the tailnet (then retire its AWG), wire skep's registry
to the netmap, and the UPnP improvement above.

## Rollback (if ever needed)

- latitude: flip `fleet.meshVpn.enable` → `true`, remove `services.tailscale`,
  `tailscale down`, rebuild.
- homeserver: `tailscale down` / uninstall; AWG tunnel was never touched.
- VPS: `systemctl disable --now headscale`; remove `cc.cyphy.kz` Caddy block +
  reload; `tailscale down`. AmneziaWG hub untouched throughout.

## Incidental (not caused by the probe)

- Homeserver's AWG service tunnel had gone **stale** (43-min-old handshake, 100%
  loss) *before* any probe change — restarted by the operator, restoring
  services. This flakiness is precisely what the mesh migration aims to end.
- immich_server had stopped and navidrome was intentionally down during the
  session; both operator-handled, unrelated to Headscale.
