# Headscale Fleet Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking. This plan is **ops, not TDD** — each task's "test" is a verification
> command with expected output, plus an explicit rollback.

**Goal:** Move the own fleet fully onto the Headscale tailnet — enroll g614jv,
cut the homeserver's public services off AmneziaWG onto the tailnet, remove the
homeserver's AWG spoke, and repoint SSH aliases + convention docs.

**Architecture:** Headscale (control plane + embedded DERP) is already live at
`cc.cyphy.kz`; VPS `100.64.0.1`, latitude `100.64.0.2`, homeserver `100.64.0.3`
are enrolled. The homeserver's Docker services already bind `0.0.0.0`, so they
are **already reachable on `100.64.0.3`** with no rebind. The migration is a
Caddy upstream repoint (`10.0.0.2` → `100.64.0.3`) with both tunnels coexisting
for zero-downtime rollback, then AWG removal, then cleanup.

**Tech Stack:** Headscale 0.29.2 / Tailscale 1.98.x, Caddy (+caddy-l4) on the
Debian VPS, Docker Desktop (WSL2) on the Windows homeserver, AmneziaVPN GUI on
homeserver, NixOS home-manager (`ssh.nix`) on the machines side.

## Global Constraints

- **AWG stays on the VPS** for relatives + friends' peers. Only the homeserver's
  own AWG *spoke* (`wg0-homeserver`, `10.0.0.2`) is removed. Never touch the VPS
  AWG hub or other peers.
- **Zero-downtime:** both AWG and Tailscale are up on the homeserver now. Keep
  `10.0.0.2` working until Caddy is verified on `100.64.0.3`; that verified state
  is the rollback anchor.
- **Caddy uses the tailnet IP `100.64.0.3`** (not MagicDNS) for determinism,
  matching the current `10.0.0.2` style. Headscale keeps node IPs stable.
- Homeserver services already listen on `0.0.0.0` (verified in the compose
  files) — **no container rebind/redeploy in this plan.**
- This session runs **on the homeserver** (`methe-server`). g614jv steps run on
  g614jv. VPS steps run over `ssh debian@cyphy.kz`. Caddy config is edited in the
  `~/my/vps` repo, pushed, then pulled+deployed on the VPS.
- The live VPS clone is `/home/debian/vps` (NOT `~/my/vps`); `manage-peers.sh` is
  at `/home/debian/vps/vps/manage-peers.sh` (iface is `wg0`, not `awg0`).

---

### Task 1: Enroll g614jv on the tailnet

Additive and reversible — g614jv keeps its AWG tunnel; Tailscale joins beside it.
**Runs on g614jv** (and a key-mint step on the VPS).

**Files:** none (imperative host config).

**Interfaces:**
- Consumes: Headscale at `https://cc.cyphy.kz`, user `fleet` (id 1).
- Produces: g614jv as a tailnet node (`100.64.0.4` expected) — a second NAT'd
  Windows node for later fleet use.

- [ ] **Step 1: Mint a reusable pre-auth key on the VPS**

Run:
```bash
ssh debian@cyphy.kz 'sudo headscale preauthkeys create --user 1 --reusable --expiration 1h'
```
Expected: a long key string on stdout. Copy it for Step 3.

- [ ] **Step 2: Install the Tailscale client on g614jv**

On g614jv (PowerShell):
```powershell
winget install -e --id Tailscale.Tailscale
```
Expected: "Successfully installed". (ID is case-sensitive; `-e` = exact.)

- [ ] **Step 3: Join the tailnet on g614jv**

On g614jv (elevated shell, `tailscale` = `C:\Program Files\Tailscale\tailscale.exe`):
```powershell
tailscale up --login-server https://cc.cyphy.kz --authkey <KEY-FROM-STEP-1>
```
Expected: returns to prompt with no error.

- [ ] **Step 4: Verify g614jv is on the tailnet**

On g614jv:
```powershell
tailscale status
tailscale ping vps-test
tailscale ping homeserver
```
Expected: `status` lists g614jv with a `100.64.0.x` address and shows the other
nodes; both `ping`s return `pong` (via DERP is fine).

- [ ] **Step 5: Confirm the node from the VPS**

Run:
```bash
ssh debian@cyphy.kz 'sudo headscale nodes list'
```
Expected: a `g614jv` row, online.

**Rollback:** on g614jv `tailscale down` (AWG untouched); optionally
`ssh debian@cyphy.kz 'sudo headscale nodes delete -i <id>'`.

---

### Task 2: Prove homeserver services are reachable over the tailnet (gate)

Read-only gate. If any service is unreachable on `100.64.0.3`, **stop** — do not
touch Caddy. Confirms Docker-on-Windows publishes `0.0.0.0` ports on the
Tailscale adapter.

