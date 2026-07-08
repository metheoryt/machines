# Phase 5b — mesh conf-fetch executors (`mesh-member` / `mesh-hub`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring a fleet member onto the AmneziaWG mesh by fetching its own client conf from the VPS hub (the key authority) over SSH and installing it — via per-platform `mesh-member` executors (NixOS = key-fetch + verifier, Windows = conf-fetch + verifier) plus a `mesh-hub` no-op pointer, following the Phase 2+ role→executor pattern; gated by a small non-interactive change to the sibling `~/my/vps` `manage-peers.sh`.

**Architecture:** Phase 5b spans **two repos**. First, a backward-compatible prerequisite in `~/my/vps`: `manage-peers.sh` gains a positional-IP `add <name> <ip>` and a `--conf-only` output flag (emit only the raw client conf on stdout) so a caller can drive it non-interactively. Then, in this repo, a shared conf-fetch helper (`provision/lib/mesh.sh` + `provision/lib/Mesh.psm1`) SSHes the hub — built as `user@host` explicitly from `fleet.json` (members never rely on the home-manager-generated `ssh vps` alias, which exists only on NixOS) — runs `show <peer> --conf-only` (idempotent, no rotation) and falls back to `add <peer> <ip> --conf-only` for a brand-new peer. The `mesh-member` executors install the result (NixOS: extract `PrivateKey` → root-owned `/etc/amnezia-wg/awg0.key`; Windows: write the whole conf → `C:\ProgramData\amnezia-wg\awg0.conf` for AmneziaVPN GUI import) and verify reachability. `mesh-hub` is a no-op pointer to `~/my/vps`. The posix dispatcher auto-discovers `role_<name>`; `provision.ps1` gains two `$RoleExecutors` map entries.

**Tech Stack:** bash (executors + lib, `jq` for manifest reads), PowerShell 7 (Windows executors + `Mesh.psm1`, native `ConvertFrom-Json`), OpenSSH client (`ssh.exe` on Windows), AmneziaWG (`awg`), `fleet.json` manifest.

## Global Constraints

