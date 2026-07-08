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
layer. The executor does **not** generate keys locally — the VPS hub is the key
authority (its `manage-peers.sh` already runs `awg genkey`, assigns the IP, and
emits the client conf). The member executor SSHes to the VPS, fetches its own
conf, and installs it. Phase 5 also makes `fleet.json` the single name-keyed
source of truth for mesh IPs (Nix derives from it) and removes the retired
NixOS `g16`.

Phase 5 spans **two repos**: a small prerequisite change in `~/my/vps`
(non-interactive `manage-peers.sh`), then the executors in this repo.

**Phasing (two plans).** This spec is implemented in two independently-landable
plans:
- **Phase 5a — Nix single-source-of-truth refactor** (fully session-verifiable):
  `fleet.json` as the mesh-IP source of truth via `mesh-vpn-params.nix`
  `fromJSON` derivation; the `modules/home/ssh.nix` generator (with the
  hub-hostname rule); the new `fleet.json` `ssh.user`/`mesh.peerName` fields;
  and the `g16` removal. Verified with `nix eval` / dry-build.
- **Phase 5b — mesh conf-fetch executors** (real-box-verifiable): the `~/my/vps`
  non-interactive prerequisite, the shared VPS conf-fetch helper, the
  `mesh-member`/`mesh-hub` executors, and dispatch wiring.

Sections below are labelled 5a/5b where the split matters.

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
- **The VPS is the key authority (confirmed from the real script).**
  `~/my/vps/vps/manage-peers.sh` is `add <name>` / `show <name>` / `list` /
  `remove <name>`. `add` runs `awg genkey` **on the VPS**, suggests/validates
  the mesh IP, stores the private key at `peers/<name>.key`, appends the peer to
  `/etc/amnezia/amneziawg/wg0.conf`, applies it live (`awg set wg0 …`), and
  prints the **complete client conf** (private key included). `show` re-emits a
  stored peer's conf. It is interactive (`read -rp` for the IP) and refuses
  duplicate names. It does **not** accept an externally-generated pubkey.
- **VPS peer names differ from fleet keys.** The live peer table names are e.g.
  `me-g614jv` (`.6`), `nix-lat5520` (`.8`), homeserver (`.2`). These are the
  `# <name>` comments `manage-peers.sh` keys on — not the `fleet.json` machine
  keys — so the manifest carries an explicit `mesh.peerName`.
- **The ROG G16 is now Windows-only.** The NixOS `g16` install is gone;
  `g614jv` (Windows) is the live representation of that laptop and owns mesh
  `.6`. The old "g16/g614jv share `.6`" collision is moot — one machine, one OS.
  The `g16` entries in `fleet.json`, `hosts/g16/nixos/`, and
  `mesh-vpn-params.nix` are stale and get removed here.
- **Mesh-IP drift:** the mesh IP is duplicated in two places that have already
  diverged — `fleet.json`'s per-machine `mesh.ip`, and `mesh-vpn-params.nix`'s
  hand-maintained `hosts` map (missing `g614jv`/`vps`, still listing dead
  `g16`). Phase 5 collapses these to one source.

## Scope decisions (from brainstorm)

1. **Real client provisioning + NixOS verifier**, not a thin status checker. The
   agenix secrets framework is a *separate later phase*; Phase 5 does not depend
   on it (the private key comes from the VPS over SSH, lands out-of-git).
2. **VPS is the key authority; the member fetches its conf** — no client-side
   keygen (so the GUI-only Windows boxes need **no** extra binary).
3. **Fetch is idempotent and non-rotating:** `show <name>` reuses a stored key;
   `add` only for a brand-new peer; a client that already has a conf/key is a
   no-op.
4. **Drive `manage-peers.sh` non-interactively** via a small prerequisite
   change in the `~/my/vps` repo (chosen over stdin-piping the interactive
   prompt).
5. **`fleet.json` is the single name-keyed source of truth for mesh IPs**; Nix
   derives its `hosts` map from it. Names are the stable handle; IPs are data.
6. **Remove the retired NixOS `g16`** everywhere.

Non-goals: the VPS hub bring-up (`setup-awg.sh`, owned by `~/my/vps`); the
agenix/age secrets framework (later phase); runtime/DHCP-style IP
auto-assignment (AmneziaWG pins static `/32`s — "dynamic" here means
single-source, not auto-negotiated); host-key pinning (existing follow-up).

## Prerequisite: `~/my/vps` `manage-peers.sh` non-interactive mode

A small, backward-compatible change in the vps repo, landed and pulled onto the
VPS **before** the machines-side executors can drive it:

- `manage-peers.sh add <name> <ip>` — when `<ip>` is given as `$3`, skip the
  interactive prompt (still validate the IP and refuse duplicate name/IP).
- A quiet/parseable output mode (flag or env, e.g. `--conf-only`) honored by
  both `add` and `show`: emit **only** the raw client conf (`[Interface]…`) to
  stdout, suppressing the QR block and `=== … ===` headers, so the caller can
  capture stdout directly.
