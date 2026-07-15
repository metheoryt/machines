# Orca headless server on WSL — design

Date: 2026-07-15 (zero-touch re-enroll added 2026-07-16)
Status: implemented; zero-touch re-enroll shipped 2026-07-16
Topic: serve one Orca runtime per WSL distro, each a distinct Headscale node,
reachable over the tailnet from the Windows Orca client / mobile.

## Goal

Run `orca serve` headless inside one or more WSL2 distros on a single Windows
host, so the Orca desktop client (and mobile) can drive an always-on dev box
whose repos, worktrees, terminals, and agent processes live natively on the
Linux filesystem — not across the slow `\\wsl.localhost` (9P) boundary.

Multiple distros on one host must each be independently reachable. The chosen
model gives **each distro its own tailnet identity** (distinct `100.64.x.y` +
MagicDNS name), so every Orca server can use the default port `6768` with no
port juggling and no host-side `netsh portproxy` / `.wslconfig` mirrored
networking.

## Why per-distro tailnet nodes (not shared host IP)

Two models were considered:

- **(A, chosen) tailscaled per distro.** Each WSL distro runs its own
  `tailscaled` and enrolls as a distinct Headscale node. Own IP + MagicDNS
  name; Orca on default `6768` everywhere; inbound from other tailnet nodes
  arrives via the VPS DERP relay (region 999) even through WSL's default NAT —
  no port forwarding. Nodes appear individually in Headscale alongside
  `vps`/`latitude`/`homeserver`, consistent with the fleet's AWG→Headscale
  migration. Independent of the Windows host's own Tailscale state.
- **(B, rejected) one host node + mirrored networking.** All distros share the
  host's single tailnet IP; each Orca needs a distinct port and a global
  `.wslconfig` `networkingMode=mirrored` change (a `wsl --shutdown` affecting
  every distro). Simpler to install but collapses the distros onto one identity
  — the opposite of the requirement.

(A) is default NAT networking, so it needs **no** `.wslconfig` change.

## Deliverables — two standalone scripts

Both mirror `provision/linux.sh` conventions: `info/ok/warn/die` helpers,
best-effort where a failure shouldn't abort, **idempotent**, safe to re-run.
Standalone (not `provision.sh` roles) — matching how `linux.sh` itself is a
direct-run script. Run **both, in order, inside each distro**.

### 1. `provision/tailscale-wsl.sh` — enroll this distro as a Headscale node

Responsibilities:

1. **Preconditions** — Debian/Ubuntu + x86_64; confirm running under WSL
   (`$WSL_DISTRO_NAME` set or `/proc/version` mentions microsoft) — warn, not
   fail, if not. Require systemd (`systemctl show-environment` probe, as in
   `linux.sh`); if absent, warn with the `/etc/wsl.conf` `[boot] systemd=true`
   fix and abort (tailscaled needs it).
2. **`/dev/net/tun`** — present on modern WSL2 kernels. If missing, warn +
   document the `--tun=userspace-networking` caveat (inbound serving degrades)
   and continue best-effort.
3. **Install tailscale** — `curl -fsSL https://tailscale.com/install.sh | sh`
   (adds the official apt repo + `tailscaled` systemd unit). Skip if `tailscale`
   already on PATH.
4. **Start the daemon** — `sudo systemctl enable --now tailscaled`.
5. **Enroll** — if `tailscale status` shows this node already up on
   `cc.cyphy.kz`, skip the `tailscale up` (but still persist the key + install
   the autoconnect unit, so the flow retrofits onto an already-enrolled distro).
   Else:
   `sudo tailscale up --login-server https://cc.cyphy.kz --authkey "$AUTHKEY" --hostname "$ORCA_TS_HOSTNAME"`.
   - **Pre-auth key resolution (precedence high→low):** `--authkey-file <path>`
     → `$HEADSCALE_AUTHKEY` → an already-persisted `/etc/headscale/authkey`.
     The reusable key (Headscale user `fleet`) is never stored in the repo; a
     local stash lives under the gitignored `provision/secrets/`. First enroll
     dies with a clear message if no key resolves from any source.
   - `ORCA_TS_HOSTNAME` — defaults to `wsl-<sanitized $WSL_DISTRO_NAME>`
     (lowercased, non-`[a-z0-9-]` → `-`, e.g. `Ubuntu-26.04` → `wsl-ubuntu-26-04`).
     Overridable via env for a custom name.

