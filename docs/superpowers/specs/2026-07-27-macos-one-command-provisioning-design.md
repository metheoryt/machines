# macOS one-command provisioning — design

**Goal:** clone `machines` on a fresh Mac, run one command, end up with a fully
enrolled fleet member — hostname set, on the tailnet, toolchain installed, agent
config linked, roles applied. No manual `scutil`, no manual Homebrew, no manual
`tailscale up`.

**Status:** approved 2026-07-27. Extends Task 4 of
`docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
and subsumes the manual steps that plan's Tasks 5–6 spell out by hand.

## Context

`provision/macos.sh` (commit `04c0309`) already installs the toolchain: it is a
**tier driver**, the Darwin sibling of `linux.sh`, sharing every tier body in
`provision/lib/tiers.sh`. What it does not do is the work that has to happen
*before* a tier can run — set the hostname, install Homebrew, join the tailnet —
or the role dispatch that happens after.

Those steps currently live as prose in the migration plan. Prose is how a fresh
Mac ends up half-provisioned.

The repo already solves this shape for WSL: `provision/provision-wsl.sh` is a
36-line chain that calls four existing scripts in order and contains no logic of
its own, exposed as `just provision-wsl <nickname>`. This design is its macOS
counterpart.

## Architecture

```
provision/
  macos-prep.sh      NEW  privileged prerequisites — one sudo prompt
  tailscale-mac.sh   NEW  tailnet enrollment (sibling of tailscale-wsl.sh)
  provision-mac.sh   NEW  the chain — pure orchestration
  macos.sh                UNCHANGED — still the pure tier driver
  provision.sh            UNCHANGED — still the role front door
```

`bash provision/provision-mac.sh air` runs four stages:

| # | Stage | Responsibility |
|---|---|---|
| 1 | `macos-prep.sh <machine>` | sudo prompt + keepalive; `scutil` hostname; Homebrew bootstrap; Remote Login |
| 2 | `tailscale-mac.sh --hostname <machine>` | install the cask; resolve the pre-auth key; `tailscale up`; verify the assigned IP against `fleet.json` |
| 3 | `macos.sh` | the 13 tiers (brew, agent config, gortex, fleet SSH, launchd agents…) |
| 4 | `provision.sh --machine <machine> --apply` | roles: `agents`, `dotfiles`, `repos` |

### Why `macos-prep.sh` is a separate file

Every privileged operation in the whole flow lives in it. "What does this ask
root for, and why" is answerable by reading one short script instead of auditing
a chain. It prompts for sudo once, up front, naming the three things it needs
root for, then holds the timestamp alive with a background `sudo -n true`
refresh so stages 2–4 never re-prompt.

Stage 3 (`macos.sh`) and stage 4 (`provision.sh`) require no root at all:
Homebrew refuses to run under sudo and owns its own prefix, and the role
executors write only inside `$HOME`.

### Why the machine name is an argument

Stage 1 *sets* the hostname, so hostname-based detection cannot work before it
runs — `fleet_detect` would have nothing to match. The name is therefore
positional: `provision-mac.sh air`.

It is validated against `fleet.json` before anything is touched: the machine
must exist and carry `platform: darwin`. A typo fails fast instead of renaming
the machine to something the manifest has never heard of.

## Component contracts

### `macos-prep.sh <machine>`

- **Consumes:** `fleet.json` (for `detect.hostname`), sudo.
- **Produces:** hostname set via `scutil` (`HostName`, `LocalHostName`,
  `ComputerName`), Homebrew present on `PATH`, Remote Login enabled.
- Homebrew: skipped when `brew` already resolves. Otherwise runs the official
  installer with `NONINTERACTIVE=1` (safe — the sudo timestamp is already warm),
  then `eval "$(/opt/homebrew/bin/brew shellenv)"` so the *current* process sees
  it. Handles the Intel prefix `/usr/local` too.
- Remote Login: `systemsetup -setremotelogin on`. **Non-fatal.** Recent macOS
  refuses this unless the invoking terminal holds Full Disk Access; on failure
  it warns with the exact System Settings path and continues, because inbound
  SSH is not required for any later stage.

### `tailscale-mac.sh [--hostname <name>] [--authkey-file <path>]`

Mirrors `tailscale-wsl.sh`'s interface and key precedence.

- **Pre-auth key precedence:** `--authkey-file` → `$HEADSCALE_AUTHKEY` → already
  logged in (skip). **There is deliberately no `--authkey` flag**: argv is
  world-readable through `ps`, so an inline key is scrapeable by any local
  process for the lifetime of the run. `tailscale-wsl.sh` omits it for the same
  reason. Keys belong in `provision/secrets/`, which is already gitignored.
- Installs the **standalone** cask (`brew install --cask tailscale-app`); the
  App Store build cannot set a custom control server.
- The CLI is not on `PATH` — it lives at
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. The script resolves it
  explicitly rather than assuming a shell alias.
- Joins with `--login-server https://cc.cyphy.kz`, then `--accept-dns=true`.
- **Verifies** `tailscale ip -4` against the machine's `tailnet.ip` in
  `fleet.json`. Mismatch is a **warning, not a failure** — reconciling it means
  editing Headscale or the manifest, neither of which re-running this script
  fixes. Silence here is the real danger: the address was already wrong once in
  this migration (`fleet.json` claimed `.5`; Headscale had assigned it to a
  phone).