**Files:** none.

**Interfaces:**
- Consumes: homeserver tailnet node `100.64.0.3`, its `0.0.0.0`-bound services.
- Produces: green light for Task 3.

- [ ] **Step 1: Confirm the homeserver's own tailnet state**

On the homeserver (PowerShell):
```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ip -4
& "C:\Program Files\Tailscale\tailscale.exe" status
```
Expected: `100.64.0.3` printed; status shows the node online, `vps-test` present.

- [ ] **Step 2: From the VPS, probe every service port on `100.64.0.3`**

Run:
```bash
ssh debian@cyphy.kz 'for p in 3000 2283 4533 2282 8084 9412; do \
  printf "%s -> " "$p"; \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://100.64.0.3:$p/ || echo UNREACHABLE; \
done; \
printf "2222 -> "; timeout 5 bash -c "</dev/tcp/100.64.0.3/2222" && echo OPEN || echo CLOSED'
```
Expected: each web port returns an HTTP status (`200`/`301`/`302`/`401`/`403` —
**any** number means reachable); `2222 -> OPEN`. A `000`/`UNREACHABLE`/`CLOSED`
on any port is a **stop** condition.

**Rollback:** none (read-only). If it fails: check the Windows Defender Firewall
rule for the Tailscale interface, and that Docker Desktop is running.

---

### Task 3: Repoint VPS Caddy to the tailnet IP and verify

The cutover. Both tunnels are up, so `10.0.0.2` still works throughout — reverting
one file is the rollback.

**Files:**
- Modify: `~/my/vps/vps/caddy/Caddyfile` (replace `10.0.0.2` → `100.64.0.3`,
  active blocks: layer4 `:2222` upstream, `git` 3000, `immich` 2283, `speed`
  2282, `qb` 8084, `navi` 4533, `tug` 9412; commented plex/emby/jfin blocks may
  be updated too, harmless).

**Interfaces:**
- Consumes: verified reachability from Task 2.
- Produces: all `*.cyphy.kz` served via the tailnet; `10.0.0.2` no longer used by
  Caddy (making Task 4 safe).

- [ ] **Step 1: Edit the Caddyfile**

Replace every `10.0.0.2` with `100.64.0.3` in `~/my/vps/vps/caddy/Caddyfile`.

- [ ] **Step 2: Commit and push (vps repo)**

```bash
cd ~/my/vps && git add vps/caddy/Caddyfile && \
git commit -m "caddy: repoint homeserver upstreams to tailnet 100.64.0.3" && git push
```

- [ ] **Step 3: Deploy on the VPS with a validate-first guard**

```bash
ssh debian@cyphy.kz 'cd /home/debian/vps && git pull && \
  sudo cp vps/caddy/Caddyfile /etc/caddy/Caddyfile && \
  sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
  sudo systemctl reload caddy && echo RELOADED'
```
Expected: `Valid configuration` then `RELOADED`. If validate fails, Caddy keeps
the running config — fix and retry (no outage).

- [ ] **Step 4: Verify every public service end-to-end**

```bash
for s in git immich speed qb navi tug; do \
  printf "%s -> " "$s"; \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 https://$s.cyphy.kz/ || echo FAIL; \
done
ssh -o BatchMode=yes -o ConnectTimeout=5 -p 2222 git@git.cyphy.kz 2>&1 | head -1
```
Expected: each subdomain returns its normal status (same codes as before the
change); the forgejo SSH probe returns Forgejo's banner/`PTY allocation`/`Permission
denied` line (i.e. the port answers), not a timeout.

**Rollback:** `git revert` (or restore `10.0.0.2`) in the Caddyfile, redeploy via
Step 3. AWG is still up, so recovery is immediate.

---

### Task 4: Remove AmneziaWG from the homeserver

Only after Task 3 is green and has soaked (services confirmed via the tailnet).
Removes the homeserver's AWG spoke on both ends.

**Files:** none in-repo (live tunnel + VPS peer state).

**Interfaces:**
- Consumes: Task 3 green (Caddy no longer needs `10.0.0.2`).
- Produces: homeserver reachable only via tailnet + LAN; `10.0.0.2` freed on the
  hub.

- [ ] **Step 1: Soak check — nothing still depends on `10.0.0.2`**

```bash
ssh debian@cyphy.kz 'sudo grep -n 10.0.0.2 /etc/caddy/Caddyfile || echo "caddy clean"'
```
Expected: `caddy clean`. (restic rides `server.lan:8001`, not the mesh — already
independent.)

- [ ] **Step 2: Stop the AmneziaVPN tunnel on the homeserver**

On the homeserver: open **AmneziaVPN**, disconnect and disable the
`wg0-homeserver` connection (GUI action). Confirm the AWG adapter is down:
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.0.0.2'
```
Expected: no output (the `10.0.0.2` address is gone).