5b. **Zero-touch re-enroll (added 2026-07-16).** Persist the resolved key to
   `/etc/headscale/authkey` (`root:root 0600`) and install a systemd **system**
   oneshot `/etc/systemd/system/tailscale-autoconnect.service`:
   `After/Wants=tailscaled.service network-online.target`,
   `ConditionPathExists=/etc/headscale/authkey`, `Type=oneshot
   RemainAfterExit=true`,
   `ExecStart=/bin/sh -c 'tailscale status --peers=false >/dev/null 2>&1 ||
   tailscale up --login-server https://cc.cyphy.kz --authkey "$(cat
   /etc/headscale/authkey)" --hostname wsl-<distro>'`,
   `WantedBy=multi-user.target`. Hostname is baked at install (system units
   don't see `$WSL_DISTRO_NAME`). Runs as root → no interactive sudo at boot;
   idempotent — a normal reboot whose state persists in `/var/lib/tailscale` is
   a no-op (the `status` probe short-circuits), while a rebuilt/logged-out distro
   re-enrolls hands-free. **Accepted tradeoff:** a reusable key sits root-readable
   on disk; mitigation = use a key with an expiry and rotate it in Headscale.
6. **Verify** — `tailscale ip -4` returns a `100.64.x.y`; print it and the
   MagicDNS FQDN `<hostname>.fleet.mesh`.

`tailscaled` runs as a **system** service (needs root + tun). Enrolling a rebuilt
distro (`wsl --unregister` → re-provision) creates a fresh node; the old one goes
stale in Headscale — note that operators prune with `headscale nodes delete`.

### 2. `provision/orca-serve.sh` — install Orca + autostart the server

Depends on step 1 having produced a tailnet IP. Responsibilities:

1. **Preconditions** — Debian/Ubuntu + x86_64. Detect a tailnet IPv4
   (`tailscale ip -4`, or an addr in `100.64.0.0/10`). If none, die pointing at
   `tailscale-wsl.sh`.
2. **Electron runtime deps** — best-effort apt install of the shared libs an
   AppImage-bundled Electron app still needs from the system (`libnss3`,
   `libgbm1`, `libgtk-3-0`, `libasound2`, `libxshmfence1`, `libatk-bridge2.0-0`,
   etc.). Missing ones are the usual `libgbm.so.1: cannot open shared object`
   failure mode.
3. **Install Orca + extract the CLI (headless, no FUSE)**:
   - Download `orca-linux.AppImage` →
     `~/.local/opt/orca/orca-<version>.AppImage`. `ORCA_VERSION` env overrides;
     default `latest` (resolve + echo the real version — there is no Orca pin
     file in the repo, unlike `pkgs/gortex.nix`; noted as a deliberate deviation).
   - `chmod +x` then `--appimage-extract` (built-in, no FUSE, no root) →
     `~/.local/opt/orca/squashfs-root/`.
   - Locate the bundled `orca` executable inside `squashfs-root`
     (`find … -type f -name orca`). Symlink → `~/.local/bin/orca`. If only
     `AppRun` exists, write a `~/.local/bin/orca` wrapper that execs
     `AppRun "$@"` (with `--no-sandbox` if required).
   - **Verify checkpoint**: `orca --help` runs headlessly. If it demands a
     display, fall back to wrapping under `xvfb-run` and document the WSLg-once
     alternative.
4. **Autostart via systemd (user) + linger**:
   - Wrapper `~/.local/bin/orca-serve-start` computes the pairing address at
     start time: `orca serve --port 6768 --pairing-address "$(tailscale ip -4 | head -1)"`
     — so a changed node IP needs no unit edit. (Tailnet IP is default for
     reliability; the MagicDNS FQDN `<hostname>.fleet.mesh` is the friendlier
     alternative an operator can swap in.)
   - Unit `~/.config/systemd/user/orca-serve.service`: `Type=simple`,
     `ExecStart=%h/.local/bin/orca-serve-start`, `Restart=on-failure`,
     `RestartSec=5`, `WantedBy=default.target`.
   - `systemctl --user enable --now orca-serve.service` +
     `loginctl enable-linger "$(id -un)"` (keeps it up with no open session) —
     the same systemd-user + linger pattern `linux.sh` uses for git-autofetch.
     No-systemd fallback: warn + a manual `tmux`/`nohup orca-serve-start` hint
     (cron can't host a long-running foreground service).
5. **Output** — how to read the pairing URL
   (`journalctl --user -u orca-serve -f`), and next steps: on the Windows client
   / mobile, add the environment via the pairing code
   (`orca environment add --name <distro> --pairing-code '<orca://pair?…>'`).
   **The pairing URL is a secret — never commit it, never print it into the repo.**

## Secrets

- `HEADSCALE_AUTHKEY` — env only, at runtime. Not committed. (A local gitignored
  export or the shell's env; consistent with how the repo keeps secrets out of
  git.)
- The Orca **pairing URL** — grants access to the runtime; lives only in the
  distro's journal. Treated like a credential.

## Windows-side prerequisites (documented, not done by these Linux scripts)

- Tailscale on the host (already in the winget set) is **independent** in model
  (A) — WSL nodes reach the tailnet themselves. The host only needs Tailscale
  (with MagicDNS) if you want the Windows Orca client to resolve
  `*.fleet.mesh` names rather than raw `100.64.x.y`.
- No `.wslconfig` change required.

## Multi-distro usage

Run both scripts in each distro. Distro A → node `wsl-a` @ `100.64.x.a:6768`;
distro B → node `wsl-b` @ `100.64.x.b:6768`. Clients pair with each separately.

## Verification / testing

Infra bash — verification is by checkpoint, not unit tests:

1. `shellcheck provision/tailscale-wsl.sh provision/orca-serve.sh` clean.
2. Dry idempotency: second run of each is a no-op (all `✓ already …`).
3. Smoke test in a scratch distro (`Ubuntu-26.04`):
   - `tailscale-wsl.sh` → `tailscale ip -4` yields a `100.64.x.y`; node visible
     in `headscale nodes list` on the VPS.
   - `orca-serve.sh` → `orca --help` works; `systemctl --user is-active
     orca-serve` is `active`; `journalctl --user -u orca-serve` prints a pairing
     URL; the Windows client pairs and opens a terminal in the distro.
4. Two distros reachable simultaneously on their own IPs, port 6768 each.

## Out of scope (YAGNI)

- Wiring these into the `provision.sh` role dispatcher (standalone by choice).
- A PowerShell/`windows.ps1` companion for host Tailscale (already winget).
- An Orca version-pin file (`pkgs/orca.*`) — default `latest`; add later if the
  fleet needs lockstep.
- Automatic Headscale stale-node pruning after a distro rebuild (manual
  `headscale nodes delete`).