- **`--conf-only` is an OUTPUT flag only — it never skips mutations.** In `--conf-only` mode `manage-peers.sh add` still runs `awg genkey`, stores `peers/<name>.key`, appends the `[Peer]` block to `wg0.conf`, and applies it live with `awg set wg0 …`; it only suppresses the QR block, the `=== … ===` headers, and the human status lines so **stdout is exactly the raw client conf** (`[Interface]…`). The peer must actually exist on the hub afterward. Same for `show` (which mutates nothing — it re-emits a stored peer's conf).
- **Never log or echo the private key.** The fetched conf contains a `PrivateKey`. It transits VPS→client over SSH (encrypted; matches the existing QR/printed-conf model) and is written to an out-of-git path (`/etc/amnezia-wg/awg0.key`, `C:\ProgramData\amnezia-wg\awg0.conf`). It is **never** printed to stdout/stderr by the executor, never put in a log line, never shown in dry-run. Dry-run prints a key-redacted plan only.
- **Add-only, self-only on the hub.** A member only ever `show`s / `add`s **its own** `peerName`. It NEVER runs `remove`, never rewrites `wg0.conf` wholesale, never touches another peer. The live `wg0` carries friends' peers (`.7` = `ilya-romanyuk`) — disturbing them is forbidden.
- **`show`-then-`add` order; `show` never rotates.** Fetch order is always `show <peer> --conf-only` first (existing peer → reuse the stored key, no rotation), and only on a not-found/failure fall back to `add <peer> <ip> --conf-only` (brand-new peer). Never `add` a peer that already exists.
- **Idempotent local no-op.** If the member already has its key/conf on disk (`awg0.key` on NixOS, `awg0.conf` on Windows), the executor does **nothing** — no SSH, no VPS churn, no rotation — in both dry-run and apply.
- **Graceful degradation — never hard-fail the run.** If SSH to the hub fails (no route, no creds, VPS down), the executor **warns** and prints the exact `manage-peers.sh show/add …` line to run by hand, then returns success (rc 0). A mesh hiccup must not abort the rest of a provision run.
- **Members build the hub SSH target explicitly from `fleet.json`** (`<hub ssh.user>@<hub ssh.host>` = `debian@cyphy.kz`), NOT the generated `ssh vps` alias (home-manager-only, absent on the Windows members). SSH the **public endpoint**, not the mesh IP — the mesh is what's being brought up (chicken-and-egg).
- **New `fleet.json` fields are additive and have no Nix consumer.** `vps.ssh.host` and `vps.mesh.managePeers` are read only by the shell/PowerShell executors. The Phase 5a Nix derivation (`mesh-vpn-params.nix` reads `mesh.ip`; `ssh.nix` reads `mesh.role`/`ssh.user`/`endpoint`) ignores them — **do not reopen the 5a-verified `ssh.nix`** to make the hub block use `ssh.host`; `endpoint` and `ssh.host` are conceptually distinct (AWG dial-endpoint vs SSH reach-host) and merely coincide as `cyphy.kz` today.
- **Windows = replace, not coexist.** `g614jv`/`homeserver` already have hand-made AmneziaVPN tunnels whose key may differ from what `show` returns. The fetched conf must **replace** the existing tunnel — two tunnels for one peer/IP fight. This is a runbook instruction to the human, not something the executor automates.
- **Cross-repo ordering:** Task 1 (the `~/my/vps` change) must land and be `git pull`ed onto the VPS **before** any real-box apply of the machines-side executors. Session/dry-run tests do not need a real VPS.

## Out of scope (do not do in 5b)

- **The VPS hub bring-up** (`setup-awg.sh`, `wg0.conf` authoring) — owned by `~/my/vps`; `mesh-hub` is only a pointer.
- **The agenix/age secrets framework** — a separate later phase. The private key comes from the VPS over SSH and lands out-of-git; 5b does not depend on agenix.
- **Windows `ssh <name>` host aliases** (an ssh_config generator for the Windows boxes) — a small follow-up; not required for the fetch (which builds `user@host` directly).
- **Host-key pinning** — existing follow-up; the fleet uses `accept-new` (TOFU) as set in 5a's `ssh.nix`.
- **Reopening `ssh.nix` or `mesh-vpn-params.nix`** — 5a is verified green; 5b adds only additive `fleet.json` fields with no Nix consumer.
- **A root-stubbed local test harness for `manage-peers.sh`** — the real `add … --conf-only` needs root + a live `awg`/`wg0` interface (even latitude5520 can't provide the hub interface). Session verification of Task 1 is `bash -n` + `shellcheck` only; the behavioral test is a VPS runbook step.

---

### Task 1: `~/my/vps` — non-interactive `manage-peers.sh` (`add <name> <ip>` + `--conf-only`)

**This task's working directory is the sibling repo `~/my/vps`, NOT this repo.** Edit, commit, and push there (its own origin). Everything else in this plan is in the `machines` repo.

**Files:**
- Modify: `~/my/vps/vps/manage-peers.sh`
- Modify: `~/my/vps/CLAUDE.md` (one-line pointer: the script is now a fleet-provisioner contract)

**Interfaces:**
- Consumes: nothing new.
- Produces the **contract** the machines-side helper relies on:
  - `manage-peers.sh add <name> <ip>` — when `<ip>` (`$3` after flag-stripping) is present, skip the interactive IP prompt; still validate the IP (`10.0.0.X`, `3≤X≤254`) and refuse a duplicate name or IP.
  - `manage-peers.sh add <name> <ip> --conf-only` / `manage-peers.sh show <name> --conf-only` — emit **only** the raw client conf (`[Interface]…[Peer]…`) to stdout; suppress the QR block, `=== … ===` headers, and status lines.
  - Flag position-independent (`--conf-only` may appear anywhere in the args).
  - Absent args/flag → existing interactive behavior byte-for-byte unchanged.

- [ ] **Step 1: Add position-independent flag parsing before the dispatch `case`**

In `~/my/vps/vps/manage-peers.sh`, replace the final dispatch block:

```bash
case "${1:-}" in
    add)    cmd_add    "${2:-}" ;;
    list)   cmd_list ;;
    show)   cmd_show   "${2:-}" ;;
    remove) cmd_remove "${2:-}" ;;
    *)      usage ;;
esac
```

with a version that strips `--conf-only` into a global and dispatches on the remaining positionals:

```bash
# Separate the --conf-only output flag (position-independent) from positional
# args, so callers can drive add/show non-interactively and capture the raw
# conf. CONF_ONLY is read by cmd_add / cmd_show. Default: interactive/verbose.
CONF_ONLY=0
args=()
for a in "$@"; do
    case "$a" in
        --conf-only) CONF_ONLY=1 ;;
        *)           args+=("$a") ;;
    esac
done

case "${args[0]:-}" in
    add)    cmd_add    "${args[1]:-}" "${args[2]:-}" ;;
    list)   cmd_list ;;
    show)   cmd_show   "${args[1]:-}" ;;
    remove) cmd_remove "${args[1]:-}" ;;
    *)      usage ;;
esac
```

Also add `--conf-only` to `usage()` so the interface is documented:

```bash
usage() {
    echo "Usage:"
    echo "  sudo bash manage-peers.sh add <name> [ip] [--conf-only]"
    echo "  sudo bash manage-peers.sh list"
    echo "  sudo bash manage-peers.sh show <name> [--conf-only]"
    echo "  sudo bash manage-peers.sh remove <name>"
    echo ""
    echo "  --conf-only  emit only the raw client conf on stdout (no QR, no headers)."
    exit 1
}
```

- [ ] **Step 2: Accept a positional IP in `cmd_add` (skip the prompt when given)**

Change the `cmd_add` signature and the IP-acquisition block. The name handling, duplicate-name check, IP validation, keypair generation, config append, and `awg set` all stay **unchanged**. Only (a) accept `$2` as `ip_arg`, and (b) use it instead of prompting when present:

```bash
cmd_add() {
    local name="${1:-}"
    local ip_arg="${2:-}"
    if [[ -z "$name" ]]; then
        read -rp "Peer name: " name
    fi
    if [[ -z "$name" ]]; then
        echo "Name required." >&2
        exit 1
    fi
```

Then, where the script currently prompts for the IP:

```bash
    # prompt for IP, Enter accepts the suggestion
    local peer_ip
    read -rp "IP [$suggested]: " peer_ip
    peer_ip="${peer_ip:-$suggested}"
```

replace with:

```bash
    # IP: use the positional arg when given (non-interactive), else prompt
    # (Enter accepts the suggestion). Validation below is identical either way.
    local peer_ip
    if [[ -n "$ip_arg" ]]; then
        peer_ip="$ip_arg"
    else
        read -rp "IP [$suggested]: " peer_ip
        peer_ip="${peer_ip:-$suggested}"
    fi
```

(The `suggested` next-free-IP computation above this block stays as-is — it is harmless when `ip_arg` is supplied and still powers the interactive prompt.)

- [ ] **Step 3: Guard `cmd_add` output on `CONF_ONLY`**

At the end of `cmd_add`, where it currently prints the status line, optional QR, and headered conf:

```bash
    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")

    echo "Peer '$name' added at $peer_ip"
    echo ""

    if command -v qrencode &>/dev/null; then
        echo "=== QR Code (scan with AmneziaWG app) ==="
        echo "$client_conf" | qrencode -t ansiutf8
        echo ""
    fi

    echo "=== Client config for '$name' ==="
    echo "$client_conf"
}
```

replace with a `CONF_ONLY` short-circuit (raw conf only) before the verbose path:

```bash
    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")

    if [[ "$CONF_ONLY" == 1 ]]; then
        printf '%s\n' "$client_conf"   # stdout = raw conf only
        return 0
    fi

    echo "Peer '$name' added at $peer_ip"
    echo ""

    if command -v qrencode &>/dev/null; then
        echo "=== QR Code (scan with AmneziaWG app) ==="
        echo "$client_conf" | qrencode -t ansiutf8
        echo ""
    fi

    echo "=== Client config for '$name' ==="
    echo "$client_conf"
}
```

- [ ] **Step 4: Guard `cmd_show` output on `CONF_ONLY`**

At the end of `cmd_show`, where it prints the optional QR and headered conf:

```bash
    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")

    if command -v qrencode &>/dev/null; then
        echo "=== QR Code (scan with AmneziaWG app) ==="
        echo "$client_conf" | qrencode -t ansiutf8
        echo ""
    fi

    echo "=== Client config for '$name' ==="
    echo "$client_conf"
}
```

replace with:

```bash
    local client_conf
    client_conf=$(render_client_conf "$peer_private_key" "$peer_ip")

    if [[ "$CONF_ONLY" == 1 ]]; then
        printf '%s\n' "$client_conf"   # stdout = raw conf only
        return 0
    fi

    if command -v qrencode &>/dev/null; then
        echo "=== QR Code (scan with AmneziaWG app) ==="
        echo "$client_conf" | qrencode -t ansiutf8
        echo ""
    fi

    echo "=== Client config for '$name' ==="
    echo "$client_conf"
}
```

- [ ] **Step 5: Leave a contract pointer in the vps repo's CLAUDE.md**

Append one bullet under an appropriate heading in `~/my/vps/CLAUDE.md` (e.g. near the AmneziaWG / `manage-peers.sh` description):

```markdown
- `manage-peers.sh` is a **fleet-provisioner contract**: the sibling `machines`
  repo's `mesh-member` executor drives it non-interactively over SSH —
  `add <name> <ip> --conf-only` / `show <name> --conf-only` emit only the raw
  client conf on stdout. Keep those two invocations stable (flag name, output =
  conf only, mutations unchanged); interactive behavior is unaffected.
```

- [ ] **Step 6: Gate — script parses and lints clean** (runs on this Windows box via Git Bash, or WSL)

Run:
```bash
cd ~/my/vps/vps
bash -n manage-peers.sh && echo "PARSE OK"
command -v shellcheck >/dev/null && shellcheck -S warning manage-peers.sh || echo "(shellcheck not installed — parse gate only)"
```
Expected: `PARSE OK`; shellcheck reports no new warnings vs. the pre-change baseline (the flag-parse loop and `CONF_ONLY` reads should be clean; pre-existing warnings, if any, are out of scope). The **behavioral** test (`add x 10.0.0.99 --conf-only` emits only a conf; no-arg stays interactive) requires root + a live `awg`/`wg0` and is the VPS runbook step below — do not attempt it in-session.

- [ ] **Step 7: Commit + push (in the vps repo)**

```bash
cd ~/my/vps
git add vps/manage-peers.sh CLAUDE.md
git commit -m "manage-peers: non-interactive add <name> <ip> + --conf-only output

Fleet-provisioner contract for the machines-repo mesh-member executor:
positional IP skips the prompt; --conf-only emits only the raw client conf
(QR/headers/status suppressed). add still genkeys+applies live; interactive
behavior unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push
```

---

### Task 2: `fleet.json` — add the hub's SSH reach + `manage-peers.sh` path

**Files:**
- Modify: `fleet.json` (machines repo)

**Interfaces:**
- Consumes: the existing `vps` machine record.
- Produces (read by Tasks 3 & 5): `machines.vps.ssh.host :: string` (public SSH host = `cyphy.kz`) and `machines.vps.mesh.managePeers :: string` (absolute path to `manage-peers.sh` on the VPS). Existing fields unchanged.

**⚠ The `mesh.managePeers` value is the one real-box unknown** — it is the checkout path of the `~/my/vps` repo *on the VPS*. This plan uses the value implied by the repo's namespace convention (clones live under `~/<owner>`; the VPS `ssh.user` is `debian`) → `/home/debian/my/vps/vps/manage-peers.sh`. The runbook's first real-box step confirms it with `ssh debian@cyphy.kz 'ls <path>'`; if it differs, this is a one-line `fleet.json` fix.

- [ ] **Step 1: Add `ssh.host` and `mesh.managePeers` to the `vps` record**

Edit only the `vps` machine block in `fleet.json` (leave the other three machines exactly as they are):

```json
    "vps": {
      "platform": "debian",
      "mesh": { "ip": "10.0.0.1", "role": "hub", "managePeers": "/home/debian/my/vps/vps/manage-peers.sh" },
      "ssh": { "user": "debian", "host": "cyphy.kz" },
      "roles": ["base", "mesh-hub", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
```

- [ ] **Step 2: Gate — valid JSON, hub reach fields present, other machines untouched** (Git Bash / WSL)

Run:
```bash
cd ~/machines   # Windows: cd /c/Users/methe/machines
jq -e '
  (.machines.vps.ssh.host == "cyphy.kz")
  and (.machines.vps.ssh.user == "debian")
  and (.machines.vps.mesh.managePeers | test("manage-peers\\.sh$"))
  and (.machines.vps.mesh.role == "hub")
  and (.machines | keys | sort == ["g614jv","homeserver","latitude5520","vps"])
  and (.machines.g614jv.mesh.peerName == "me-g614jv")          # 5a data intact
  and (.machines.latitude5520.mesh.peerName == "nix-lat5520")
' fleet.json && echo "GATE OK"
```
Expected: `true` then `GATE OK`.

- [ ] **Step 3: `[nix box]` Gate — 5a Nix derivation still green with the additive fields** (latitude5520, after `git pull`)

Run:
```bash
cd ~/machines
nix eval --json -f modules/system/mesh-vpn-params.nix hosts
# Expected UNCHANGED: {"g614jv":"10.0.0.6","homeserver":"10.0.0.2","latitude5520":"10.0.0.8","vps":"10.0.0.1"}
nix build --dry-run '.#nixosConfigurations.latitude5520.config.system.build.toplevel'
# Expected: clean dry-build (proves ssh.host/managePeers are ignored by the Nix side).
```
Expected: the `hosts` map is byte-identical to 5a's (the new fields have no Nix consumer); the dry-build is clean.

- [ ] **Step 4: Commit**

```bash
git add fleet.json
git commit -m "phase5b: fleet.json — add hub ssh.host + mesh.managePeers

Read by the mesh-member executors to build the VPS SSH target (debian@cyphy.kz)
and the remote manage-peers.sh path. Additive; no Nix consumer.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `provision/lib/mesh.sh` — shared VPS conf-fetch helper (posix)

**Files:**
- Create: `provision/lib/mesh.sh`
- Test: `provision/lib/mesh.test.sh` (a self-contained bash test with a stubbed `ssh` and a temp manifest)

**Interfaces:**
- Consumes (from Task 2): `fleet.json` hub record (`mesh.role=="hub"`, `ssh.user`, `ssh.host`, `mesh.managePeers`) and per-machine `mesh.peerName`/`mesh.ip`.
- Produces (sourced by Task 4's `mesh-member.sh`):
  - `mesh_hub_target :: () -> "<user>@<host>"`
  - `mesh_hub_script :: () -> "<abs path to manage-peers.sh>"`
  - `mesh_peer_name <machine> :: -> "<peerName or machine key>"`
  - `mesh_peer_ip <machine> :: -> "<mesh ip>"`
  - `mesh_ssh_fetch <machine> :: -> prints raw conf to stdout, rc 0; rc 1 on failure. Never logs the key.`
  - `mesh_manual_hint <machine> :: -> prints the by-hand show/add lines to STDERR`
  - `mesh_dryrun_line <machine> <install_path> :: -> prints the key-redacted would-ssh plan to STDOUT`
  - Honors `MESH_MANIFEST` (env override, default = repo-root `fleet.json`) and `MESH_SSH` (env override for the `ssh` binary, default `ssh`) so tests can inject a temp manifest and a stub.

- [ ] **Step 1: Write `provision/lib/mesh.sh`**

```bash
# provision/lib/mesh.sh — shared VPS conf-fetch helper (source me; do not execute).
# Sourced by provision/roles/mesh-member.sh. Requires: jq, ssh.
#
# The VPS hub is the AmneziaWG key authority (its ~/my/vps manage-peers.sh runs
# `awg genkey`, assigns the IP, stores the key, and emits the client conf). A
# member does NOT generate keys locally — it SSHes the hub's PUBLIC endpoint
# (never the mesh IP: the mesh is what's being brought up) and fetches its OWN
# peer conf: `show <peer> --conf-only` first (idempotent, no rotation), else
# `add <peer> <ip> --conf-only` (brand-new peer). Add-only, self-only: never
# remove/rewrite other peers — the live wg0 carries friends' peers.
#
# SECRET HANDLING: the fetched conf contains a PrivateKey. It is returned on
# stdout for the caller to install to an out-of-git path; it is NEVER logged,
# echoed, or shown in dry-run. Callers must not print it.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
# shellcheck shell=bash

# Manifest path: env override (tests) else repo-root fleet.json (lib/ -> repo).
MESH_MANIFEST="${MESH_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/fleet.json}"
# ssh binary: env override (tests inject a stub) else the real client.
MESH_SSH="${MESH_SSH:-ssh}"

# "<user>@<host>" for the hub (the single machine with mesh.role=="hub").
# host = ssh.host if set, else the mesh IP; user = ssh.user or "me".
mesh_hub_target() {
    jq -r '
        .machines | to_entries[] | select(.value.mesh.role == "hub") | .value
        | ((.ssh.user // "me") + "@" + (.ssh.host // .mesh.ip))
    ' "$MESH_MANIFEST"
}

# Absolute path to manage-peers.sh on the hub.
mesh_hub_script() {
    jq -r '
        .machines | to_entries[] | select(.value.mesh.role == "hub")
        | .value.mesh.managePeers // "/home/debian/my/vps/vps/manage-peers.sh"
    ' "$MESH_MANIFEST"
}

# VPS-side peer name for a machine (defaults to the machine key).
mesh_peer_name() {
    jq -r --arg m "$1" '.machines[$m].mesh.peerName // $m' "$MESH_MANIFEST"
}

# Mesh IP for a machine.
mesh_peer_ip() {
    jq -r --arg m "$1" '.machines[$m].mesh.ip' "$MESH_MANIFEST"
}

# Fetch this machine's client conf from the hub. Prints the raw conf to stdout
# on success (rc 0); rc 1 on any failure. Key is captured in a local var and
# never logged. `show` first (no rotation), then `add`.
mesh_ssh_fetch() {
    local machine="$1"
    local target peer ip script conf
    target="$(mesh_hub_target)"
    peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"
    script="$(mesh_hub_script)"

    # 1) existing peer — reuse the stored key (no rotation)
    if conf="$("$MESH_SSH" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
            "sudo bash '$script' show '$peer' --conf-only" 2>/dev/null)" \
        && printf '%s' "$conf" | grep -q '^\[Interface\]'; then
        printf '%s\n' "$conf"
        return 0
    fi

    # 2) not found — create a brand-new peer at its fleet IP
    if conf="$("$MESH_SSH" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
            "sudo bash '$script' add '$peer' '$ip' --conf-only" 2>/dev/null)" \
        && printf '%s' "$conf" | grep -q '^\[Interface\]'; then
        printf '%s\n' "$conf"
        return 0
    fi

    return 1
}

# Graceful-degradation hint (STDERR) — the exact by-hand lines to run on the VPS.
mesh_manual_hint() {
    local machine="$1" target peer ip script
    target="$(mesh_hub_target)"; peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"; script="$(mesh_hub_script)"
    {
        echo "  mesh: could not reach the hub over SSH — skipping (run did NOT fail)."
        echo "  mesh: to provision '$machine' by hand, on the VPS ($target) run:"
        echo "      sudo bash $script show $peer --conf-only     # existing peer"
        echo "      sudo bash $script add  $peer $ip --conf-only # new peer"
    } >&2
}

# Dry-run plan (STDOUT) — key-redacted; describes the SSH + install without doing it.
mesh_dryrun_line() {
    local machine="$1" install_path="$2" target peer ip script
    target="$(mesh_hub_target)"; peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"; script="$(mesh_hub_script)"
    echo "  ~ would ssh $target → sudo bash $script show $peer --conf-only (else add $peer $ip --conf-only)"
    echo "  ~ would install the fetched conf to $install_path (PrivateKey redacted; never shown)"
}
```

- [ ] **Step 2: Write the test `provision/lib/mesh.test.sh`** (stubbed `ssh`, temp manifest — no network)

```bash
#!/usr/bin/env bash
# provision/lib/mesh.test.sh — unit test for mesh.sh with a stubbed ssh + temp manifest.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Temp manifest: a hub + one member, matching the real field shape.
cat > "$tmp/fleet.json" <<'JSON'
{
  "machines": {
    "testbox": { "platform": "nixos", "mesh": { "ip": "10.0.0.9", "role": "member", "peerName": "nix-test" } },
    "vps": { "platform": "debian", "mesh": { "ip": "10.0.0.1", "role": "hub", "managePeers": "/srv/vps/manage-peers.sh" }, "ssh": { "user": "debian", "host": "cyphy.kz" } }
  }
}
JSON

# Stub ssh: `show` fails (peer not found), `add` returns a fake conf. Records args.
cat > "$tmp/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SSH_CALLS"
case "$*" in
    *"show "*) exit 1 ;;                                   # not found -> triggers add
    *"add "*)  printf '[Interface]\nPrivateKey = SECRETKEY123\nAddress = 10.0.0.9/32\n[Peer]\n'; exit 0 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$tmp/ssh"