- [ ] **Step 3: Remove the peer on the VPS hub**

```bash
ssh debian@cyphy.kz 'sudo /home/debian/vps/vps/manage-peers.sh remove wg0-homeserver && \
  sudo /home/debian/vps/vps/manage-peers.sh list'
```
Expected: `list` no longer shows `wg0-homeserver`; other peers (relatives,
`ilya-romanyuk`, `me-g614jv`, `nix-lat5520`) remain.

- [ ] **Step 4: Verify services survive with AWG gone**

```bash
for s in git immich navi; do \
  printf "%s -> " "$s"; curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 https://$s.cyphy.kz/; \
done
ssh debian@cyphy.kz 'ping -c1 -W2 10.0.0.2 >/dev/null 2>&1 && echo "STILL UP (unexpected)" || echo "10.0.0.2 down (expected)"'
```
Expected: services return normal codes; `10.0.0.2 down (expected)`.

**Rollback:** re-enable the AmneziaVPN tunnel on the homeserver. If Step 3 already
ran, the peer must be re-added — but the VPS mints a **new** key
(`manage-peers.sh add wg0-homeserver 10.0.0.2`), so re-import the fresh conf into
AmneziaVPN (key rotation caveat, per the fleet memory). Prefer rolling back at
Step 2 (before Step 3) when possible.

---

### Task 5: Repoint SSH access + update convention docs

Cleanup so the repos reflect the tailnet reality.

**Files:**
- Modify: `~/my/vps/CLAUDE.md` (the "bind to `10.0.0.2`" / "reachable only through
  the WireGuard tunnel" wording → tailnet `100.64.0.3`, note services bind
  `0.0.0.0` behind NAT).
- Modify: `~/my/vps/README.md` (same network description).
- Modify: `machines` SSH-over-mesh for the homeserver — repoint its host alias to
  the tailnet (MagicDNS name `homeserver` or IP `100.64.0.3`) in the source that
  feeds `modules/home/ssh.nix` (`fleet.json` / the generator). Keep the change
  homeserver-scoped; a fleet-wide SSH-over-tailnet move is a follow-up (latitude
  is already tailnet-only, so the whole `ssh.nix` mesh story wants migrating —
  out of scope here).

**Interfaces:**
- Consumes: Task 4 done.
- Produces: docs + `ssh homeserver` consistent with the tailnet.

- [ ] **Step 1: Update `vps/CLAUDE.md` + `README.md`**

Reword the network section: services run on the homeserver, published on
`0.0.0.0` and reached by the VPS over the **tailnet** at `100.64.0.3` (Headscale);
they are not publicly exposed because the homeserver sits behind NAT with no
port-forward. Note AWG is retained on the VPS only for relatives. Update the
"Adding a New Service" step 2 to point the Caddy block at `100.64.0.3:<port>`.

- [ ] **Step 2: Commit the vps doc changes**

```bash
cd ~/my/vps && git add CLAUDE.md README.md && \
git commit -m "docs: homeserver services reached over tailnet (100.64.0.3), not AWG" && git push
```

- [ ] **Step 3: Repoint the homeserver SSH alias (machines)**

Point `ssh homeserver` at the tailnet. Confirm the generated alias resolves and
connects:
```bash
ssh -o ConnectTimeout=5 homeserver 'hostname'
```
Expected: `methe-server` (or the box's hostname) over the tailnet path.

- [ ] **Step 4: Commit the machines change**

```bash
cd ~/machines && git add -A && \
git commit -m "ssh: reach homeserver over the tailnet (post-AWG-removal)" && git push
```

- [ ] **Step 5: Update the fleet memory rollout status**

In `~/machines/.claude/memory/project.md`, tick the rollout: g614jv on tailnet,
homeserver services on `100.64.0.3`, homeserver AWG removed. Commit.

**Rollback:** docs/SSH are non-load-bearing; `git revert` any commit.

---

## Follow-ups (out of scope, per the results doc)

- Enable **UPnP/PCP on the home router** so roaming machines reach the fixed
  homeserver directly instead of via DERP (highest-value; the CGNAT finding).
- **Fleet-wide SSH-over-tailnet:** migrate all of `ssh.nix` off AWG mesh IPs to
  MagicDNS (latitude is already tailnet-only).
- Declarative Windows Tailscale provisioning (fold into the `mesh-member` role).
- Drop g614jv's AWG once nothing needs it there.
- ACLs before the open mesh widens further.
