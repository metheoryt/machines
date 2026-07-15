# Orca headless server on WSL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve one headless `orca serve` runtime per WSL2 distro, each enrolled as a distinct Headscale tailnet node, reachable from the Orca desktop/mobile client over the tailnet.

**Architecture:** Two standalone, idempotent bash scripts under `provision/`, mirroring `provision/linux.sh` conventions. `tailscale-wsl.sh` installs `tailscaled` and enrolls the distro as its own Headscale node (own `100.64.x.y`). `orca-serve.sh` extracts the Orca CLI from the Linux AppImage (headless, no FUSE) and autostarts `orca serve` on the default port `6768` via a systemd **user** unit + linger. Inbound reaches the distro through the VPS DERP relay over WSL's default NAT — no port forwarding, no `.wslconfig` change.

**Tech Stack:** bash, apt (Ubuntu 26.04), Tailscale/Headscale (`https://cc.cyphy.kz`), systemd user services, Orca AppImage.

## Global Constraints

- Target: Debian/Ubuntu, **x86_64 only** (matches `provision/linux.sh`). Reference distro: `Ubuntu-26.04`.
- Both scripts: `set -u`, `info/ok/warn/die/have` helpers copied verbatim from `provision/linux.sh` style; **idempotent** (re-run = no-op with `✓ already …`).
- Headscale control server: `https://cc.cyphy.kz`. MagicDNS base domain: `fleet.mesh`. Tailnet range: `100.64.0.0/10`.
- Secrets are **env only, never committed**: `HEADSCALE_AUTHKEY` (reusable pre-auth key, Headscale user `fleet`). The Orca **pairing URL** is a credential — never printed into the repo.
- Node hostname default: `wsl-<sanitized $WSL_DISTRO_NAME>` (lowercase, non-`[a-z0-9-]`→`-`, collapse/trim), overridable via `ORCA_TS_HOSTNAME`.
- Orca serve port: **6768** (default; per-distro distinct IP means no port juggling).
- Orca version: default `latest`, overridable via `ORCA_VERSION` (no repo pin file — deliberate).
- sudo handling: `SUDO="sudo"` when non-root, `die` if neither root nor sudo (as in `linux.sh`).
- Some steps run **anywhere** (shellcheck, pure-function checks, guard checks); steps marked **[WSL]** must run inside a real Ubuntu-26.04 WSL distro on the tailnet.

---

## File Structure

- Create: `provision/tailscale-wsl.sh` — enroll this distro as a Headscale node.
- Create: `provision/orca-serve.sh` — install Orca + autostart `orca serve`.
- Modify: `provision/README.md` — add a "## Orca headless server (WSL)" section.

---

### Task 1: `provision/tailscale-wsl.sh` — enroll distro as a Headscale node

> **Amended 2026-07-16 — zero-touch re-enroll (shipped).** The verbatim script
> below is the original v1 (manual: `$HEADSCALE_AUTHKEY` env only, early `exit 0`
> when already enrolled). The live script now also: (a) resolves the pre-auth key
> by precedence `--authkey-file <path>` → `$HEADSCALE_AUTHKEY` → persisted
> `/etc/headscale/authkey`, and persists a freshly-supplied key there
> (`root:root 0600`); (b) drops the early `exit 0` so the key + unit retrofit onto
> an already-enrolled distro, making `tailscale up` conditional on not-already-up;
> (c) installs + enables a systemd **system** oneshot
> `tailscale-autoconnect.service` (baked hostname, `ConditionPathExists`,
> `tailscale status || tailscale up`) for hands-free re-enroll after a
> rebuild/logout. New pure helper `ts_pick_key` (precedence) is unit-tested
> alongside `ts_sanitize_hostname` in `provision/tailscale-wsl.test.sh`. `.gitignore`
> gains `provision/secrets/`. See the design doc's §5/§5b for rationale. The
> `provision/tailscale-wsl.sh` in the repo is the source of truth.

**Files:**
- Create: `provision/tailscale-wsl.sh`
- Create: `provision/tailscale-wsl.test.sh` (unit tests: sanitizer + key precedence)