export MESH_MANIFEST="$tmp/fleet.json"
export MESH_SSH="$tmp/ssh"
export SSH_CALLS="$tmp/calls"
: > "$SSH_CALLS"
# shellcheck source=/dev/null
source "$here/mesh.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) hub target + script + peer resolution
[ "$(mesh_hub_target)" = "debian@cyphy.kz" ] || fail "hub target"
[ "$(mesh_hub_script)" = "/srv/vps/manage-peers.sh" ] || fail "hub script"
[ "$(mesh_peer_name testbox)" = "nix-test" ] || fail "peer name"
[ "$(mesh_peer_ip testbox)" = "10.0.0.9" ] || fail "peer ip"

# 2) fetch: show-then-add order; returns the conf; tried show BEFORE add
conf="$(mesh_ssh_fetch testbox)" || fail "fetch rc"
printf '%s' "$conf" | grep -q '^\[Interface\]' || fail "fetch conf"
grep -q "show 'nix-test' --conf-only" "$SSH_CALLS" || fail "show attempted"
grep -q "add 'nix-test' '10.0.0.9' --conf-only" "$SSH_CALLS" || fail "add attempted"
# show must precede add
show_ln="$(grep -n 'show ' "$SSH_CALLS" | head -1 | cut -d: -f1)"
add_ln="$(grep -n 'add ' "$SSH_CALLS" | head -1 | cut -d: -f1)"
[ "$show_ln" -lt "$add_ln" ] || fail "show before add"

