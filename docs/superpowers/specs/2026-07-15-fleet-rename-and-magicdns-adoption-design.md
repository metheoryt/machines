# Fleet rename to consistent names + MagicDNS adoption

_Design — 2026-07-15_

## Problem

Two things drifted out of alignment as the fleet's transport migrated from
AmneziaWG to Headscale/Tailscale:

1. **Inconsistent, legacy machine names.** Each box carries a different, often
   accidental name depending on where you look: the SSH alias / `fleet.json`
   key (`latitude5520`, `homeserver`, `g614jv`, `vps`), the Headscale
   given-name (`latitude`, `homeserver`, `g614jv`, `cyphy-hub`), and the OS
   hostname (`latitude5520`, `methe-server`, `g614jv`, `27608`). The names you
   type daily (`ssh homeserver`, `server.fleet.mesh`) don't agree with each
   other and read like hardware SKUs, not roles.

2. **Redundant name-resolution machinery.** The 2026-07-14 SSH-over-tailnet
   work built a whole hosts-file layer — `modules/system/fleet-hosts.nix` (NixOS
   `networking.hosts`) plus a cross-platform `hosts` provisioner role
   (`provision/roles/hosts.{sh,ps1}`) writing a managed block into each box's
   system hosts file — on the premise that *"MagicDNS requires `--accept-dns`,
   which isn't set."* That premise was **stale**: MagicDNS is already live
   tailnet-wide (Headscale `magic_dns: true` + `override_local_dns: true`;
   `accept-dns` ON), verified on this box — `homeserver.fleet.mesh` **and** bare
   `homeserver` both resolve to `100.64.0.3`. So the hosts-file layer is
   redundant, and its claimed offline-fallback value is illusory (no tailnet =
   no `100.64.0.0/10` route = name resolution is moot regardless).

This design gives every machine **one consistent, role-suggesting name**
everywhere you type or read it, and **adopts MagicDNS as the fleet resolver**,
retiring the redundant hosts machinery.

## Goals

- Each machine has a single coherent fleet name: `hub` (vps), `latitude`
  (latitude5520), `desktop` (g614jv), `server` (homeserver). The iOS phone
  (`ipheoryt12`) is untouched.
- The name is consistent across the three places you interact with it: the
  Headscale **given-name** (→ MagicDNS `<name>.<suffix>`), the `fleet.json`
  **key** (→ generated `ssh <name>` alias), and the machines-repo **labels**
  (flake attr, `hosts/<name>/` dir).
- **MagicDNS is the fleet resolver.** Names resolve tailnet-wide via Headscale,
  not a hand-maintained hosts file.
- `fleet.json` stays the single source of truth for fleet addressing.
- The still-live AmneziaWG mesh (VPS hub for relatives + friends) is **not
  disturbed**.

## Non-goals / out of scope

- **OS hostnames are NOT renamed.** `networking.hostName` (latitude) and the
  Windows/Debian OS hostnames stay `latitude5520` / `methe-server` / `g614jv` /
  `27608`. Renaming them would drift the per-host SSH key labels
  (`me-nixos-latitude5520`), the AWG `peerName`s (`nix-lat5520`,
  `wg0-homeserver`, `me-g614jv`), and every provisioner `detect.hostname` match
  — a much larger, riskier blast radius for no daily-use benefit. The scope is
  *given-names + repo labels*, per the 2026-07-14 brainstorm.
- **No AWG param / IP changes.** `mesh.ip`, `mesh.peerName`, and the AWG
  constants in `mesh-vpn-params.nix` stay untouched.
- **The AWG Nix module is not ripped out.** `fleet.meshVpn` is dormant on
  latitude (`enable = false`) but its removal is a separate roadmap item.
- **`base_domain` value is already chosen** (`gg.ez`, committed to the vps repo
  as `c0fe069`); this design deploys it, it does not re-decide it.

## Reversal of a prior decision

The 2026-07-14 spec explicitly **rejected MagicDNS** and chose raw tailnet IPs
+ a hosts file. That decision was made believing `accept-dns` was unset and
MagicDNS a live-interference risk. Live verification on 2026-07-15 disproved
both premises (MagicDNS is on and working fleet-wide with no interference). This
design **reverses** that call: adopt MagicDNS, retire the hosts layer.

## Key facts (verified live, 2026-07-15)

- **Headscale given-names (live):** `cyphy-hub`(node 1), `latitude`(2 — already
  renamed), `homeserver`(3), `g614jv`(4), `ipheoryt12`(5). Renames still needed:
  **1→`hub`, 3→`server`, 4→`desktop`**; node 2 already matches target.
