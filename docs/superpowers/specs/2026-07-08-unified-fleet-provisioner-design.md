# Unified fleet provisioner — design spec

> **Status:** design approved via brainstorming 2026-07-08; pending user review of
> this written spec, then → `writing-plans`.
> **Supersedes framing of:** `docs/superpowers/plans/2026-07-07-fleet-mesh-vpn-ssh.md`
> (that Runbook becomes Phase 0 / the drift-cleanup input, not the end state).

## 1. Goal & scope

A single **convergence-first front door** for the whole fleet: one entry point per
platform that **detects/selects** the host, **previews** every change (dry-run),
**applies** idempotently, and offers **restore-from-backup** as a mode. Re-runnable
forever to reconcile drift. Fresh bring-up is just "converge from empty."

**Scope ceiling — machine layer only:** OS settings, mesh/VPN, SSH, dotfiles, repo
layout, backups. **Out of scope:** application/service deployment (Immich, Caddy,
Navidrome, Forgejo, RustDesk server) — those stay the `~/my/vps` repo's job, running
*on top of* a machine this tool provisioned. Backups of their *data* are in scope.

## 2. Core model — one role-based fleet

- **There is one fleet.** Every machine the user owns is a member.
- **A machine = an identity + a set of roles.** Roles compose what gets provisioned.
- **"VPS" is not a category — it's a role** a machine earns by having a public IP
  (→ runs the mesh hub, terminates Caddy). The VPS drifted precisely *because* it was
  treated as special and hand-edited; here it's just a role-bearing member.
- **Identity is per-OS-install, not per-physical-box.** The ASUS ROG G16 laptop is up
  to three machines — `g16` (NixOS), `g614jv` (Windows), a WSL distro — provisioned
  independently, never booted at once.

## 3. Architecture — compose, don't build

We are **not** building a config-management engine (that would be reinventing
Ansible/chezmoi). Terraform/Pulumi are the wrong category — they provision *cloud
resources via provider APIs*, not the inside of already-owned heterogeneous machines.
Instead, **compose mature engines + write only a thin dispatcher.**

| Layer | Engine (buy) | Build |
|---|---|---|
| NixOS hosts | NixOS + home-manager (nixos-unified pattern) | role→module mapping in the flake |
| Dotfiles / baseline / drift (non-Nix) | **chezmoi** | — |
| Secrets | **age** — via chezmoi (non-Nix) + **agenix** (NixOS) | age recipients wiring |
| Backup / restore | **restic / resticprofile** (already deployed) | restore-mode glue |
| Windows-only bits | (none clean) | idempotent steps: OpenSSH.Server, AmneziaWG, dev-mode |
| **The front door** | — | **thin dispatcher over `fleet.json`** |

The dispatcher is the only substantial new code: on the order of a couple hundred
lines, not a framework.

## 4. State & ownership model

Two engines own dotfiles, split by platform — philosophically consistent:

- **NixOS boxes → home-manager** is the dotfiles engine. Declarative, **drift-free**;
  a reproducible box *should* be rigid. No chezmoi here (running it over
  home-manager-managed paths = double ownership = conflict; `.ssh/config` via
  `ssh.nix`, `CLAUDE.md` via `claude.nix` are already home-manager-owned).
- **Non-Nix boxes (2× Windows, WSL) → chezmoi.** Cross-platform, templated, drift-
  tolerant baseline.

**chezmoi divergence model = intentional (chosen over ambient).** chezmoi tracks
*desired* state (the source), unlike the retired `~/.dotfiles` bare repo which tracked
*live* `$HOME`. `chezmoi apply` overwrites local drift with the source default (that's
how a bumped default re-aligns the fleet). To **keep** a per-machine variation you
**promote** it to source as machine-specific / templated (`chezmoi re-add`, templates,
`.chezmoiignore`) — divergence is declared, not ambient. `chezmoi diff` = the dry-run.
The bare `~/.dotfiles` repo is **retired** (only ever held 4 files across `main` +
`latitude5520` branches — nothing meaningful to migrate).

**Secrets (reverses the old "never in git" convention):** age-encrypted secrets live
in-repo, decrypted on apply — **chezmoi's age** on non-Nix boxes, **agenix** (also age)
on NixOS. **Per-host age keys (decided 2026-07-08):** each machine generates its own age
identity on first provision; only the *public* recipients are committed (like
`mesh-authorized-keys`), and each secret is encrypted to just the hosts that need it —
matching the fleet's existing "SSH keys are per-host, not shared" convention and
containing blast radius. `agenix` is a **new dependency** (the repo's first secrets
framework), introduced deliberately here.