# 3) dry-run line is key-free and names the install path
dry="$(mesh_dryrun_line testbox /etc/amnezia-wg/awg0.key)"
echo "$dry" | grep -q "would ssh debian@cyphy.kz" || fail "dryrun target"
echo "$dry" | grep -q "/etc/amnezia-wg/awg0.key" || fail "dryrun path"
echo "$dry" | grep -qi "SECRETKEY" && fail "dryrun leaked key"

echo "ALL TESTS PASS"
```

- [ ] **Step 3: Gate — lib parses, lints, and the unit test passes** (Git Bash / WSL)

Run:
```bash
cd ~/machines
bash -n provision/lib/mesh.sh && echo "PARSE OK"
command -v shellcheck >/dev/null && shellcheck -S warning provision/lib/mesh.sh provision/lib/mesh.test.sh || echo "(shellcheck skipped)"
bash provision/lib/mesh.test.sh
```
Expected: `PARSE OK`; no shellcheck warnings; `ALL TESTS PASS`. The test proves show-before-add ordering, correct target/peer resolution, and a key-free dry-run line — with **no** real network.

- [ ] **Step 4: Commit**

```bash
git add provision/lib/mesh.sh provision/lib/mesh.test.sh
git commit -m "phase5b: provision/lib/mesh.sh — VPS conf-fetch helper (posix)

show-then-add over SSH to the hub's public endpoint (built from fleet.json);
idempotent, add-only/self-only, key never logged. Unit-tested with a stubbed
ssh + temp manifest (no network).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `provision/roles/mesh-member.sh` — posix executor (NixOS verifier + key fetch)

**Files:**
- Create: `provision/roles/mesh-member.sh`

**Interfaces:**
- Consumes: `provision/lib/mesh.sh` (Task 3) — `mesh_ssh_fetch`, `mesh_manual_hint`, `mesh_dryrun_line`. Called by the generic posix dispatcher (`provision.sh` sources `roles/*.sh` and invokes `role_mesh_member <mode> <platform> <machine>`).
- Produces: `role_mesh_member` (function). NixOS = key-fetch + verifier; `wsl`/`debian`/other = documented skip.

- [ ] **Step 1: Write `provision/roles/mesh-member.sh`**

