---
name: hermes-dashboard-remote
description: Connect Hermes Desktop to a remote dashboard via basic auth.
version: 1.1.0
platforms: [linux, macos, windows, wsl]
metadata:
  hermes:
    tags: [hermes, dashboard, remote, desktop, wsl, auth]
---

# Hermes Dashboard — Remote Desktop Backend

Set up `hermes dashboard` as a remote backend so Hermes Desktop (on another machine) can connect to it. The desktop app talks to the dashboard over HTTP/WebSocket — all sessions, memory, tools, and gateway run on the backend host.

## When to Use

- Connecting Windows Hermes Desktop to a WSL2 Hermes instance
- Running Hermes on a headless server/VPS and using Desktop from a laptop
- Homelab box or Mini PC running Hermes, desktop app elsewhere

## Quick Setup

### 1. Configure basic auth on the backend

Basic auth MUST be set via **environment variables**, not config.yaml keys. Config keys alone will NOT engage the auth gate — the dashboard will show `auth_required: false` and Desktop will never present a Sign-in form.

Add to `~/.hermes/.env`:

```bash
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<user>
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<pass>
# Generate a token-signing secret:
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
```

Then verify the gate is engaged before trying Desktop:

```bash
hermes dashboard --host 0.0.0.0 --port 9119 --no-open &
sleep 3
curl -s http://localhost:9119/api/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'auth_required={d[\"auth_required\"]} providers={d[\"auth_providers\"]}')"
# Must show: auth_required=True providers=['basic']
```

If it shows `auth_required: false` or missing `"basic"`, the env vars aren't being picked up — the dashboard may have been started without them in its environment. Restart your shell or `source ~/.hermes/.env` and try again.

### 2. Start the dashboard (bind to non-loopback)

```bash
hermes dashboard --host 0.0.0.0 --port 9119 --no-open
```

Binding to a non-loopback address engages the auth gate. Without `--host 0.0.0.0` (or the machine's real IP), the dashboard binds only to 127.0.0.1 and remote connections are rejected.

### 3. Connect from Hermes Desktop

On the Desktop machine: **Settings → Gateway → Remote gateway**:
- **Remote URL**: `http://<backend-host>:9119`
- Click **Sign in** → enter the username and password from step 1
- **Save and reconnect**

The desktop app is now a UI shell; all agent logic runs on the backend.

## WSL2 → Windows Specifics

WSL2 forwards localhost automatically. When the dashboard runs inside WSL bound to `0.0.0.0:9119`, Windows can reach it at `http://localhost:9119`. No WSL IP or port forwarding needed.

Verify reachability from Windows:
```powershell
curl http://localhost:9119/api/status
```

## Pitfalls

- **Basic auth requires env vars, not config.yaml**: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `PASSWORD` / `SECRET` in `~/.hermes/.env` engages the gate. The `dashboard.basic_auth.*` config.yaml keys alone will NOT work — the dashboard will start with `auth_required: false`. This is the #1 cause of "Desktop asks for a session token instead of username/password."
- **Verify the gate before trying Desktop**: curl `/api/status` and confirm `auth_required: true` and `auth_providers: ["basic"]`. If these aren't set, Desktop's "remote backend is ready" probe passes (it only checks `/api/status` existence) but Sign-in will fail or show the wrong flow.
- **Dashboard must stay running**: the desktop app depends on the dashboard process. If you close the terminal or the backend host goes down, the desktop app loses its connection. Consider running `hermes dashboard` as a background service on the backend.
- **Password in plaintext**: `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` is plaintext in `.env`. For production, use `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` instead (compute with the hash utility from `plugins/dashboard_auth/basic`).
- **Dashboard ≠ Gateway**: the dashboard (what Desktop connects to) and the gateway (what Telegram/Discord/etc. connect to) are separate processes. Run `hermes gateway run` independently if you use messaging platforms. Do NOT run the gateway on both machines with the same bot token — they'll fight over updates.
- **Port conflicts**: default dashboard port is 9119. If already in use, pick another with `--port`.
- **Desktop "session token" prompt = auth gate not engaged**: if Desktop asks for a session token instead of username/password, the dashboard's auth gate didn't fire. Re-check the env vars and the `/api/status` response.
