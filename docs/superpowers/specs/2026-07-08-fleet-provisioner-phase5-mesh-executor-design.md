# Phase 5 — `mesh-member` / `mesh-hub` role executor — design

Date: 2026-07-08
Status: approved (brainstorm), pending spec review
Predecessors: Phase 1 (manifest+dispatcher), Phase 2 (agents), Phase 3
(dotfiles), Phase 4 (repos). Parent design:
`docs/superpowers/specs/2026-07-08-unified-fleet-provisioner-design.md`.
Supersedes the client-side scope of
`docs/superpowers/specs/2026-07-07-fleet-mesh-vpn-ssh-design.md`.

## Summary

Phase 5 adds the fleet's `mesh-member` and `mesh-hub` role executors — the
front-door path that brings a machine onto the AmneziaWG mesh — following the
Phase 2+ role→executor pattern (per-platform executor, `DRY_RUN`-capable,
confirm-gated, dispatched by the generic `role_<name>` machinery).

Unlike `agents`/`dotfiles`/`repos` (uniform wraps of one host-agnostic script),
the mesh role is **heterogeneous**: each platform's mesh sits at a different
layer, so each executor branch does a different thing. It also (a) generates
per-host AmneziaWG keys instead of asking for them, (b) auto-registers the
derived public key on the VPS hub over SSH, (c) makes `fleet.json` the single
name-keyed source of truth for mesh IPs (Nix derives from it), and (d) removes
the now-retired NixOS `g16`.

## Context / current state

- **NixOS members** (`latitude5520`, mesh `.8`): `modules/system/mesh-vpn.nix`
  already declares `awg0` + sshd; `switch` applies it. The only imperative gaps
  are (1) placing the out-of-store private key `/etc/amnezia-wg/awg0.key`, and
  (2) rebooting into the LTS kernel `6.18.38` so the out-of-tree AmneziaWG
  module loads (latitude5520 is sitting on exactly this gap right now).
- **Windows members** (`g614jv` mesh `.6`, `homeserver` mesh `.2`): **no**
  codified AmneziaWG client provisioning exists — `provision/windows.ps1` only
  *warns* the tunnel must be up. AmneziaWG runs via the AmneziaVPN **GUI** (no
  scriptable service/CLI on these boxes).
- **Debian hub** (`vps`, mesh `.1`): the hub side (`setup-awg.sh`,
  `manage-peers.sh`) is owned by the sibling `~/my/vps` repo, not this repo.
- **The ROG G16 is now Windows-only.** The NixOS `g16` install is gone;
  `g614jv` (Windows) is the live representation of that laptop and owns mesh
  `.6`. The old "g16/g614jv share `.6`" collision is therefore moot — there is
  one machine, one OS. The `g16` entries in `fleet.json`, `hosts/g16/nixos/`,
  and `mesh-vpn-params.nix` are stale and get removed here.
- **Mesh-IP drift:** the mesh IP is currently duplicated in two places that
  have already diverged — `fleet.json`'s per-machine `mesh.ip`, and
  `mesh-vpn-params.nix`'s hand-maintained `hosts` map (missing `g614jv` and
  `vps`, still listing dead `g16`). Phase 5 collapses these to one source.

## Scope decisions (from brainstorm)

1. **Real Windows client (manual-key convention) + NixOS verifier**, not a
   full auto-everything and not a thin status-only checker. Real bring-up needs
   a private key; the agenix secrets framework is a *separate later phase*, so
   Phase 5 uses the same "key lives out-of-git, placed once" convention NixOS
   already uses — no dependency on the secrets phase.
2. **Windows = conf generator + verifier**, not a service installer. The boxes
   are GUI-only, so the executor renders an `awg0.conf` for AmneziaVPN import
   and verifies reachability; it does not install a tunnel service.
3. **Generate keys, don't ask** — idempotently (never rotate an existing key).
4. **Auto-register the pubkey on the VPS over SSH**, add-only, with graceful
   fallback to a printed command.
5. **`fleet.json` is the single name-keyed source of truth for mesh IPs**; Nix
   derives its `hosts` map from it. Names are the stable handle; IPs are data.
6. **Remove the retired NixOS `g16`** everywhere.

Non-goals: the VPS hub side (owned by `~/my/vps`); the agenix/age secrets
framework (later phase); runtime/DHCP-style IP auto-assignment (AmneziaWG pins
static `/32`s — "dynamic" here means single-source, not auto-negotiated);
host-key pinning (existing follow-up, unchanged).

## Per-platform executor behavior