**Interfaces:**
- Consumes: env `HEADSCALE_AUTHKEY` (required unless already enrolled), optional `ORCA_TS_HOSTNAME`.
- Produces: this distro up on the tailnet; `tailscale ip -4` returns a `100.64.x.y`. Function `ts_sanitize_hostname <str>` → DNS-label-safe string (relied on by nothing else, but unit-tested here).

- [ ] **Step 1: Write the script**

Create `provision/tailscale-wsl.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# provision/tailscale-wsl.sh — enroll THIS WSL2 distro as a distinct node on the
# fleet's Headscale tailnet (control https://cc.cyphy.kz), so a server running
# inside the distro (Orca, ssh, rustdesk) is reachable from other tailnet nodes
# at its OWN 100.64.x.y — independent of the Windows host's own Tailscale.
# Pairs with provision/orca-serve.sh.
#
# Model: one tailscaled PER distro (NOT host mirrored-networking), so N distros
# on one Windows host each get a distinct identity and Orca can use the default
# port 6768 everywhere. Inbound arrives via the VPS DERP relay (region 999)
# through WSL's default NAT — no port forwarding, no .wslconfig change.
#
# Idempotent; safe to re-run. Requires systemd in the distro (Ubuntu 24.04+/
# 26.04 default; else set [boot] systemd=true in /etc/wsl.conf and `wsl -t <d>`).
#
# Usage (inside the distro):
#   export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
#   bash ~/machines/provision/tailscale-wsl.sh
#   # optional custom node name:
#   ORCA_TS_HOSTNAME=devbox bash ~/machines/provision/tailscale-wsl.sh
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

LOGIN_SERVER="https://cc.cyphy.kz"

# DNS-label safe: lowercase, non [a-z0-9-] → '-', collapse repeats, trim edges.
ts_sanitize_hostname() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Allow sourcing just the function (for tests) without running main.
[ "${TS_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  warn "does not look like WSL — continuing anyway."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

# systemd is required for tailscaled as a service.
if ! systemctl show-environment >/dev/null 2>&1; then
  die "systemd not running in this distro. Add to /etc/wsl.conf:  [boot]\\nsystemd=true  then 'wsl -t $(uname -n)' and re-open."
fi

# ── Node hostname ─────────────────────────────────────────────────────────────
DEFAULT_NAME="wsl-$(ts_sanitize_hostname "${WSL_DISTRO_NAME:-$(uname -n)}")"
HOSTNAME_TS="${ORCA_TS_HOSTNAME:-$DEFAULT_NAME}"
info "Node hostname: $HOSTNAME_TS"

# ── Already enrolled? (idempotent) ────────────────────────────────────────────
if have tailscale && tailscale ip -4 2>/dev/null | grep -qE '^100\.'; then
  ok "already enrolled on the tailnet: $(tailscale ip -4 | head -1) ($HOSTNAME_TS.fleet.mesh)"
  exit 0
fi

# ── Install tailscale ─────────────────────────────────────────────────────────
if have tailscale; then
  ok "tailscale already installed"
else
  info "Installing tailscale…"
  curl -fsSL https://tailscale.com/install.sh | sh || die "tailscale install failed."
fi

# ── Start the daemon ──────────────────────────────────────────────────────────
$SUDO systemctl enable --now tailscaled || die "could not start tailscaled."

# ── /dev/net/tun sanity ───────────────────────────────────────────────────────
[ -e /dev/net/tun ] || warn "/dev/net/tun missing — inbound serving may need 'tailscaled --tun=userspace-networking'. Modern WSL2 kernels provide tun."

# ── Enroll ────────────────────────────────────────────────────────────────────
[ -n "${HEADSCALE_AUTHKEY:-}" ] || die "HEADSCALE_AUTHKEY not set. Export the reusable pre-auth key (headscale user 'fleet') and re-run."
info "Enrolling on $LOGIN_SERVER as $HOSTNAME_TS…"
$SUDO tailscale up \
  --login-server "$LOGIN_SERVER" \
  --authkey "$HEADSCALE_AUTHKEY" \
  --hostname "$HOSTNAME_TS" \
  || die "tailscale up failed."

# ── Verify ────────────────────────────────────────────────────────────────────
IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$IP" ] || die "enrolled but no tailnet IPv4 yet — check 'tailscale status'."
ok "node '$HOSTNAME_TS' up at $IP  (MagicDNS: ${HOSTNAME_TS}.fleet.mesh)"
printf '\nNext: bash %s\n' "$(dirname "$0")/orca-serve.sh"
```