```bash
# provision/roles/mesh-member.sh — the `mesh-member` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_mesh_member.
#
# NixOS: `switch` already declares awg0 + sshd (modules/system/mesh-vpn.nix).
# The only imperative gap is the out-of-store private key. This executor: if
# /etc/amnezia-wg/awg0.key is absent, fetch THIS box's conf from the VPS hub
# (lib/mesh.sh), extract the PrivateKey, and write it root-owned; then verify
# the tunnel (handshake + that the AmneziaWG kernel module is loaded). It never
# mutates the declared config and never generates keys locally.
#
# wsl shares the Windows host tunnel; debian is the hub, not a member.
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
# shellcheck shell=bash

role_mesh_member() {
    local mode="$1" platform="$2" machine="$3"
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=provision/lib/mesh.sh
    source "$here/../lib/mesh.sh"

    case "$platform" in
        nixos)
            local key=/etc/amnezia-wg/awg0.key
            if [ -f "$key" ]; then
                echo "  mesh-member: $key present — key already installed (no fetch)."
            elif [ "$mode" = apply ]; then
                echo "  mesh-member: $key absent — fetching this box's conf from the hub…"
                local conf priv
                if conf="$(mesh_ssh_fetch "$machine")"; then
                    priv="$(printf '%s\n' "$conf" | sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' | head -1)"
                    if [ -z "$priv" ]; then
                        echo "  mesh-member: fetched conf had no PrivateKey — aborting (nothing written)." >&2
                        return 1
                    fi
                    sudo install -m 600 -o root -g root /dev/null "$key"
                    printf '%s\n' "$priv" | sudo tee "$key" >/dev/null
                    echo "  mesh-member: wrote $key (root:600). PrivateKey not shown."
                else
                    mesh_manual_hint "$machine"
                    return 0   # graceful: a hub hiccup must not fail the run
                fi
            else
                mesh_dryrun_line "$machine" "$key"
            fi
            [ "$mode" = apply ] && _mesh_member_nixos_verify || echo "  ~ would verify awg0 handshake + kernel module after install."
            return 0
            ;;
        wsl)
            echo "  mesh-member: wsl shares the Windows host's AmneziaVPN tunnel — no separate setup (skipped)."
            return 0
            ;;
        debian)
            echo "  mesh-member: 'debian' is the hub platform, not a mesh member (skipped)."
            return 0
            ;;
        *)
            echo "  mesh-member: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}

# Best-effort tunnel verify (apply only; may prompt for sudo). Non-fatal.
_mesh_member_nixos_verify() {
    if command -v awg >/dev/null 2>&1 && sudo awg show awg0 >/dev/null 2>&1; then
        local hs
        hs="$(sudo awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)"
        if [ -n "$hs" ] && [ "$hs" != 0 ]; then
            echo "  mesh-member: awg0 up with a recent handshake. ✓"
        else
            echo "  mesh-member: awg0 configured but no handshake yet (enable/keepalive, or check the hub peer)."
        fi
    else
        echo "  mesh-member: awg0 not up. If 'modprobe: amneziawg not found', reboot into the LTS kernel 6.18.38 so the out-of-tree module loads."
    fi
}
```

- [ ] **Step 2: Gate — parses, lints, and dispatches cleanly** (Git Bash / WSL; stubbed so no SSH/sudo fires)

Run:
```bash
cd ~/machines
bash -n provision/roles/mesh-member.sh && echo "PARSE OK"
command -v shellcheck >/dev/null && shellcheck -S warning provision/roles/mesh-member.sh || echo "(shellcheck skipped)"

# Dry-run must print the key-redacted plan and open no SSH. Stub ssh via a temp
# dir on PATH and a temp key path so the idempotency branch is not taken.
tmp="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho "SSH SHOULD NOT RUN IN DRY-RUN" >&2; exit 99\n' > "$tmp/ssh"; chmod +x "$tmp/ssh"
( source provision/roles/mesh-member.sh
  PATH="$tmp:$PATH" role_mesh_member dry-run nixos latitude5520 )
rm -rf "$tmp"
```
Expected: `PARSE OK`; no shellcheck warnings; the dry-run prints `~ would ssh debian@cyphy.kz → …` and `~ would verify awg0 …`, with **no** "SSH SHOULD NOT RUN" line (dry-run opens no SSH). (Because `/etc/amnezia-wg/awg0.key` almost certainly does not exist on this box, the executor takes the dry-run branch; if it happens to exist, expect the "key already installed" line instead — also valid.)

- [ ] **Step 3: Commit**

```bash
git add provision/roles/mesh-member.sh
git commit -m "phase5b: mesh-member.sh — NixOS key-fetch + verifier (posix executor)

Fetches this box's conf from the hub only if awg0.key is absent; extracts the
PrivateKey to a root:600 out-of-store file; verifies handshake + reminds to
reboot into the LTS kernel if the module is unloaded. Dry-run is key-redacted
and opens no SSH.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Windows conf-fetch — `provision/lib/Mesh.psm1` + `provision/roles/mesh-member.ps1`

These two are one reviewable unit (the executor is a thin driver over the module; they change together).

**Files:**
- Create: `provision/lib/Mesh.psm1`
- Create: `provision/roles/mesh-member.ps1`

**Interfaces:**
- Consumes (from Task 2): the `fleet.json` hub reach fields, via native `ConvertFrom-Json`. Uses `ssh.exe` (OpenSSH client).
- Produces:
  - `Mesh.psm1` exports: `Get-MeshHubTarget`, `Get-MeshHubScript`, `Get-MeshPeerName`, `Get-MeshPeerIp`, `Invoke-MeshSshFetch` (→ conf string or `$null`), `Write-MeshManualHint`, `Write-MeshDryRunLine`. Honors `$env:MESH_MANIFEST` / `$env:MESH_SSH` overrides for tests.
  - `mesh-member.ps1`: `Invoke-RoleMeshMember -Mode -Platform -Machine` (dot-sourced by `provision.ps1`). Windows = conf-fetch to `C:\ProgramData\amnezia-wg\awg0.conf` + import instructions + hub ping; non-Windows = skip.

- [ ] **Step 1: Write `provision/lib/Mesh.psm1`**

```powershell
# provision/lib/Mesh.psm1 — VPS conf-fetch helper for Windows. Imported by
# provision/roles/mesh-member.ps1. Uses native ConvertFrom-Json + ssh.exe.
#
# Mirrors provision/lib/mesh.sh: SSH the hub's PUBLIC endpoint (built from
# fleet.json), fetch THIS box's OWN peer conf via `show <peer> --conf-only`
# first (no rotation), else `add <peer> <ip> --conf-only`. Add-only, self-only.
# The fetched conf holds a PrivateKey: returned to the caller to install, NEVER
# logged or shown in dry-run.

function Get-MeshManifestPath {
    if ($env:MESH_MANIFEST) { return $env:MESH_MANIFEST }
    Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'fleet.json'
}
function Get-MeshManifest { Get-Content -Raw (Get-MeshManifestPath) | ConvertFrom-Json }
function Get-MeshSsh { if ($env:MESH_SSH) { $env:MESH_SSH } else { 'ssh' } }

function Get-MeshHub {
    $m = (Get-MeshManifest).machines
    foreach ($p in $m.PSObject.Properties) { if ($p.Value.mesh.role -eq 'hub') { return $p.Value } }
    return $null
}
function Get-MeshHubTarget {
    $h = Get-MeshHub
    $user = if ($h.ssh.user) { $h.ssh.user } else { 'me' }
    $host_ = if ($h.ssh.host) { $h.ssh.host } else { $h.mesh.ip }
    "$user@$host_"
}
function Get-MeshHubScript {
    $h = Get-MeshHub
    if ($h.mesh.managePeers) { $h.mesh.managePeers } else { '/home/debian/my/vps/vps/manage-peers.sh' }
}
function Get-MeshPeerName {
    param([Parameter(Mandatory)][string] $Machine)
    $rec = (Get-MeshManifest).machines.$Machine
    if ($rec.mesh.peerName) { $rec.mesh.peerName } else { $Machine }
}
function Get-MeshPeerIp {
    param([Parameter(Mandatory)][string] $Machine)
    (Get-MeshManifest).machines.$Machine.mesh.ip
}