| Platform | Role | Executor does |
|---|---|---|
| **NixOS** (`latitude5520`) | `mesh-member` | **Verifier + key-gap filler.** `switch` owns the `awg0`/sshd config. Executor: generate `/etc/amnezia-wg/awg0.key` iff absent (root, `wg genkey`) → if just generated, call the shared VPS-register helper; check `awg show awg0` for a recent handshake; check the running kernel is the LTS build and print the reboot-into-`6.18.38` reminder if the module isn't loaded. No config mutation. |
| **Windows** (`g614jv`, `homeserver`) | `mesh-member` | **Conf generator + verifier.** Generate the keypair iff `awg0.key` absent → register on VPS; render `awg0.conf` from shared constants + this box's `mesh.ip` (by name) + the private key to an off-repo path; print AmneziaVPN import instructions; verify reachability (ping hub `10.0.0.1`). No service install. |
| **Debian** (`vps`) | `mesh-hub` | **No-op pointer.** Print "hub is owned by `~/my/vps` (`setup-awg.sh`/`manage-peers.sh`)" and exit 0. |

### Key generation (shared)

- **Idempotent, never rotates.** Generate the private key **only if the key
  file is absent**; if present, reuse it. Rationale: `g614jv` (`.6`) and
  `homeserver` (`.2`) already have live peers on the VPS — regenerating would
  rotate the key and break the tunnel until the VPS is updated. Generation
  primarily serves fresh boxes; existing boxes keep their key.
- **Tooling:** NixOS/POSIX `wg genkey | wg pubkey` (wireguard/amneziawg-tools
  present). Windows: probe for `wg.exe`/`amneziawg.exe` in the AmneziaVPN
  install dir + `PATH`; if found → generate; if not found → **degrade** to
  emitting `awg0.conf.example` with `PrivateKey = <FILL_ME>` + a warning (never
  hard-fail).
- The private key is never echoed to the terminal in any mode.

### VPS auto-registration (shared helper)

A freshly generated public key means nothing until the hub knows it. The hub is
a different repo whose peer keys are deliberately uncommitted, so this repo
cannot self-register from source — it registers over SSH instead.

- **Path:** SSH to the VPS **public** endpoint (`debian@cyphy.kz`, from
  `params.endpoint` + the `vps` machine's `ssh.user`), **not** the mesh —
  avoids the chicken-and-egg where the mesh is what's being brought up. Target +
  `manage-peers.sh` path are overridable; defaults pinned in the plan.
- **When:** only when the executor **just generated a new key**. If the key
  already existed, the peer is assumed registered → no SSH, no VPS churn, no
  rotation. An explicit `--reregister` escape hatch forces it.
- **Add-only, never disturb:** registers only this box's own `(mesh-ip,
  pubkey)`. Never removes/rewrites other peers — the live `wg0` carries
  friends' peers. **Precondition on the vps side:** `manage-peers.sh` must be an
  idempotent add/upsert. This makes `manage-peers.sh` a fleet-provisioner
  contract; a pointer note is left for the `~/my/vps` repo.
- **Graceful degradation:** if the SSH fails (no route/creds, VPS down), do
  **not** hard-fail the provision run — warn and print the exact
  `manage-peers.sh <ip> <pubkey>` line to run by hand.
- **Dry-run:** print "would ssh `<target>` → `manage-peers.sh <ip> <pubkey>`";
  mutate nothing local or remote.

### Windows `awg0.conf` render

Off-repo paths (mirror the NixOS `/etc/amnezia-wg/awg0.key` convention so the
secret never touches git):

- Key: `C:\ProgramData\amnezia-wg\awg0.key`
- Conf: `C:\ProgramData\amnezia-wg\awg0.conf`

Rendered `[Interface]` (`Address` from the box's `mesh.ip`, looked up by name;
`MTU`/obfuscation/peer from the shared constants):

```ini
[Interface]
PrivateKey = <from awg0.key, never echoed>
Address = <mesh.ip>/32
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 71
S2 = 64
H1 = 4170542315
H2 = 917531710
H3 = 2420372300
H4 = 330186316