- [ ] **Step 2: Lint (runs anywhere shellcheck is present)**

Run: `shellcheck provision/tailscale-wsl.sh` (in the distro: `sudo apt-get install -y shellcheck` first).
Expected: no errors. (SC2016 in single-quoted `wsl.conf` hint is acceptable; the `\\n` is literal on purpose.)

- [ ] **Step 3: Unit-test the sanitizer (runs anywhere)**

Run:
```bash
TS_WSL_LIB_ONLY=1
out=$(bash -c 'TS_WSL_LIB_ONLY=1 source provision/tailscale-wsl.sh; ts_sanitize_hostname "Ubuntu-26.04"')
[ "$out" = "ubuntu-26-04" ] && echo "PASS: $out" || { echo "FAIL: got '$out'"; exit 1; }
out2=$(bash -c 'TS_WSL_LIB_ONLY=1 source provision/tailscale-wsl.sh; ts_sanitize_hostname "My_Cool Distro!!"')
[ "$out2" = "my-cool-distro" ] && echo "PASS: $out2" || { echo "FAIL: got '$out2'"; exit 1; }
```
Expected: `PASS: ubuntu-26-04` then `PASS: my-cool-distro`.

- [ ] **Step 4: Guard check — missing authkey dies cleanly [WSL]**