# Fetch this machine's client conf from the hub. Returns the conf string on
# success, $null on failure. show-then-add. Key captured in a var, never logged.
function Invoke-MeshSshFetch {
    param([Parameter(Mandatory)][string] $Machine)
    $ssh = Get-MeshSsh
    $target = Get-MeshHubTarget
    $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine
    $ip = Get-MeshPeerIp -Machine $Machine
    $common = @('-o','BatchMode=yes','-o','ConnectTimeout=10',$target)

    $conf = & $ssh @common "sudo bash '$script' show '$peer' --conf-only" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($conf -join "`n") -match '\[Interface\]') { return ($conf -join "`n") }

    $conf = & $ssh @common "sudo bash '$script' add '$peer' '$ip' --conf-only" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($conf -join "`n") -match '\[Interface\]') { return ($conf -join "`n") }

    return $null
}

function Write-MeshManualHint {
    param([Parameter(Mandatory)][string] $Machine)
    $target = Get-MeshHubTarget; $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine; $ip = Get-MeshPeerIp -Machine $Machine
    Write-Warning "  mesh: could not reach the hub over SSH — skipping (run did NOT fail)."
    Write-Host   "  mesh: to provision '$Machine' by hand, on the VPS ($target) run:"
    Write-Host   "      sudo bash $script show $peer --conf-only     # existing peer"
    Write-Host   "      sudo bash $script add  $peer $ip --conf-only # new peer"
}

function Write-MeshDryRunLine {
    param([Parameter(Mandatory)][string] $Machine, [Parameter(Mandatory)][string] $InstallPath)
    $target = Get-MeshHubTarget; $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine; $ip = Get-MeshPeerIp -Machine $Machine
    Write-Host "  ~ would ssh $target -> sudo bash $script show $peer --conf-only (else add $peer $ip --conf-only)"
    Write-Host "  ~ would install the fetched conf to $InstallPath (PrivateKey redacted; never shown)"
}

Export-ModuleMember -Function Get-MeshHubTarget, Get-MeshHubScript, Get-MeshPeerName, `
    Get-MeshPeerIp, Invoke-MeshSshFetch, Write-MeshManualHint, Write-MeshDryRunLine
```

- [ ] **Step 2: Write `provision/roles/mesh-member.ps1`**

```powershell
# provision/roles/mesh-member.ps1 — the `mesh-member` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleMeshMember.
#
# Windows AmneziaWG runs via the AmneziaVPN GUI (no scriptable service). This
# executor fetches THIS box's conf from the VPS hub (Mesh.psm1) only if it is
# not already installed, writes it to C:\ProgramData\amnezia-wg\awg0.conf for
# GUI import, prints import instructions, and verifies the hub is pingable. No
# keygen, no service install.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md

function Invoke-RoleMeshMember {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  mesh-member: no Windows executor for platform '$Platform' (skipped)."
        return
    }
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Mesh.psm1') -Force

    $confPath = 'C:\ProgramData\amnezia-wg\awg0.conf'

    if (Test-Path $confPath) {
        Write-Host "  mesh-member: $confPath present — conf already installed (no fetch)."
    } elseif ($Mode -eq 'apply') {
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            Write-Warning "  mesh-member: ssh.exe not found — install the Windows OpenSSH client. Skipping."
            return
        }
        Write-Host "  mesh-member: $confPath absent — fetching this box's conf from the hub…"
        $conf = Invoke-MeshSshFetch -Machine $Machine
        if ($conf) {
            New-Item -ItemType Directory -Force (Split-Path $confPath) | Out-Null
            Set-Content -Path $confPath -Value $conf -NoNewline
            Write-Host "  mesh-member: wrote $confPath."
            Write-Host "  mesh-member: import it into AmneziaVPN (File -> Import config) and enable the tunnel."
            Write-Host "  mesh-member: REPLACE any existing tunnel for this peer — two tunnels for one IP fight."
        } else {
            Write-MeshManualHint -Machine $Machine
            return
        }
    } else {
        Write-MeshDryRunLine -Machine $Machine -InstallPath $confPath
    }

    if ($Mode -eq 'apply') {
        if (Test-Connection -ComputerName '10.0.0.1' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-Host "  mesh-member: hub 10.0.0.1 reachable. ✓"
        } else {
            Write-Host "  mesh-member: hub 10.0.0.1 not reachable yet — enable the tunnel in AmneziaVPN."
        }
    }
}
```

- [ ] **Step 3: Gate — module + executor parse; dry-run is key-redacted and opens no SSH** (PowerShell)

Run (PowerShell tool or `pwsh`):
```powershell
cd ~/machines
# Parse both files (throws on syntax error).
$null = [System.Management.Automation.Language.Parser]::ParseFile("$PWD/provision/lib/Mesh.psm1", [ref]$null, [ref]$null)
$null = [System.Management.Automation.Language.Parser]::ParseFile("$PWD/provision/roles/mesh-member.ps1", [ref]$null, [ref]$null)
Write-Host "PARSE OK"

# Resolve helpers against the real fleet.json.
Import-Module "$PWD/provision/lib/Mesh.psm1" -Force
if ((Get-MeshHubTarget) -ne 'debian@cyphy.kz') { throw "hub target wrong: $(Get-MeshHubTarget)" }
if ((Get-MeshPeerName -Machine 'g614jv') -ne 'me-g614jv') { throw "peer name wrong" }

# Dry-run: key-redacted plan, no SSH. (awg0.conf is absent on a dev box.)
. "$PWD/provision/roles/mesh-member.ps1"
$out = Invoke-RoleMeshMember -Mode 'dry-run' -Platform 'windows' -Machine 'g614jv' *>&1
$out
if ($out -match 'SECRET|PrivateKey =') { throw "dry-run leaked a key" }
if (-not ($out -join "`n" | Select-String 'would ssh debian@cyphy.kz')) { throw "no would-ssh plan line" }
Write-Host "DRY-RUN OK"
```
Expected: `PARSE OK`; the hub-target/peer-name assertions pass; the dry-run prints the `~ would ssh debian@cyphy.kz …` plan with no key material; `DRY-RUN OK`. (GOTCHA carried from Phase 2/4: capture `Write-Host` with `*>&1`, not `2>&1`.)

- [ ] **Step 4: Gate — apply confirm-gate declines cleanly with rc 0** (Git Bash driving pwsh, NOT the PowerShell tool)

The PowerShell tool runs `-NonInteractive`, so the `Read-Host` confirm in `provision.ps1` can't be exercised there. Drive it via Git Bash piping `n`:
```bash
cd ~/machines
echo n | pwsh -NoProfile -File provision/provision.ps1 -Apply -Machine g614jv; echo "rc=$?"
```
Expected: the `mesh-member` preview (the dry-run plan) prints, the `Apply mesh-member? [y/N]` prompt is answered `n`, `- mesh-member skipped.` is shown, and `rc=0`. Nothing is written to `C:\ProgramData\amnezia-wg\`. (This also exercises Task 6's dispatch wiring once that task lands; before Task 6, `mesh-member`/`mesh-hub` show the generic "not yet implemented" line — that's expected and this gate moves to after Task 6. If running tasks in order, defer Step 4 until Task 6 is in.)

- [ ] **Step 5: Commit**

```bash
git add provision/lib/Mesh.psm1 provision/roles/mesh-member.ps1
git commit -m "phase5b: Mesh.psm1 + mesh-member.ps1 — Windows conf-fetch + verify

Fetches this box's conf from the hub (show-then-add over ssh.exe) only if
awg0.conf is absent; writes it for AmneziaVPN GUI import (replace, not
coexist); pings the hub. Dry-run is key-redacted and opens no SSH.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `mesh-hub` no-op pointers + `provision.ps1` dispatch wiring

**Files:**
- Create: `provision/roles/mesh-hub.sh`
- Create: `provision/roles/mesh-hub.ps1`
- Modify: `provision/provision.ps1` (two `$RoleExecutors` map entries)