[Peer]
PublicKey = Hm4m5Cce1RdzpbcOezzliDBxV4ZY2tp9mIMWXNivY1s=
AllowedIPs = 10.0.0.0/24
Endpoint = cyphy.kz:64531
PersistentKeepalive = 25
```

Behavior: key present → write `awg0.conf`, print import instructions. Key
absent → write `awg0.conf.example` with a `<FILL_ME>` placeholder + warn; never
silently produce a broken tunnel. Dry-run → print target path + a key-redacted
preview; mutate nothing.

**Secret hygiene:** key + conf live in `%ProgramData%` (off-repo → no repo
`.gitignore` churn). Per the `.dotfiles` convention, the runbook notes adding
`awg0.key` to the box's `.dotfiles` branch `.gitignore` as the "regenerate on a
fresh box" marker.

## Names as the stable handle, IPs as data

- **Single source of truth = `fleet.json`.** Already name-keyed, read natively
  on Windows and from Nix via `builtins.fromJSON (builtins.readFile
  ../../fleet.json)`. Matches the unified-provisioner principle ("NixOS
  membership is generated from the manifest").
- **`mesh-vpn-params.nix`** drops its hand-written `hosts` map and **derives**
  name→`mesh.ip` from `fleet.json`; it keeps only the genuinely non-per-host
  constants (`vpsPublicKey`, `port`, `endpoint`, `obfuscation`). The drift and
  the dead `g16` line disappear structurally.
- **`modules/home/ssh.nix`** stops enumerating `matchBlocks` by hand and
  **generates** them from the derived members, with per-host `User` from a new
  optional `ssh.user` field in `fleet.json` (default `me`; `methe` for
  homeserver, `debian` for vps). `ssh <name>` keeps working; g16 vanishes for
  free. (Windows ssh_config name aliases: small addition / follow-up.)
- **Bound on "dynamic":** AmneziaWG pins each peer to a static `/32`, so an IP
  is not auto-negotiated at runtime. The win is single-source: change a box's IP
  in `fleet.json` once → conf `Address`, SSH aliases, and VPS registration all
  regenerate. Name stable, IP a one-line change.

## Files

New:
- `provision/roles/mesh-member.sh` — posix executor (nixos verifier; wsl/debian
  branch minimal). Defines `role_mesh_member`.
- `provision/roles/mesh-member.ps1` — Windows executor (conf gen + verify).
  Defines `Invoke-RoleMeshMember`.
- `provision/roles/mesh-hub.sh` / `mesh-hub.ps1` — no-op pointer to `~/my/vps`.
- `provision/lib/mesh.sh` + `provision/lib/Mesh.psm1` (or folded into the
  existing `fleet` libs) — shared keygen + `awg0.conf` render + VPS
  auto-register-with-fallback.

Changed:
- `provision/provision.ps1` — two `$RoleExecutors` map entries
  (`mesh-member`, `mesh-hub`). `provision.sh` unchanged (generic dispatch).
- `fleet.json` — remove `g16`; add optional `ssh.user` where it differs from
  the `me` default (`homeserver`=`methe`, `vps`=`debian`).
- `modules/system/mesh-vpn-params.nix` — derive `hosts` from `fleet.json`; drop
  the hand-written map.
- `modules/home/ssh.nix` — generate `matchBlocks` from the derived members.
- `.claude/memory/project.md` — fix the stale "g16 = live NixOS member / shares
  `.6`" bullet.

Removed:
- `hosts/g16/nixos/` and the `g16` machine entry.

## Verification

Session-testable:
- ps1/sh parse cleanly.
- Dry-run (temp `ProgramData`): renders a **key-redacted** conf preview, prints
  the "would generate keypair" / "would ssh … manage-peers.sh" lines, and
  mutates nothing (no key file, no conf, no SSH).
- Windows apply-confirm skips on `n` with rc=0. (GOTCHA carried from Phase 2/4:
  the PowerShell tool runs `-NonInteractive`, so drive the confirm-gate smoke
  via Git Bash `echo n | pwsh -File …`, not the PowerShell tool; and filter
  `Write-Host` plan lines with `*>&1`, not `2>&1`.)
- Nix: `nix eval` the derived `hosts` map from `fleet.json` and dry-build the
  latitude5520 toplevel — confirm the `fromJSON` derivation + generated
  `ssh.nix` blocks still evaluate green and g16 is gone.

Runbook (real-box, needs `git pull` first):
- On a box that generates a fresh key (`--apply`/`-Apply`, answer `y`): confirm
  the VPS peer appears (`awg show` on the VPS via `debian@cyphy.kz`) and
  `ssh <name>` connects over the mesh. Auto-SSH register needs `debian@cyphy.kz`
  reachable and `manage-peers.sh` present + idempotent.
- On `latitude5520`: place/confirm `/etc/amnezia-wg/awg0.key`, **reboot into
  `6.18.38`**, then `awg show awg0` shows a handshake and the verifier reports
  green.
- Windows (`g614jv`/`homeserver`): import the generated `awg0.conf` into
  AmneziaVPN, enable, confirm `ping 10.0.0.1` and `ssh homeserver`/`ssh g614jv`.

## Open risks / notes

- `wg`/`amneziawg` keygen tooling may be absent on the GUI-only Windows boxes;
  the degrade path (`awg0.conf.example`) covers it but then keygen is manual.
- The `debian@cyphy.kz` SSH user must be able to run `manage-peers.sh` (likely
  `sudo`); the plan pins the exact remote invocation.
- `manage-peers.sh` idempotency is a **precondition** owned by the `~/my/vps`
  repo; if it is not add/upsert-safe, auto-register could duplicate a peer. Verify
  before first real apply; leave the pointer note in the vps repo.