Precondition: distro NOT yet enrolled (fresh, or `sudo tailscale logout` first).
Run: `unset HEADSCALE_AUTHKEY; bash provision/tailscale-wsl.sh; echo "exit=$?"`
Expected: reaches the enroll step and dies with `HEADSCALE_AUTHKEY not set…`, `exit=1`. (If systemd/tun warnings appear first, that's fine.)

- [ ] **Step 5: Real enrollment [WSL]**

Run:
```bash
export HEADSCALE_AUTHKEY='<reusable pre-auth key>'
bash provision/tailscale-wsl.sh
```
Expected: ends with `node 'wsl-ubuntu-26-04' up at 100.64.x.y (MagicDNS: wsl-ubuntu-26-04.fleet.mesh)`. Verify on the VPS: `headscale nodes list` shows the new node. Re-run once: expected `✓ already enrolled …` and exit 0 (idempotency).

- [ ] **Step 6: Commit**

```bash
git add provision/tailscale-wsl.sh
git commit -m "feat(provision): enroll a WSL distro as its own Headscale node

provision/tailscale-wsl.sh installs tailscaled and joins the fleet tailnet
(cc.cyphy.kz) with a per-distro hostname, so each WSL distro gets a distinct
100.64.x.y. Idempotent; systemd-required; authkey via HEADSCALE_AUTHKEY env.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `provision/orca-serve.sh` — install Orca + autostart the server

**Files:**
- Create: `provision/orca-serve.sh`

**Interfaces:**
- Consumes: a live tailnet IP from Task 1 (`tailscale ip -4`); optional `ORCA_VERSION`.
- Produces: `~/.local/bin/orca` (CLI), `~/.local/bin/orca-serve-start` (wrapper computing `--pairing-address` at runtime), `~/.config/systemd/user/orca-serve.service` (enabled), Orca reachable at `<tailnet-ip>:6768`.

- [ ] **Step 1: Write the script**

Create `provision/orca-serve.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# provision/orca-serve.sh — install Orca and autostart a headless `orca serve`
# runtime in THIS WSL2 distro, reachable over the tailnet (run
# provision/tailscale-wsl.sh FIRST). The Orca desktop/mobile client pairs to it
# and drives repos/terminals/agents that live natively on the distro's Linux
# filesystem — not across the slow \\wsl.localhost 9P boundary.
#
# Orca ships on Linux only as a GUI AppImage; the `orca` CLI (which `serve`
# needs) is bundled inside. We extract it headlessly with --appimage-extract
# (no FUSE, no root) and symlink the CLI onto PATH.
#
# Idempotent; safe to re-run. Serve autostarts via a systemd *user* unit +
# linger, mirroring provision/linux.sh's git-autofetch pattern.
#
# Usage (inside the distro, AFTER tailscale-wsl.sh):
#   bash ~/machines/provision/orca-serve.sh
#   ORCA_VERSION=1.2.3 bash ~/machines/provision/orca-serve.sh   # pin a version
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

have tailscale || die "tailscale not found — run provision/tailscale-wsl.sh first."
TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$TSIP" ] || die "no tailnet IPv4 — run provision/tailscale-wsl.sh first."
ok "tailnet IP: $TSIP"

# ── Electron runtime deps (best-effort; names vary across releases) ───────────
# _apt_try installs the FIRST existing package name from its args; warns if none.
_apt_try() {
  local p
  for p in "$@"; do
    if $SUDO apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
      ok "dep $p"; return 0
    fi
  done
  warn "none of [$*] installed — orca may hit a missing .so"
}
info "Installing Electron runtime libs…"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq || warn "apt-get update failed — dep install may be stale"
_apt_try libnss3
_apt_try libgbm1
_apt_try libgtk-3-0t64 libgtk-3-0
_apt_try libasound2t64 libasound2
_apt_try libatk-bridge2.0-0t64 libatk-bridge2.0-0
_apt_try libatk1.0-0t64 libatk1.0-0
_apt_try libcups2t64 libcups2
_apt_try libxshmfence1
_apt_try libdrm2
_apt_try libxkbcommon0
_apt_try libxcomposite1
_apt_try libxdamage1
_apt_try libxrandr2
_apt_try libxfixes3
_apt_try libpango-1.0-0
_apt_try xvfb   # fallback virtual display for headless Electron

# ── Download + extract the AppImage (headless, no FUSE) ───────────────────────
ORCA_DIR="$HOME/.local/opt/orca"; mkdir -p "$ORCA_DIR"
VER="${ORCA_VERSION:-latest}"
if [ "$VER" = latest ]; then
  URL="https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage"
else
  URL="https://github.com/stablyai/orca/releases/download/v${VER}/orca-linux.AppImage"
fi
AI="$ORCA_DIR/orca-${VER}.AppImage"
if [ -f "$AI" ]; then
  ok "AppImage present: $AI"
else
  info "Downloading Orca AppImage ($VER)…"
  curl -fsSL "$URL" -o "$AI" || die "AppImage download failed: $URL"
fi
chmod +x "$AI"

info "Extracting CLI (--appimage-extract)…"
rm -rf "$ORCA_DIR/squashfs-root"
( cd "$ORCA_DIR" && "$AI" --appimage-extract >/dev/null 2>&1 ) || die "--appimage-extract failed."

# ── Expose the orca CLI on PATH ───────────────────────────────────────────────
CLI="$(find "$ORCA_DIR/squashfs-root" -type f -name orca 2>/dev/null | head -1)"
if [ -n "$CLI" ]; then
  chmod +x "$CLI"
  ln -sf "$CLI" "$HOME/.local/bin/orca"
  ok "orca CLI → ~/.local/bin/orca ($CLI)"
else
  APPRUN="$ORCA_DIR/squashfs-root/AppRun"
  [ -x "$APPRUN" ] || die "no 'orca' binary and no AppRun in squashfs-root — cannot expose a CLI."
  cat > "$HOME/.local/bin/orca" <<EOF
#!/usr/bin/env bash
exec "$APPRUN" "\$@"
EOF
  chmod +x "$HOME/.local/bin/orca"
  ok "orca CLI wrapper → ~/.local/bin/orca (AppRun)"
fi

# ── Verify the CLI runs headlessly (xvfb fallback) ────────────────────────────
NEED_XVFB=0
if orca --help >/dev/null 2>&1; then
  ok "orca CLI works headlessly"
elif have xvfb-run && xvfb-run -a orca --help >/dev/null 2>&1; then
  NEED_XVFB=1
  warn "orca needs a virtual display — serve will run under xvfb-run"
else
  warn "orca --help failed. Check libs:  ldd \"$CLI\" | grep 'not found'  — or run once under WSLg."
fi

# ── Serve wrapper (computes pairing address fresh at each start) ──────────────
SERVE="$HOME/.local/bin/orca-serve-start"
RUN_PREFIX=""
[ "$NEED_XVFB" = 1 ] && RUN_PREFIX="xvfb-run -a "
cat > "$SERVE" <<EOF
#!/usr/bin/env bash
# orca-serve-start — launch the headless Orca runtime bound to this node's
# current tailnet IP. Written by provision/orca-serve.sh.
set -u
export PATH="\$HOME/.local/bin:\$PATH"
addr="\$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "\$addr" ] || { echo "orca-serve-start: no tailnet IPv4 (is tailscaled up?)" >&2; exit 1; }
exec ${RUN_PREFIX}orca serve --port 6768 --pairing-address "\$addr"
EOF
chmod +x "$SERVE"
ok "serve wrapper → ~/.local/bin/orca-serve-start"

# ── Autostart via systemd user unit + linger ──────────────────────────────────
if systemctl --user show-environment >/dev/null 2>&1; then
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
  cat > "$UD/orca-serve.service" <<'UNIT'
[Unit]
Description=Orca headless runtime server (tailnet, port 6768)
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/orca-serve-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  if systemctl --user enable --now orca-serve.service >/dev/null 2>&1; then
    $SUDO loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
    ok "orca-serve.service enabled (autostart + linger)"
  else
    warn "could not enable orca-serve.service — start manually: orca-serve-start"
  fi
else
  warn "no systemd user manager — start manually: orca-serve-start (or under tmux/nohup). Enable systemd in /etc/wsl.conf for autostart."
fi

# ── Next steps ────────────────────────────────────────────────────────────────
cat <<EOF

Orca server ready on this distro.
  • Pairing URL (SECRET — do not commit):  journalctl --user -u orca-serve -f
  • Reach it at:  ${TSIP}:6768   (or <node>.fleet.mesh:6768 with MagicDNS)
  • Pair a client:  orca environment add --name $(uname -n) --pairing-code '<orca://pair?…>'
EOF
```

- [ ] **Step 2: Lint (runs anywhere shellcheck is present)**

Run: `shellcheck provision/orca-serve.sh`
Expected: no errors. (Heredoc-escaped `\$` inside double-quoted heredocs is intentional — the wrapper must expand at run time, not install time.)

- [ ] **Step 3: Guard check — no tailnet dies cleanly [WSL]**

On a distro where `tailscale ip -4` returns nothing (or `tailscale` absent):
Run: `bash provision/orca-serve.sh; echo "exit=$?"`
Expected: dies with `no tailnet IPv4 — run provision/tailscale-wsl.sh first.` (or `tailscale not found …`), `exit=1`.

- [ ] **Step 4: Full install on an enrolled distro [WSL]**

Precondition: Task 1 done (node up). Run: `bash provision/orca-serve.sh`
Expected:
- `~/.local/bin/orca` exists and `orca --help` runs (directly, or the wrapper reports xvfb fallback).
- `~/.local/bin/orca-serve-start` exists; its `exec` line references `orca serve --port 6768 --pairing-address "$addr"` (with `xvfb-run -a` prefix iff the fallback triggered).
- `systemctl --user is-active orca-serve` → `active`.
- `journalctl --user -u orca-serve -n 40` prints a `orca://pair?…` URL.

- [ ] **Step 5: End-to-end pairing [WSL + client]**

From the Windows Orca client (or mobile), add the environment using the pairing code from Step 4 and open a terminal — confirm it lands inside the distro (`echo $WSL_DISTRO_NAME` shows the distro; `pwd` is a Linux path). Re-run `bash provision/orca-serve.sh` once — expected idempotent (`✓ AppImage present`, service still active).

- [ ] **Step 6: Commit**

```bash
git add provision/orca-serve.sh
git commit -m "feat(provision): install Orca + autostart headless serve on WSL

provision/orca-serve.sh extracts the orca CLI from the Linux AppImage
(--appimage-extract, no FUSE), then autostarts 'orca serve --port 6768' via a
systemd-user unit + linger, bound to this distro's tailnet IP. Idempotent;
xvfb fallback for headless Electron.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Document the WSL Orca flow in `provision/README.md`

**Files:**
- Modify: `provision/README.md` (append a new section after the existing content)

**Interfaces:**
- Consumes: the two scripts from Tasks 1–2.
- Produces: operator docs.

- [ ] **Step 1: Append the section**

Append this to the end of `provision/README.md`:

```markdown

## Orca headless server (WSL)

Serve one Orca runtime per WSL2 distro, each a distinct Headscale tailnet node,
so the Orca desktop/mobile client drives repos that live natively on the distro's
Linux filesystem (not across the slow `\\wsl.localhost` 9P boundary). Design:
`docs/superpowers/specs/2026-07-15-orca-serve-wsl-design.md`.

Run **both scripts inside each distro**, in order:

    # 1. Join the fleet tailnet as this distro's own node (needs systemd + sudo)
    export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
    bash ~/machines/provision/tailscale-wsl.sh          # → wsl-<distro> @ 100.64.x.y

    # 2. Install Orca + autostart `orca serve` on :6768 (systemd-user + linger)
    bash ~/machines/provision/orca-serve.sh

Then read the pairing URL and add it on the client:

    journalctl --user -u orca-serve -f                  # prints orca://pair?… (SECRET)
    # on the Windows/mobile client:
    orca environment add --name <distro> --pairing-code '<orca://pair?…>'

Notes:

- **Per-distro identity.** Each distro runs its own `tailscaled` and gets a
  distinct `100.64.x.y` + MagicDNS name (`wsl-<distro>.fleet.mesh`), so every
  Orca server uses the default port `6768`. No `.wslconfig` mirrored networking,
  no `netsh portproxy` — inbound rides the VPS DERP relay through WSL's NAT.
- **Hostname** defaults to `wsl-<sanitized $WSL_DISTRO_NAME>`; override with
  `ORCA_TS_HOSTNAME`.
- **Version** defaults to `latest`; pin with `ORCA_VERSION`.
- **Secrets** (`HEADSCALE_AUTHKEY`, the pairing URL) are never committed.
- Rebuilding a distro (`wsl --unregister`) leaves a stale Headscale node — prune
  with `headscale nodes delete` on the VPS.
```

- [ ] **Step 2: Verify it renders**

Run: `grep -n "Orca headless server (WSL)" provision/README.md`
Expected: one match. Eyeball the fenced blocks are balanced (even count): `grep -c '^    ' provision/README.md` increases; `grep -c '```' provision/README.md` stays even.

- [ ] **Step 3: Commit**

```bash
git add provision/README.md
git commit -m "docs(provision): how to serve Orca per WSL distro over the tailnet

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Per-distro tailscaled enrollment, distinct node, `HEADSCALE_AUTHKEY` env, hostname default → Task 1. ✓
- AppImage `--appimage-extract` CLI, Electron deps, xvfb fallback, `ORCA_VERSION` → Task 2. ✓
- systemd-user autostart + linger, start-time pairing-address wrapper, default port 6768 → Task 2. ✓
- Pairing URL as secret, journal read, client `environment add` → Task 2 output + Task 3. ✓
- No `.wslconfig` change; DERP-relayed inbound → documented in Task 3. ✓
- Windows-side prereqs are out of scope (host Tailscale already winget) → noted, not a task. ✓

**Placeholder scan:** the only `<…>` are user-supplied secrets/pairing codes (correct — not plan placeholders). No TBD/TODO.

**Type/name consistency:** `ts_sanitize_hostname`, `HEADSCALE_AUTHKEY`, `ORCA_TS_HOSTNAME`, `ORCA_VERSION`, `orca-serve-start`, `orca-serve.service`, port `6768`, login server `https://cc.cyphy.kz`, MagicDNS `fleet.mesh` — used identically across all tasks and the spec.
