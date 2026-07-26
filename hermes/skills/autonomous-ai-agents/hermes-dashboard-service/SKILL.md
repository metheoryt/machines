---
name: hermes-dashboard-service
description: Run hermes serve as a systemd user service on Linux/WSL.
version: 1.0.0
platforms: [linux, wsl]
metadata:
  hermes:
    tags: [hermes, dashboard, systemd, service, headless, wsl]
    related_skills: [hermes-dashboard-remote]
---

# Hermes Dashboard — Systemd Service

Deploy `hermes serve` as a persistent systemd user service that auto-starts on boot and survives terminal closes. Pair with `hermes-dashboard-remote` for the full Desktop-app remote-backend setup.

## When to Use

- WSL: keep `hermes serve` running even when no terminal is open
- Headless server/VPS: auto-start on boot, auto-restart on crash
- Any Linux box where you want the backend up before you log in

## Prerequisites

Basic auth must be configured in `~/.hermes/.env` before enabling the service (see `hermes-dashboard-remote` for the env vars). The service binds to `0.0.0.0:9119` — without auth, anyone on the network can reach it.

On WSL, enable linger so the user manager runs without an active session:

```bash
sudo loginctl enable-linger $USER
```

## Service File

Create `~/.config/systemd/user/hermes-serve.service`:

```ini
[Unit]
Description=Hermes Agent backend server (headless)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/hermes serve --host 0.0.0.0 --port 9119 --skip-build --no-open
Restart=on-failure
RestartSec=5
Environment=HOME=%h
Environment=HERMES_HOME=%h/.hermes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Key flags:
- `hermes serve` — headless JSON-RPC/WebSocket gateway (no browser, no web UI build). Use this instead of `hermes dashboard` for systemd.
- `--host 0.0.0.0` — bind to all interfaces so the Desktop app can reach it
- `--skip-build` — skip the npm web UI build (not needed for the headless gateway; avoids npm dependency in systemd context)
- `--no-open` — don't try to open a browser

## Enable and Start

```bash
systemctl --user daemon-reload
systemctl --user enable --now hermes-serve.service
```

## Verify

```bash
systemctl --user status hermes-serve
# Should show: Active: active (running)

curl -s http://localhost:9119/api/status | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['auth_providers'] == ['basic'], 'auth gate not engaged'
print(f'OK v{d[\"version\"]} auth={d[\"auth_providers\"]}')
"
```

## Port Conflict Debugging

If the service fails with `address already in use`, a leftover `hermes serve` or `hermes dashboard` process is holding port 9119.

**Diagnose:**

```bash
# Find what's on port 9119
ss -tlnp | grep 9119
# LISTEN 0  2048  0.0.0.0:9119  0.0.0.0:*  users:(("hermes",pid=12345,fd=9))

# Identify the process
ps -p 12345 -o pid,args
```

**Fix:**

```bash
systemctl --user stop hermes-serve.service
# Kill the leftover process holding the port
kill $(ss -tlnp | grep 9119 | grep -oP 'pid=\K[0-9]+')
sleep 2
systemctl --user reset-failed hermes-serve.service
systemctl --user start hermes-serve.service
```

Common causes of port conflicts:
- Ad-hoc `hermes serve &` or `hermes dashboard &` from a shell that was never killed
- A previous systemd instance that wasn't fully stopped before a config change
- Running both `hermes serve` and `hermes dashboard` on the same port

## Troubleshooting

- **Service starts then dies silently**: check logs — `journalctl --user -u hermes-serve.service -n 50`
- **Service exits code 1 with no clear error**: almost always a port conflict — see §Port Conflict Debugging above
- **API reachable but Desktop says "auth_required: false"**: env vars aren't loaded. The systemd service reads `~/.hermes/.env` on its own — verify the vars are set there, not just in your shell session
- **Service works from shell but fails under systemd**: check that `hermes` is at `~/.local/bin/hermes` (the `%h` in the unit file expands to `$HOME`). Run `which hermes` to confirm
