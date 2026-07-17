# Fleet SSH for a disposable WSL node (`provision/ssh-wsl.sh`) — design

Date: 2026-07-17
Status: approved
Topic: give a WSL2 distro its own sshd + a fleet identity key + client config so
it can `ssh <fleet-host>` and be reached back, while staying disposable
(`wsl --unregister` safe). Companion to `tailscale-wsl.sh` (tailnet) and
`orca-serve.sh` (Orca runtime).

## Goal

A WSL distro on the tailnet should be a first-class SSH participant without
becoming a `fleet.json` member: it runs its own sshd (so agents/humans reach it
over the tailnet), holds a stable fleet identity key trusted by the other boxes,
and has a client config so `ssh latitude` / `ssh server` / `ssh hub` Just Work
from inside the distro. All of it re-established by one idempotent provisioning
script, and durable across a `wsl --unregister` rebuild.

## Model — leaf node, not a fleet member

The distro is a **leaf**: it reaches out to the fleet and is trusted by it, but
is **not** added to `fleet.json`. Rationale:

- Keeps the change additive — no `fleet.json` edit, no `modules/home/ssh.nix`
  generator change, no touching `mesh-vpn-params.nix`.
- Sidesteps the identity collision: the distro's OS hostname is `g614jv`, the
  **same** as the `desktop` Windows host's `detect.hostname` — a `fleet.json`
  member would make `fleet_detect` ambiguous.