**Interfaces:**
- Consumes: nothing.
- Produces: `role_mesh_hub` (posix), `Invoke-RoleMeshHub` (Windows) — both print a pointer to `~/my/vps` and exit 0. `provision.ps1` `$RoleExecutors` gains `mesh-member` and `mesh-hub`. (The posix `provision.sh` needs **no** change — it auto-discovers `role_<name>` from `roles/*.sh`.)

- [ ] **Step 1: Write `provision/roles/mesh-hub.sh`**

```bash
# provision/roles/mesh-hub.sh — the `mesh-hub` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_mesh_hub.
#
# The AmneziaWG hub (the VPS) is owned by the sibling ~/my/vps repo
# (setup-awg.sh brings up wg0; manage-peers.sh manages peers). This repo does
# not provision the hub — the executor is a no-op pointer, in both modes.
# shellcheck shell=bash

role_mesh_hub() {
    # shellcheck disable=SC2034  # mode/platform/machine: role-signature parity
    local mode="$1" platform="$2" machine="$3"
    echo "  mesh-hub: the AmneziaWG hub is owned by the ~/my/vps repo (setup-awg.sh / manage-peers.sh) — not provisioned from here."
    return 0
}
```

- [ ] **Step 2: Write `provision/roles/mesh-hub.ps1`**

```powershell
# provision/roles/mesh-hub.ps1 — the `mesh-hub` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleMeshHub.
#
# The AmneziaWG hub (the VPS) is owned by the sibling ~/my/vps repo. No-op
# pointer (the hub is Debian anyway; this exists for dispatch-map completeness).

function Invoke-RoleMeshHub {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    Write-Host "  mesh-hub: the AmneziaWG hub is owned by the ~/my/vps repo (setup-awg.sh / manage-peers.sh) — not provisioned from here."
}
```

- [ ] **Step 3: Add the two `$RoleExecutors` entries in `provision/provision.ps1`**

Change the map from:

```powershell
$RoleExecutors = @{
    'agents'   = { param($Mode, $Platform, $Machine) Invoke-RoleAgents   -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles' = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles -Mode $Mode -Platform $Platform -Machine $Machine }
    'repos'    = { param($Mode, $Platform, $Machine) Invoke-RoleRepos    -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

to (add the two hyphenated roles — the map form is exactly why hyphenated role names avoid function-name mangling, per the file's own comment):

```powershell
$RoleExecutors = @{
    'agents'      = { param($Mode, $Platform, $Machine) Invoke-RoleAgents     -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles'    = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles   -Mode $Mode -Platform $Platform -Machine $Machine }
    'repos'       = { param($Mode, $Platform, $Machine) Invoke-RoleRepos      -Mode $Mode -Platform $Platform -Machine $Machine }
    'mesh-member' = { param($Mode, $Platform, $Machine) Invoke-RoleMeshMember -Mode $Mode -Platform $Platform -Machine $Machine }
    'mesh-hub'    = { param($Mode, $Platform, $Machine) Invoke-RoleMeshHub    -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

- [ ] **Step 4: Gate — posix dispatch runs mesh-member/mesh-hub as plans** (Git Bash / WSL)

Run:
```bash
cd ~/machines
bash -n provision/roles/mesh-hub.sh && echo "PARSE OK"
command -v shellcheck >/dev/null && shellcheck -S warning provision/roles/mesh-hub.sh || echo "(shellcheck skipped)"

# NixOS member: mesh-member shows its plan; the hub pointer never fires here.
bash provision/provision.sh --machine latitude5520 --dry-run
```
Expected: `PARSE OK`; the dry-run lists roles for `latitude5520` and under `mesh-member` prints the `~ would ssh debian@cyphy.kz …` plan (not the generic "would converge via the … executor" line, which would mean the function wasn't found). `mesh-hub` is not a role of `latitude5520`, so it won't appear; to see the hub pointer, `bash provision/provision.sh --machine vps --dry-run` prints the `mesh-hub: … owned by ~/my/vps` line.

- [ ] **Step 5: Gate — Windows dispatch resolves both roles** (PowerShell parse + dry-run)

Run:
```powershell
cd ~/machines
$null = [System.Management.Automation.Language.Parser]::ParseFile("$PWD/provision/roles/mesh-hub.ps1", [ref]$null, [ref]$null)
$null = [System.Management.Automation.Language.Parser]::ParseFile("$PWD/provision/provision.ps1", [ref]$null, [ref]$null)
Write-Host "PARSE OK"
# Full dry-run for the Windows member: mesh-member plan appears via the map entry.
pwsh -NoProfile -File provision/provision.ps1 -Machine g614jv *>&1 | Select-String 'mesh-member|would ssh'
```
Expected: `PARSE OK`; the output includes the `mesh-member` plan line (`~ would ssh debian@cyphy.kz …`), confirming the `$RoleExecutors['mesh-member']` entry dispatches to `Invoke-RoleMeshMember` rather than the "not yet implemented" fallback.

- [ ] **Step 6: Now run Task 5 Step 4** (the confirm-gate decline) — it depends on this dispatch wiring:
```bash
cd ~/machines
echo n | pwsh -NoProfile -File provision/provision.ps1 -Apply -Machine g614jv; echo "rc=$?"
```
Expected: `mesh-member` preview prints, prompt answered `n`, `- mesh-member skipped.`, `rc=0`, nothing written under `C:\ProgramData\amnezia-wg\`.

- [ ] **Step 7: Commit**

```bash
git add provision/roles/mesh-hub.sh provision/roles/mesh-hub.ps1 provision/provision.ps1
git commit -m "phase5b: mesh-hub no-op pointers + provision.ps1 dispatch wiring

role_mesh_hub / Invoke-RoleMeshHub point at ~/my/vps; provision.ps1 gains the
mesh-member + mesh-hub map entries. provision.sh needs no change (auto-discovers
role_<name>).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Project memory + acceptance sweep + real-box runbook

**Files:**
- Modify: `.claude/memory/project.md`

**Interfaces:**
- Consumes: the green state from Tasks 1–6.
- Produces: none (documentation + verification only).

- [ ] **Step 1: Session acceptance sweep** (this Windows box + latitude5520 for the Nix line)

Run (Git Bash):
```bash
cd ~/machines
set -e
echo "1) posix libs/executors parse:"
for f in provision/lib/mesh.sh provision/roles/mesh-member.sh provision/roles/mesh-hub.sh; do bash -n "$f"; done; echo OK
echo "2) mesh.sh unit test:"
bash provision/lib/mesh.test.sh
echo "3) posix dry-run dispatch (NixOS member -> mesh-member plan):"
bash provision/provision.sh --machine latitude5520 --dry-run | grep -q "would ssh debian@cyphy.kz" && echo "  mesh-member plan OK"
echo "4) hub pointer:"
bash provision/provision.sh --machine vps --dry-run | grep -q "owned by the ~/my/vps repo" && echo "  mesh-hub pointer OK"
echo "SESSION SWEEP GREEN"
```
And (PowerShell):
```powershell
cd ~/machines
pwsh -NoProfile -File provision/provision.ps1 -Machine g614jv *>&1 | Select-String 'would ssh debian@cyphy.kz' | ForEach-Object { "  windows mesh-member plan OK" }
echo n | pwsh -NoProfile -File provision/provision.ps1 -Apply -Machine g614jv | Out-Null; "windows confirm-gate rc=$LASTEXITCODE (expect 0)"
```
Expected: `SESSION SWEEP GREEN`; the Windows lines both confirm the plan + rc 0.

- [ ] **Step 2: Update `.claude/memory/project.md`**

In the "Fleet network" section, record Phase 5b as executed (session-verified; real-box pending), replacing/adding bullets to state:
- **Phase 5b EXECUTED (session-verified):** the `~/my/vps` `manage-peers.sh` gained non-interactive `add <name> <ip>` + `--conf-only` (fleet-provisioner contract); this repo has `provision/lib/mesh.sh` + `Mesh.psm1` (VPS conf-fetch: `show`-then-`add` over SSH to `debian@cyphy.kz`, add-only/self-only, key never logged), `provision/roles/mesh-member.{sh,ps1}` (NixOS key-fetch+verifier / Windows conf-fetch+verifier) and `mesh-hub.{sh,ps1}` (no-op pointer), wired in `provision.ps1`. `fleet.json` gained `vps.ssh.host=cyphy.kz` + `vps.mesh.managePeers`.
- **Real-box pending (runbook, Step 3):** (a) confirm the VPS `managePeers` path; (b) land+pull the vps change on the VPS; (c) latitude5520 key-fetch + reboot into `6.18.38`; (d) Windows conf import (replace tunnel). `homeserver`'s `mesh.peerName` still defaulted — confirm via `manage-peers.sh list` (it may be a statically-baked peer with no stored key → `show` fails and `add` errors "IP in use"; use the manual fallback for that box).

(One fact per bullet; curate — don't duplicate the 5a bullets.)

- [ ] **Step 3: Real-box runbook** (NOT a session step — record it; execute with VPS/real-box access)

```
0. CONFIRM the manage-peers path (the one guessed fleet.json value):
     ssh debian@cyphy.kz 'ls -l /home/debian/my/vps/vps/manage-peers.sh'
   If the path differs, fix machines/fleet.json .machines.vps.mesh.managePeers (one line), commit.

1. LAND the vps prereq on the VPS (Task 1 must be pushed first):
     ssh debian@cyphy.kz 'cd ~/my/vps && git pull'
     # smoke (safe, throwaway peer at an unused IP), then clean it up:
     ssh debian@cyphy.kz "sudo bash /home/debian/my/vps/vps/manage-peers.sh add smoke 10.0.0.99 --conf-only"  # prints ONLY a conf
     ssh debian@cyphy.kz "sudo bash /home/debian/my/vps/vps/manage-peers.sh remove smoke"

2. NixOS member (latitude5520), after `git pull`:
     bash provision/provision.sh --machine latitude5520 --apply   # answer y to mesh-member
     # confirm /etc/amnezia-wg/awg0.key now exists (root:600), then REBOOT into 6.18.38
     sudo awg show awg0    # expect a recent handshake once rebooted

3. Windows members (g614jv, homeserver): from an elevated pwsh, after `git pull`:
     pwsh -File provision/provision.ps1 -Apply -Machine g614jv   # answer y
     # import C:\ProgramData\amnezia-wg\awg0.conf into AmneziaVPN, REPLACING the existing tunnel; enable
     ping 10.0.0.1 ; ssh g614jv    # over the mesh
   homeserver: first `ssh debian@cyphy.kz "sudo bash <path>/manage-peers.sh list"` to confirm its peer
   name; if it has no stored key, use the printed manual fallback (do not blindly `add` — "IP in use").
```

- [ ] **Step 4: Commit**

```bash
git add .claude/memory/project.md
git commit -m "phase5b: record executed (session-verified) + real-box runbook

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (against `2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md`, the 5b-labelled scope):
- vps `manage-peers.sh` non-interactive prereq (`add <name> <ip>` + `--conf-only`) → Task 1.
- Shared VPS conf-fetch helper (`provision/lib/mesh.sh` + `Mesh.psm1`): idempotency, SSH public endpoint, show-then-add, add-only/self-only, graceful fallback, secret handling, dry-run → Tasks 3 & 5.
- `mesh-member.sh` (NixOS verifier + key fetch) → Task 4; `mesh-member.ps1` (Windows conf fetch + verify) → Task 5.
- `mesh-hub.{sh,ps1}` no-op pointer → Task 6.
- Dispatch: `provision.ps1` two map entries; `provision.sh` unchanged → Task 6.
- `fleet.json` hub reach (`ssh.host` + `managePeers`) → Task 2. (The spec's `ssh.user`/`mesh.peerName` additions already landed in 5a; 5b adds only the reach fields the executor needs.)
- Verification (parse, dry-run no-op/idempotency, Windows confirm-gate, unit test) → each task's gate + Task 7 sweep; real-box runbook → Task 7 Step 3.
- Install paths (`/etc/amnezia-wg/awg0.key` root:600; `C:\ProgramData\amnezia-wg\awg0.conf`) → Tasks 4 & 5.

**Placeholder scan:** every code step shows full file content or an exact before/after replacement. The one non-derivable value — the VPS `managePeers` path — is given a concrete convention-based value with an explicit runbook confirm step (not a "TBD").

**Type consistency:** `mesh.sh` exposes `mesh_hub_target`/`mesh_hub_script`/`mesh_peer_name`/`mesh_peer_ip`/`mesh_ssh_fetch`/`mesh_manual_hint`/`mesh_dryrun_line`; `mesh-member.sh` consumes exactly `mesh_ssh_fetch`/`mesh_manual_hint`/`mesh_dryrun_line`. `Mesh.psm1` exports the PascalCase mirror (`Get-MeshHubTarget`, `Invoke-MeshSshFetch`, `Write-MeshManualHint`, `Write-MeshDryRunLine`); `mesh-member.ps1` calls exactly those. `role_mesh_member`/`role_mesh_hub` match the posix dispatcher's `role_${role//-/_}` convention; `Invoke-RoleMeshMember`/`Invoke-RoleMeshHub` match the `$RoleExecutors` scriptblocks. `fleet.json` `vps.ssh.host`/`vps.mesh.managePeers` are read by `mesh_hub_target`/`mesh_hub_script` (jq) and `Get-MeshHubTarget`/`Get-MeshHubScript` (ConvertFrom-Json) with identical `//`/`if` fallbacks.

**Cross-repo note:** Task 1 commits to `~/my/vps` (its own origin); Tasks 2–7 commit to `machines`. The subagent-driven `review-package BASE HEAD` for Task 1 must run inside `~/my/vps`; for all other tasks inside `machines`.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-09-fleet-provisioner-phase5b-mesh-executors.md`.**

Two real-box facts this session could not verify (both isolated to one `fleet.json` value + the eventual apply, not the code):
1. **The VPS checkout path** of `~/my/vps` — this plan uses `/home/debian/my/vps/vps/manage-peers.sh` (repo namespace convention + `debian` user). Confirm with: `ssh debian@cyphy.kz 'ls -l /home/debian/my/vps/vps/manage-peers.sh'`.
2. **SSH reach from a member to the hub** (`debian@cyphy.kz`) — the plan's central assumption. Confirm with: `ssh -o BatchMode=yes debian@cyphy.kz whoami`.

You can run both yourself now via the `!` prefix in the prompt; if the path differs it's a one-line Task 2 edit.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks. Best fit: Task 1 lands in the vps repo, Tasks 3/5 carry unit + dry-run gates verifiable here, and the NixOS/real-box gates land on latitude5520 — tight, independently-reviewable diffs.
2. **Inline Execution** — execute in this session with checkpoints. This box can complete all edits, the `jq`/`bash -n`/shellcheck gates, the `mesh.sh` unit test, the PowerShell parse + dry-run gates, and the Windows confirm-gate; the NixOS dry-build line and every real-box step defer to latitude5520 / a VPS-access run.

**Which approach?**