- Existing interactive behavior unchanged when args/flag are absent.

This makes `manage-peers.sh` a fleet-provisioner **contract**; a pointer note is
left in the vps repo. (Its idempotency — refuse-duplicate on `add`, stable
`show` — is relied on here.)

## Per-platform executor behavior

| Platform | Role | Executor does |
|---|---|---|
| **NixOS** (`latitude5520`) | `mesh-member` | **Verifier + key fetch.** `switch` owns the `awg0`/sshd config. Executor: if `/etc/amnezia-wg/awg0.key` absent → SSH the VPS for this member's conf (`show <peerName>`, else `add`), extract `PrivateKey`, write it root-owned to `awg0.key`; check `awg show awg0` for a recent handshake; check the running kernel is the LTS build and print the reboot-into-`6.18.38` reminder if the module isn't loaded. No config mutation. |
| **Windows** (`g614jv`, `homeserver`) | `mesh-member` | **Conf fetch + verifier.** If `%ProgramData%\amnezia-wg\awg0.conf` absent → SSH the VPS for the conf, write it there; print AmneziaVPN import instructions; verify reachability (ping hub `10.0.0.1`). No keygen, no service install, no extra binary needed. |
| **Debian** (`vps`) | `mesh-hub` | **No-op pointer.** Print "hub is owned by `~/my/vps` (`setup-awg.sh`/`manage-peers.sh`)" and exit 0. |

### VPS conf-fetch (shared helper)

`provision/lib/mesh.sh` + `Mesh.psm1` (or folded into the existing `fleet`
libs), called by both executors:

- **Idempotency first:** if the client already has its key/conf, do nothing —
  no SSH, no VPS churn, no rotation.
- **Otherwise SSH to the VPS public endpoint** (`debian@cyphy.kz`, from
  `params.endpoint` + the `vps` machine's `ssh.user`), **not** the mesh (avoids
  the chicken-and-egg where the mesh is what's being brought up). The remote
  `manage-peers.sh` path is a manifest/param, overridable.
- **Fetch order:** `show <peerName> --conf-only` (existing peer → reuse stored
  key, **no rotation**); on "not found", `add <peerName> <mesh-ip> --conf-only`
  (new peer). `<mesh-ip>` comes from `fleet.json` by name (so we pass the known
  fleet-member IP rather than let the script auto-suggest).
- **Add-only on the hub:** the member only ever creates/reads **its own** peer.
  It never removes/rewrites other peers — the live `wg0` carries friends'
  peers.
- **Graceful degradation:** if SSH fails (no route/creds, VPS down), do **not**
  hard-fail the provision run — warn and print the exact
  `manage-peers.sh show/add …` line to run on the VPS by hand.
- **Secret handling:** the fetched conf contains the private key (transits
  VPS→client over SSH — encrypted, and matches the existing QR/printed-conf
  model). It is written to an out-of-git path and **never echoed**; dry-run
  prints a key-redacted preview only.
- **Dry-run:** print "would ssh `<target>` → `manage-peers.sh show/add
  <peerName> [ip]`" and the target install path; mutate nothing local or
  remote.

### Install paths

- **NixOS:** extract `PrivateKey` from the fetched conf → `/etc/amnezia-wg/awg0.key`
  (root-owned, `chmod 600`). The rest of the tunnel is already declared by
  `mesh-vpn.nix` (obfuscation/peer/endpoint match `awg.env`/params).
- **Windows:** write the whole conf to `C:\ProgramData\amnezia-wg\awg0.conf`
  (off-repo → no repo `.gitignore` churn), for AmneziaVPN GUI import. Per the
  `.dotfiles` convention, the runbook notes adding that path to the box's
  `.dotfiles` branch `.gitignore` as the "regenerate on a fresh box" marker.

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
  **generates** one block per mesh member (all of them — incl. Windows members
  like homeserver — not just NixOS hosts), with per-host `User` from a new
  optional `ssh.user` field in `fleet.json` (default `me`; `methe` for
  homeserver, `debian` for vps). `ssh <name>` keeps working; g16 vanishes for
  free. (Windows ssh_config name aliases: small addition / follow-up.)
- **Hub keeps its public hostname (do not regress).** The generator's
  `HostName` rule is: `mesh.role == "hub"` → `params.endpoint` (cyphy.kz);
  else → `mesh.ip`. This preserves the existing deliberate choice that the `vps`
  block points at the public domain, *not* `10.0.0.1`, so managing the VPS never
  depends on the tunnel it hosts. A naive "hostname = mesh.ip for every member"
  generator would silently regress this — the rule must key on `mesh.role`.
- **New `fleet.json` fields:** optional `ssh.user` (per above) and
  `mesh.peerName` (the VPS-side `# <name>`; defaults to the machine key, set
  explicitly for existing peers: `g614jv`→`me-g614jv`, `latitude5520`→
  `nix-lat5520`, homeserver→confirmed via `manage-peers.sh list`).