## 5. The manifest — `fleet.json`

One committed file, the single source of truth for "who exists and what they are."
**JSON, not TOML:** on a fresh Windows box only PowerShell is guaranteed — it has
native `ConvertFrom-Json` but no TOML parser; Nix has `builtins.fromJSON`; bash has
`jq`. No bootstrap dependency, read natively by every consumer.

```jsonc
{
  "machines": {
    "latitude5520": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.8", "role": "member" },
      "roles": ["base","mesh-member","ssh-server","dev","desktop","laptop","agents","dotfiles","repos","backup-client"],
      "detect": { "hostname": "latitude5520" }
    },
    "g614jv": {                              // ASUS ROG G16, Windows side
      "platform": "windows",
      "mesh": { "ip": "10.0.0.6", "role": "member" },
      "roles": ["base","mesh-member","ssh-server","agents","dotfiles","repos"],
      "detect": { "hostname": "g614jv" }
    },
    "vps": {
      "platform": "debian",                  // DECIDED: stays Debian/Ubuntu (imperative role steps)
      "mesh": { "ip": "10.0.0.1", "role": "hub" },
      "roles": ["base","mesh-hub","ssh-server","agents","dotfiles","backup-client"],
      "detect": { "hostname": "cyphy" }
    }
  }
}
```