- Idempotent: an already-joined node is detected and skipped.

### `provision-mac.sh <machine>`

Pure orchestration. Validates the machine against `fleet.json`, prints
`▸ N/4 …` per stage, dies on the first failure of stages 1–3, and passes
`--authkey-file` through to stage 2 when given. Contains no provisioning logic —
matching `provision-wsl.sh`, which is deliberately just a call sequence.

`--dry-run` prints the stage plan and exits without touching the system.

### `justfile`

```
provision-mac machine:
    bash provision/provision-mac.sh {{machine}}
```

## Error handling

| Condition | Behaviour |
|---|---|
| Machine absent from `fleet.json`, or not `platform: darwin` | die before any mutation |
| Not running on Darwin | die |
| sudo unobtainable | die — stage 1 cannot proceed |
| Homebrew install fails | die — every later tier depends on it |
| No pre-auth key and not already joined | die with the `headscale preauthkeys create` command to run on hub |
| Tailnet IP ≠ `fleet.json` | **warn**, continue |
| Remote Login refused by macOS | **warn** with the System Settings path, continue |
| Any tier or role fails | inherit existing behaviour — CORE tiers die, best-effort tiers warn |

## Testing

The privileged and macOS-only paths cannot execute on the NixOS box where this
repo is developed, so the split is:

- **`--dry-run` stage plan.** `provision-mac.sh --dry-run air` prints the four
  stages and exits 0, touching nothing. Mirrors `MACHINES_TIERS_DRY_RUN`, which
  is what makes `macos.sh`'s tier list assertable from a Linux box today.
- **`LIB_ONLY` guards.** `macos-prep.sh` and `tailscale-mac.sh` return early
  under `MACOS_PREP_LIB_ONLY=1` / `TAILSCALE_MAC_LIB_ONLY=1`, exposing their pure
  functions for direct test. This is the existing convention —
  `ssh-wsl.sh` (`SSH_WSL_LIB_ONLY`) and `tiers.sh` (`TIERS_LIB_ONLY`) both do it,
  and `tier_fleet_ssh` already depends on it.
- **`provision/tests/provision-mac.test.sh`** covers: machine validation
  (unknown name, non-darwin platform, valid), the dry-run stage plan, authkey
  precedence resolution, the brew-prefix selection for both architectures, and
  the IP-comparison helper (match, mismatch, absent).

Privileged calls are asserted as *plan output*, never executed.

## Out of scope

- Docker Desktop, the company VPN, and `tsh` — manual installs, unchanged from
  Task 6 Step 5 of the migration plan.
- Orca install and remote-environment pairing — Task 6 Step 8.
- Registering the generated SSH keys with GitHub — inherently interactive
  (`gh auth login`), already covered by Task 6 Step 1b.
- A macOS `hub` profile. The hub is a Debian VPS; `macos.sh` rejects any profile
  other than `workstation`.