- **Bound on "dynamic":** AmneziaWG pins each peer to a static `/32`, so an IP
  is not auto-negotiated at runtime. The win is single-source: change a box's IP
  in `fleet.json` once → conf `Address`, SSH aliases, and the VPS fetch all use
  it. Name stable, IP a one-line change.

## Files

vps repo (`~/my/vps`, prerequisite commit):
- `vps/manage-peers.sh` — non-interactive `add <name> <ip>` + `--conf-only`
  quiet output; behavior otherwise unchanged.

This repo — new:
- `provision/roles/mesh-member.sh` — posix executor (nixos verifier + key
  fetch; wsl branch minimal). Defines `role_mesh_member`.
- `provision/roles/mesh-member.ps1` — Windows executor (conf fetch + verify).
  Defines `Invoke-RoleMeshMember`.
- `provision/roles/mesh-hub.sh` / `mesh-hub.ps1` — no-op pointer to `~/my/vps`.
- `provision/lib/mesh.sh` + `provision/lib/Mesh.psm1` — shared VPS conf-fetch
  (SSH `show`-then-`add`) + install + graceful fallback.

This repo — changed:
- `provision/provision.ps1` — two `$RoleExecutors` map entries
  (`mesh-member`, `mesh-hub`). `provision.sh` unchanged (generic dispatch).
- `fleet.json` — remove `g16`; add optional `ssh.user`
  (homeserver=`methe`, vps=`debian`) and `mesh.peerName` where it differs from
  the machine key.
- `modules/system/mesh-vpn-params.nix` — derive `hosts` from `fleet.json`; drop
  the hand-written map.
- `modules/home/ssh.nix` — generate `matchBlocks` from the derived members.
- `.claude/memory/project.md` — fix the stale "g16 = live NixOS member / shares
  `.6`" bullet.

This repo — removed:
- `hosts/g16/nixos/` and the `g16` machine entry.

## Verification

Session-testable:
- ps1/sh parse cleanly.
- Dry-run (temp install dir, VPS unreachable/faked): prints the "would ssh …
  show/add …" line + target path, writes no key/conf, opens no SSH. Idempotency:
  with a pre-existing conf present, the executor no-ops.
- Windows apply-confirm skips on `n` with rc=0. (GOTCHAs carried from Phase 2/4:
  the PowerShell tool runs `-NonInteractive`, so drive the confirm-gate smoke
  via Git Bash `echo n | pwsh -File …`, not the PowerShell tool; filter
  `Write-Host` plan lines with `*>&1`, not `2>&1`.)
- Nix: `nix eval` the derived `hosts` map from `fleet.json` and dry-build the
  latitude5520 toplevel — confirm the `fromJSON` derivation + generated
  `ssh.nix` blocks evaluate green and g16 is gone.
- vps: `manage-peers.sh add x 10.0.0.99 --conf-only` on a scratch/VPS-like host
  emits only a valid conf and stays interactive without args.

Runbook (real-box, cross-repo):
- **First:** land the `~/my/vps` `manage-peers.sh` change and `git pull` it on
  the VPS. (The vps repo is not cloned on g614jv — do this from a box that has
  it, or on the VPS.)
- On a member with no key yet (`--apply`/`-Apply`, answer `y`): confirm the
  executor SSHed `debian@cyphy.kz`, fetched the conf, installed it; `awg show`
  on the VPS lists the peer; `ssh <name>` connects over the mesh.
- `latitude5520`: fetch/confirm `/etc/amnezia-wg/awg0.key`, **reboot into
  `6.18.38`**, then `awg show awg0` shows a handshake and the verifier is green.
- Windows (`g614jv`/`homeserver`): import the fetched `awg0.conf` into
  AmneziaVPN, enable, confirm `ping 10.0.0.1` and `ssh homeserver`/`ssh g614jv`.
  These boxes already have a hand-made AmneziaVPN tunnel whose key may differ
  from what `show` returns — the fetched conf must **replace** that tunnel, not
  run alongside it (two tunnels for one peer/IP will fight).

## Open risks / notes

- **Cross-repo ordering:** the vps `manage-peers.sh` change gates the
  machines-side apply. The plan sequences it first; session tests that don't hit
  a real VPS still pass without it.
- **Existing static peers:** homeserver's `.2` may be a statically baked peer
  with no `peers/<name>.key` on the VPS → `show` fails and `add` errors ("IP in
  use"). Handle via the manual fallback + a runbook note; confirm the peer name
  with `manage-peers.sh list` first.
- **Remote path/user:** `debian@cyphy.kz` must be able to `sudo bash
  <path>/manage-peers.sh`; the plan pins the checkout path + sudo invocation.
- The fetched conf carries the private key VPS→client over SSH; acceptable
  (encrypted, matches the existing model), but the key must never be logged.