- **MagicDNS suffix is still `fleet.mesh`** live — the `gg.ez` rename is
  committed to the vps repo but **not deployed** (drift).
- **`mesh-vpn.nix` never indexes `fleet.json` by key** — it reads only
  value-level constants (`obfuscation`, `vpsPublicKey`, `endpoint`, `port`).
  Therefore renaming `fleet.json` keys is **AWG-safe** (the derived
  `params.hosts` name→IP map has no remaining consumer that indexes it by name).
- **`just switch` builds `.#$(hostname)`** — the `justfile` sets its `hostname`
  variable by shelling out to the `hostname` command, so the recipes target
  `.#<OS-hostname>`. So the NixOS flake attr is currently coupled to the OS
  hostname — renaming the
  attr requires decoupling this (see Decisions).
- **Only latitude (the sole NixOS box) has OS-layer coupling.** Windows/Debian
  boxes rename cleanly: `fleet.json` key → generated `ssh` alias only;
  `detect.hostname` and OS-hostname-keyed host-memory (`methe-server.md`,
  `g614jv.md`) are untouched.

## Design

Three independent layers of work. Layer 1 is auth-free and local; Layers 2–3
touch the VPS / live tailnet and each box.

### Layer 1 — machines-repo rename (auth-free, local)

Rename the **fleet-label** identifiers to the target names, keeping every
**OS-identity** identifier as-is.

Rename (per box):

| fleet.json key | → | flake attr / `hosts/<dir>/` | `detect.hostname` (KEEP) | OS hostName (KEEP) |
|---|---|---|---|---|
| `vps` | `hub` | (n/a — not a NixOS box) | `27608` | `27608` |
| `latitude5520` | `latitude` | `latitude` | `latitude5520` | `latitude5520` |
| `g614jv` | `desktop` | (n/a) | `g614jv` | `g614jv` |
| `homeserver` | `server` | (n/a) | `methe-server` | `methe-server` |

Concrete edits:

- **`fleet.json`:** rename the four top-level `machines` keys. Keep each
  `detect.hostname`, `mesh.*` (incl. `peerName`), `tailnet.ip`, `ssh.*`
  verbatim. This alone re-points the generated SSH aliases → `ssh hub` /
  `ssh latitude` / `ssh desktop` / `ssh server`.
- **latitude only (full label rename — Option A, chosen):**
  - `git mv hosts/latitude5520 hosts/latitude`.
  - `flake.nix`: `mkHost "latitude5520"` → `mkHost "latitude"`;
    `nixosConfigurations.latitude5520` → `.latitude`;
    `homeConfigurations."me@latitude5520"` → `"me@latitude"`; the two `checks`
    (`nixos-latitude5520`, `home-latitude5520`) and their referenced attrs.
  - **Decouple `just switch` from the OS hostname:** latitude is the only NixOS
    box, and its OS hostname stays `latitude5520` while the flake attr becomes
    `latitude`, so `.#$(hostname)` would look up a missing attr. Introduce a
    dedicated `nixos_attr := "latitude"` justfile variable and use it in the
    `build` / `switch` / `test` / `boot` / `build-vm` recipes instead of
    `{{hostname}}`. (The existing shell-derived `hostname` variable stays for any
    OS-hostname use.) A future second NixOS box turns this into a hostname→attr
    map.
  - **Host-memory file:** `git mv agents/hosts/latitude5520.md
    agents/hosts/latitude.md`, and set the `hostname` specialArg to `"latitude"`
    in both binding sites (`flake.nix` `mkHost`/`mkHome` already thread the attr
    name; `hosts/latitude/nixos/configuration.nix` line ~123
    `home-manager.extraSpecialArgs.hostname = "latitude5520"` → `"latitude"`).
    `claude.nix`/`codex.nix` link `${agents}/hosts/${hostname}.md`, so the file
    name and the specialArg must move together.
  - **`networking.hostName` stays `"latitude5520"`** in
    `hosts/latitude/nixos/configuration.nix` (OS identity, out of scope).
- **Windows/Debian boxes:** no repo file beyond `fleet.json` needs editing — the
  provisioner detects them by `detect.hostname` (unchanged) and their
  host-memory links off the live OS hostname (unchanged).

Acceptance (local, NixOS eval, on latitude): `nix flake check` passes with the
renamed attrs; `nix eval .#nixosConfigurations.latitude.config.system.build.toplevel`
resolves; generated `ssh` aliases render as `hub`/`latitude`/`desktop`/`server`
with the hub keeping `cyphy.kz`.