**Identity & selection:** the dispatcher auto-detects via `detect.hostname`, then an
**interactive confirm/select** ("You look like `g614jv` — provision as this? / pick
another / register new"). An unknown fresh box drops into "register new machine" →
writes a manifest entry.

## 6. Role catalog + per-platform executors

Each role = one purpose, a per-platform executor, a dry-runnable plan.

| Role | Purpose | nixos | windows | wsl |
|---|---|---|---|---|
| `base` | OS base settings | `base.nix` | dev-mode, git, shells | apt base |
| `mesh-member` | AmneziaWG spoke + ssh-over-mesh client | `mesh-vpn.nix` | AmneziaWG + ssh cfg | via host |
| `mesh-hub` | public-IP hub: wg0 server, peer forwarding, `manage-peers` | hub module | — | — |
| `ssh-server` | sshd on mesh+LAN | `openssh` | `OpenSSH.Server` step | — |
| `agents` | synced Claude/Codex config | `agents/bootstrap.sh` (all) | | |
| `dotfiles` | home-manager (nixos) / chezmoi (non-Nix) | home-manager | chezmoi | chezmoi |
| `repos` | repo-layout clone | `repos.sh` (all) | | |
| `backup-client` / `backup-hub` | restic spoke / REST+drives | resticprofile | | |
| `dev` / `desktop` / `laptop` | toolchain / GNOME / power | nixos modules | winget/apt where meaningful | |

**Roles resolve differently per platform (load-bearing):**
- **NixOS:** a role *is* a module. Converge = assemble the host's role-modules → **one
  `nixos-rebuild switch`**. Dry-run = `nix build --dry-run` + `nvd`/`nix store
  diff-closures` preview.
- **Windows / WSL:** a role is an **idempotent, individually dry-runnable step**
  (refactored `windows.ps1` / `linux.sh` functions, or `chezmoi apply`). Converge =
  run each role's step in dependency order; dry-run = each reports "would change X."

Presentation is uniform (per-role plan/diff) even though the engine differs.

## 7. NixOS single-source-of-truth (chosen: manifest generates imports)

The flake **reads `fleet.json`** (`builtins.fromJSON`) and, per host, maps each role
name → its module path → the host's `imports`. Host role membership is encoded **once**
(in the manifest); `hosts/<h>/configuration.nix` no longer hand-lists role modules, so
manifest and NixOS config **cannot silently disagree**. This is the higher-effort
option, chosen deliberately because eliminating exactly this kind of two-place drift is
the point of the project. A small `role → module` table lives in the flake; per-host
knobs (e.g. `mesh.address`) come from the manifest entry.

## 8. The dispatcher (the only real build)

- **Per-platform thin launchers**, sharing manifest + concepts + UX: `just provision`
  (NixOS), `provision.ps1` (Windows), `provision.sh` (WSL). Each is a bootstrap-safe
  native entry point (no python/TOML prerequisite).
- **Converge loop (uniform):** detect host → resolve roles from `fleet.json` → for each
  role: **plan (dry-run diff) → confirm → apply idempotently**. `--dry-run` stops after
  plan. Interactive select uses fzf where available (as `repos.sh` already does).
- **Restore mode:** `provision --restore` → restic restore of the machine's data +
  re-converge config (home-manager/chezmoi rebuild the declarative surface; restic
  brings back data + anything out-of-store).

## 9. Drift cleanup (the origin of this work) — perishable recon facts

Reconnaissance on the live VPS (2026-07-08) that must survive this transcript:

- **Live `awg show` ≠ on-disk `/etc/wireguard/wg0.conf`.** The running `wg0` was
  hand-edited away from its own config file: the file lists peers (`Stas .11`, `Dell
  latitude5520 windows .21`, `iphone ipheoryt .22`, homeserver key `/ba5KKQP…`) that
  are **not** in the live interface; the live interface has different peers/IPs. This
  is the concrete drift that justified the redesign.
- **Real non-secret AmneziaWG params** (from `awg show` + `awg.env`, safe to commit):
  `vpsPublicKey = Hm4m5Cce1RdzpbcOezzliDBxV4ZY2tp9mIMWXNivY1s=`, `port = 64531`,
  obfuscation `Jc=4 Jmin=40 Jmax=70 S1=71 S2=64 H1=4170542315 H2=917531710
  H3=2420372300 H4=330186316`. `mesh-vpn-params.nix` currently holds **placeholders**
  for all of these.
- **Peer → IP → key map** (`peers/*.key` → pubkey → `awg show` IP):
  - `.6` = `me-g614jv` (this Windows box, via the AmneziaVPN app) — up.
  - `.8` = **`nix-lat5520`** = latitude5520's **NixOS** side — already meshed
    (handshaked ~1h before recon). **latitude5520's real mesh IP is `.8`, NOT the `.7`
    the old plan guessed.**
  - `.7` = **`ilya-romanyuk` (a friend's device)** — the old plan's `.7` placeholder
    for latitude5520 would have **collided** onto someone else's peer.
  - Others (`.2` homeserver, `.4` taisia, `.5` nikita, `.9` ilya-laptop, `.3` ipheoryt)
    — the mesh also carries friends' devices; **do not disturb existing peers.**
- **VPS repo (`/home/debian/vps`) does not contain the old Group A commits** — the
  interactive `manage-peers.sh` / committed hairpin were never deployed there. Live
  `FORWARD` policy is already `ACCEPT`, so peer-to-peer already forwards (the hairpin
  rule is optional hardening, not a prerequisite).

**Reconcile:** the `mesh-hub` role becomes the source of truth for the VPS's wg
config; `mesh-vpn-params.nix` gets the real values above; latitude5520's
`mesh.address` corrected to `.8`. Existing friend peers are preserved.

## 10. Phasing

- **Phase 0 (now, stopgap — user opted in):** get cross-machine SSH working on current
  infra without waiting for the full build. Repo-side (doable this session): fill
  `mesh-vpn-params.nix` with the real §9 values, correct latitude5520 → `.8`. On-box
  (needs the user to drive each box): place existing keys, `switch` / run `windows.ps1`
  for `ssh-server`. Some glue is throwaway — folded into roles later.
- **Phase 1:** `fleet.json` + dispatcher skeleton (detect/select, plan/apply loop,
  per-platform launchers).
- **Phase 2:** chezmoi adoption on non-Nix boxes; retire `~/.dotfiles` bare repo.
- **Phase 3:** flake reads `fleet.json` → generates NixOS imports (§7).
- **Phase 4:** mesh role reconcile + VPS drift fix (§9); age/agenix secrets.
- **Phase 5:** backup/restore mode.

## 11. Risks & open questions

- **VPS platform — DECIDED (2026-07-08): stays Debian/Ubuntu.** The manifest carries it
  as `platform: debian`; its roles (`base`, `mesh-hub`, `ssh-server`, …) resolve to
  imperative bash executors (the `~/my/vps` repo's existing `setup-awg.sh` /
  `manage-peers.sh` patterns), not nixos modules. No NixOS migration. This makes
  `debian` a fourth platform the dispatcher/role-catalog must handle (alongside nixos /
  windows / wsl).
- **agenix — DECIDED (2026-07-08): per-host age keys.** Each host owns its identity;
  commit only public recipients; encrypt each secret to the hosts that need it. agenix
  is still a new dependency to wire (Phase 4).
- **NixOS import generation** (§7) is the highest-implementation-risk piece; prototype
  it early in Phase 1/3.
- **Windows AmneziaWG as a declarative-ish role:** the app is GUI-oriented; the
  `mesh-member` Windows executor may need the CLI/service form, not the app.