- Matches the disposable ethos of the WSL box (README: "`wsl --unregister` and
  re-provision in minutes").

Consequence: other boxes are **not** auto-configured to `ssh wsl` (they'd reach
it by tailnet node name / IP ad hoc). Accepted — the requirement is outbound
`ssh` from the distro + inbound trust, not symmetric fleet membership.

## Deliverable — `provision/ssh-wsl.sh`

Standalone, run **after** `tailscale-wsl.sh` (it depends on the tailnet being up
and MagicDNS resolving). Mirrors sibling conventions: `info/ok/warn/die/have`
helpers, `set -u`, **idempotent** / safe to re-run, best-effort where a failure
shouldn't abort. A `SSH_WSL_LIB_ONLY=1` guard (same pattern as
`tailscale-wsl.sh`'s `TS_WSL_LIB_ONLY`) lets `ssh-wsl.test.sh` source the pure
helpers without running `main`.

### Preconditions

Debian/Ubuntu + x86_64; systemd present (probe as `tailscale-wsl.sh` does — the
sshd unit needs it); `sudo` (non-root). `jq` present (installed by `linux.sh`'s
CORE apt base) — `die` with a clear pointer to `linux.sh` if absent, since the
client-config generation reads `fleet.json` with it. Warn (not fail) if not
under WSL.

### 1. sshd (server)

- `apt-get install -y openssh-server` (idempotent; also runs `ssh-keygen -A` to
  create host keys).
- Install a drop-in `/etc/ssh/sshd_config.d/10-fleet.conf`:
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no` — key-only.
  No lockout risk: the WSL console (`wsl -d <distro>`) is always available
  independent of sshd.
- `sudo systemctl enable --now ssh`; restart if the drop-in changed. Default
  bind `0.0.0.0:22` is reachable over the tailnet as-is (no `netsh`/portproxy).
- Verify: `systemctl is-active ssh` and a listener on `:22`.

### 2. Fleet identity key, persisted on the Windows host

- Dedicated key `~/.ssh/id_fleet` (+ `.pub`), ed25519, comment
  `me@<sanitized $WSL_DISTRO_NAME>-wsl`. Deliberately **separate** from
  `linux.sh`'s per-GitHub-account keys (`id_metheoryt`, `id_cyphy671`) and the
  box's ambiguous existing `id_ed25519` — no fighting over the default identity.
- **Persistence store** `FLEET_KEY_DIR`, default
  `/mnt/c/Users/<winuser>/.fleet` — `<winuser>` auto-detected as the single
  non-system directory under `/mnt/c/Users`, overridable via `FLEET_WIN_USER`;
  the whole path overridable via `FLEET_KEY_DIR`.
- Lifecycle (store is source of truth):
  - If `$FLEET_KEY_DIR/id_fleet` exists → **restore**: copy it (+ `.pub`) into
    `~/.ssh/` (mode `0600` / `0644`).
  - Else → **generate** `~/.ssh/id_fleet` (`ssh-keygen -t ed25519 -N ''`), then
    **copy both** to `$FLEET_KEY_DIR` (creating it). Future rebuilds restore it.
- So `wsl --unregister` + re-provision reuses the same key → its
  `mesh-authorized-keys` entry never goes stale.
- **Tradeoff (accepted):** `/mnt/c` is a 9p/drvfs mount where unix `0600` is not
  enforced (uid-mapped, Windows ACLs only). The persisted private key is thus
  protected by Windows ACLs on `C:\Users\<winuser>`, not unix perms. Documented,
  not mitigated further (YAGNI).

### 3. Trust outward — `mesh-authorized-keys`

- The repo clone is `MACHINES_REPO` (default `~/machines`). Append the
  `id_fleet.pub` line to `provision/mesh-authorized-keys` **iff** its key body
  isn't already present (match on the base64 body, ignoring the comment), with a
  comment identifying the box. Idempotent.
- The script **cannot** rebuild other machines, so propagation stays
  operator-driven (consistent with how the fleet already distributes keys):
  after appending, `warn` to **commit + push** `mesh-authorized-keys` and
  **re-provision** the other boxes (`nixos-rebuild switch` on NixOS,
  `windows.ps1` on Windows) so their `authorized_keys` pick it up. If already
  present → `ok "already trusted (mesh-authorized-keys)"`.
- With the persisted key + a committed entry, a rebuild `git pull`s the entry
  back and this step is a no-op — no trust churn.

### 4. Client config — merged fleet block in `~/.ssh/config`

- The distro already has a `~/.ssh/config` (linux.sh's GitHub host aliases). We
  **merge**, never clobber: a marked, replaceable block delimited by
  `# >>> fleet-ssh (managed by ssh-wsl.sh) >>>` … `# <<< fleet-ssh <<<`. Re-runs
  replace only the marked block (drop the old markers-to-markers span, append
  the freshly rendered one); everything outside the markers is untouched.
- One `Host <name>` block per `fleet.json` member (via `jq`), mirroring
  `modules/home/ssh.nix`:
  - `IdentityFile ~/.ssh/id_fleet`
  - `StrictHostKeyChecking accept-new` (TOFU-then-pin, safe on the private mesh)
  - `User <ssh.user>` **only** when the member's `ssh.user` (default `me`) ≠ `me`
    (so `server`/`desktop` → `methe`, `hub` → `debian`)
  - `HostName cyphy.kz` **only** for the hub (its SSH must not depend on the
    transport it hosts); members use bare names resolved by MagicDNS
    (`search gg.ez` is already active on the box).
- Result: `ssh latitude`, `ssh server`, `ssh hub` work from the distro. (The
  `desktop` block targets this distro's own Windows host — harmless, useful.)

## Components / interfaces

- **Pure helpers** (above the `SSH_WSL_LIB_ONLY` guard, unit-testable):
  - `ssh_wsl_render_config <fleet-json>` → the fleet block text (the `Host …`
    stanzas), given `fleet.json` content on stdin/arg. Deterministic; no IO.
  - `ssh_wsl_key_present <pubfile-body> <authkeys-file>` → 0/1 whether that key
    body already appears in the authorized-keys/`mesh-authorized-keys` file
    (comment-insensitive).
  - Reuse `ts_sanitize_hostname`? It lives in `tailscale-wsl.sh`; duplicate a
    tiny local sanitizer here rather than cross-source another script (keep the
    scripts independent, as they are today).
- **Impure main**: preconditions → sshd → key restore/generate+persist →
  mesh-authorized-keys append → config merge → verify + next-steps output.
- **Env knobs** (all defaulted): `FLEET_KEY_DIR`, `FLEET_WIN_USER`,
  `MACHINES_REPO`.

## Testing

- **Unit (`provision/ssh-wsl.test.sh`, sourced with `SSH_WSL_LIB_ONLY=1`):**
  `ssh_wsl_render_config` against a small fleet.json fixture → asserts the hub
  gets `HostName cyphy.kz`, a non-`me` member gets a `User` line, a `me` member
  gets none, and every block carries `IdentityFile`/`StrictHostKeyChecking`.
  `ssh_wsl_key_present` → present / absent / comment-differs-but-body-same.
- **shellcheck** clean (`nix run nixpkgs#shellcheck`); `bash -n` clean.
- **[WSL] on-box:** run after `tailscale-wsl.sh`; assert `systemctl is-active
  ssh`, a `:22` listener, `~/.ssh/id_fleet` exists and equals
  `$FLEET_KEY_DIR/id_fleet`, the fleet block is present in `~/.ssh/config` with
  the GitHub block intact, and `ssh -o BatchMode=yes latitude true` succeeds
  once latitude trusts the key. Simulate a rebuild: `rm ~/.ssh/id_fleet*` +
  re-run → key **restored** from the store (same pubkey), config/authorized
  entries unchanged.
- **[FLEET] propagation:** after committing `mesh-authorized-keys`, re-provision
  one box and confirm inbound `ssh` from the WSL distro works with `id_fleet`.

## Security / tradeoffs

- Persisted private key on `/mnt/c` (Windows ACLs, not unix `0600`) — accepted,
  §2.
- sshd is key-only (`PasswordAuthentication no`); the private tailnet is the
  network boundary. Inbound is reachable by any tailnet node (tailnet is
  default-open today; ACLs are a separate roadmap item, out of scope here).

## Out of scope (YAGNI)

- Adding the WSL box to `fleet.json` (leaf by choice) or auto-generating its
  block in other boxes' `ssh.nix`.
- Auto-rebuilding / auto-pushing to the other machines (operator-driven, as the
  fleet already works).
- A Windows-side companion; MagicDNS / `--accept-dns` setup (already on).
- Wiring into the `provision.sh` dispatcher (standalone, like its siblings).