### Layer 2 — VPS / Headscale (needs prod SSH auth)

Auto-mode blocks prod SSH writes; these run via the user's `!`-prefixed shell or
with explicit authorization. Read-only `headscale` commands are already allowed.

1. **Deploy `gg.ez` base_domain (resolves the drift).** On the VPS: pull the vps
   repo (`c0fe069`), `cp vps/headscale/config.yaml /etc/headscale/config.yaml`,
   `systemctl restart headscale` (or re-run `setup-headscale.sh`). Guard with a
   rollback: keep the prior `config.yaml`; if `headscale` fails to start or nodes
   stop resolving, restore and restart. (`gg.ez` chosen because `.ez` isn't a
   real TLD — no public-DNS collision — while bare `gg` was rejected by
   Headscale and `.gg` is a real ccTLD.)
2. **Rename given-names to targets:** `headscale nodes rename hub -i 1`;
   `headscale nodes rename server -i 3`; `headscale nodes rename desktop -i 4`.
   (Node 2 already `latitude`; node 5 is the phone — leave both.)

Acceptance: `headscale nodes list` shows `hub/latitude/desktop/server` +
`ipheoryt12`; from a joined box, `<name>.gg.ez` and bare `<name>` resolve to the
right `100.64.0.x`.

### Layer 3 — MagicDNS-adoption cleanup (folds Layers 1–2 into a clean end-state)

With MagicDNS the resolver and names consistent, retire the redundant layer:

- **Retire the hosts machinery:** delete `modules/system/fleet-hosts.nix` and
  its import in `hosts/latitude/nixos/configuration.nix`; delete
  `provision/roles/hosts.{sh,ps1}`; remove the `hosts` role from every machine's
  `roles` in `fleet.json`; and hand-delete the `# BEGIN/END fleet hosts` managed
  block already written to this box's `C:\Windows\System32\drivers\etc\hosts`
  (the `hosts` role has no remove mode). Other Windows boxes that never had the
  block applied need nothing.
- **Pin `--accept-dns` declaratively on latitude.** MagicDNS resolution depends
  on it; today it's imperative. Set it via `services.tailscale.extraUpFlags` (or
  a `tailscale set --accept-dns` one-shot) in the latitude config so a rebuild
  can't silently drop DNS. (UNVERIFIED on latitude — confirm the flag takes on
  this home-manager/tailscale version during apply.)
- **Slim `modules/home/ssh.nix`.** MagicDNS now supplies names, so the generated
  per-box `HostName` blocks are largely redundant — but keep what MagicDNS
  cannot: (a) the **hub's public address** (`cyphy.kz`, so managing the hub never
  depends on the transport it hosts), and (b) non-default `User`s (MagicDNS gives
  names, not usernames). Reduce `ssh.nix` to those two concerns rather than a
  full per-box `HostName` table.

Acceptance: on latitude after `switch`, `ping server` / `getaddrinfo server`
resolve via MagicDNS (not a hosts file); `ssh hub` reaches `cyphy.kz`;
`ssh server`/`ssh desktop`/`ssh latitude` reach the right boxes;
`provision` no longer lists a `hosts` role.

## Sequencing & risk

- **Layer 1 is independent of Layers 2–3** (`ssh.nix` uses raw `tailnet.ip`, so
  aliases don't depend on the MagicDNS suffix). It can land and be merged on its
  own, auth-free.
- Layer 2's `gg.ez` deploy and given-name renames need prod auth and are done on
  the VPS; they don't touch the machines repo.
- Layer 3 depends on Layer 2 (don't retire hosts-fallback until MagicDNS is
  confirmed the resolver end-to-end) and on Layer 1 (the retired
  `fleet-hosts.nix` import lives in the renamed `hosts/latitude/` dir).
- **Before deploying `gg.ez` or renaming given-names, grep BOTH repos for
  hardcoded `fleet.mesh` and for old names used as resolvable hostnames**
  (Caddyfile upstreams, service configs). The 2026-07-13 rollout believes Caddy
  upstreams use raw `100.64.0.x` IPs — confirm rather than trust.

## Verification summary

- Layer 1: `nix flake check` green on latitude; `ssh` aliases render to targets;
  key rename provably AWG-safe (mesh-vpn.nix reads no keys).
- Layer 2: `headscale nodes list` shows the four targets; `<name>.gg.ez` resolves
  from a joined box; rollback path exercised mentally (keep prior config.yaml).
- Layer 3: name resolution survives with `fleet-hosts.nix` + the hosts block
  gone; `--accept-dns` persists across a latitude rebuild.
