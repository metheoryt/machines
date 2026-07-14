# Headscale Fleet-Mesh Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Headscale + self-hosted embedded DERP on the VPS and validate it as the fleet transport by enrolling latitude (NixOS) and the homeserver (Windows), without disturbing any load-bearing service.

**Architecture:** Headscale (self-hosted Tailscale control server) runs on the VPS behind the existing Caddy at `cc.cyphy.kz`, with an embedded DERP relay. Fleet machines run the standard Tailscale client pointed at that login server, forming a dynamic WireGuard mesh (`100.64.0.0/10`) that is disjoint from — and coexists with — the existing AmneziaWG network (`10.0.0.0/24`). This is a validation probe: latitude drops its AWG spoke, the homeserver keeps AWG (it carries the public services) and runs Tailscale beside it.

**Tech Stack:** Headscale, Tailscale client, Caddy (already deployed), NixOS (`services.tailscale`), systemd, SQLite.

## Global Constraints

- **Headscale domain:** `cc.cyphy.kz` (server_url), fronted by existing Caddy. Copy verbatim.
- **Tailnet range:** `100.64.0.0/10` — must stay disjoint from AmneziaWG `10.0.0.0/24`.
- **DERP:** embedded in Headscale; Tailscale's public DERP map disabled (`derp.urls: []`) so all relayed traffic goes through our own relay. Fall back to standalone `derper` only if embedded misbehaves.
- **Do NOT touch** the homeserver's AmneziaWG tunnel (`10.0.0.2`) or the VPS's AmneziaWG hub (relatives). Both stay running.
- **Headscale config schema drifts between versions.** Every config block below is for Headscale 0.23+. After install, run `headscale version` and, if a sample fails to parse, reconcile keys against the installed version's `config-example.yaml` before proceeding. Do not fight a parse error blindly.
- **Execution is interactive**, driven from latitude with SSH to the VPS (`ssh debian@cyphy.kz`).
- **Secrets** (pre-auth keys, DERP/noise private keys) are never committed.

---

### Task 1: Headscale server on the VPS

**Files:**
- Create (on VPS, later committed to `~/my/vps`): `~/my/vps/vps/setup-headscale.sh`
- Create (on VPS, template committed): `~/my/vps/vps/headscale/config.yaml`

**Interfaces:**
- Produces: a running `headscale` systemd service listening on `127.0.0.1:8080`, embedded DERP STUN on UDP `3478`, ready for a reverse proxy. Consumed by Task 2 (Caddy) and Task 3 (users/keys).

- [ ] **Step 1: Install Tailscale + Headscale on the VPS**

SSH to the VPS and install both (Tailscale client is needed in Task 3 for the VPS's own self-join):

```bash
ssh debian@cyphy.kz
# Tailscale client (official script)
curl -fsSL https://tailscale.com/install.sh | sudo sh
# Headscale: fetch the latest .deb from GitHub releases
HS_VER=$(curl -fsSL https://api.github.com/repos/juanfont/headscale/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
echo "Installing headscale $HS_VER"
curl -fsSL -o /tmp/headscale.deb "https://github.com/juanfont/headscale/releases/download/v${HS_VER}/headscale_${HS_VER}_linux_amd64.deb"
sudo apt-get install -y /tmp/headscale.deb
headscale version
```

Expected: `headscale version` prints a version string (0.23+). The package creates `/etc/headscale/`, `/var/lib/headscale/`, and a `headscale.service` unit (not yet started/healthy — no config).

- [ ] **Step 2: Write the Headscale config**

Create `/etc/headscale/config.yaml`. Keep an in-repo copy at `~/my/vps/vps/headscale/config.yaml` (identical, no secrets — key *paths* only).

```yaml
server_url: https://cc.cyphy.kz
listen_addr: 127.0.0.1:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

# Embedded DERP relay. urls:[] drops Tailscale's public DERP map so ALL
# relayed traffic rides our own relay (worst-case path we want to validate).
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "cc"
    region_name: "cyphy embedded"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  urls: []
  paths: []
  auto_update_enabled: false
  update_frequency: 24h

# MagicDNS base domain — internal only, MUST NOT equal/parent server_url host.
dns:
  magic_dns: true
  base_domain: fleet.mesh
  nameservers:
    global:
      - 1.1.1.1
      - 9.9.9.9

log:
  level: info
```

- [ ] **Step 3: Open the STUN port and start the service**

DERP's STUN needs UDP 3478 reachable from the internet (TCP 443 is already open for Caddy). Open it with whatever firewall the VPS uses, then start Headscale:

```bash
# If ufw is active:
sudo ufw allow 3478/udp || true
# If nftables/iptables direct, add the equivalent accept for udp/3478.
sudo systemctl enable --now headscale
sudo systemctl status headscale --no-pager
```

Expected: `active (running)`. `sudo ss -ulnp | grep 3478` shows headscale bound on `0.0.0.0:3478`; `sudo ss -tlnp | grep 8080` shows it on `127.0.0.1:8080`.

- [ ] **Step 4: Verify the API answers locally**

```bash
curl -fsS http://127.0.0.1:8080/health
```

Expected: `{"status":"pass"}` (or HTTP 200). If it fails, check `journalctl -u headscale -e` for a config parse error and reconcile keys against `headscale` `config-example.yaml` per the Global Constraints note.

- [ ] **Step 5: Stage the setup script + config template in the vps repo**

Write `~/my/vps/vps/setup-headscale.sh` capturing Steps 1–3 as an idempotent script (guard installs with `command -v headscale`, `[ -f /etc/headscale/config.yaml ]` checks), matching the style of the neighbouring `setup-awg.sh`. Copy the config to `~/my/vps/vps/headscale/config.yaml`.

- [ ] **Step 6: Commit (vps repo)**

```bash
cd ~/my/vps && git checkout -b headscale-probe
git add vps/setup-headscale.sh vps/headscale/config.yaml
git commit -m "feat(vps): headscale server + embedded DERP setup (cc.cyphy.kz)"
```

---

### Task 2: Caddy front + DNS for `cc.cyphy.kz`

**Files:**
- Modify: `~/my/vps/vps/caddy/Caddyfile`

**Interfaces:**
- Consumes: Headscale on `127.0.0.1:8080` (Task 1).
- Produces: public HTTPS endpoint `https://cc.cyphy.kz` terminating TLS and proxying to Headscale (incl. the embedded-DERP HTTP endpoint). Consumed by every client join (Tasks 3–5).

- [ ] **Step 1: Create the DNS A record**

At your DNS provider, add `cc.cyphy.kz` → the VPS public IP (same IP `cyphy.kz` resolves to). Verify:

```bash
dig +short cc.cyphy.kz
```

Expected: the VPS public IP. Wait for propagation before Step 3.

- [ ] **Step 2: Add the Caddy block**

Append to `~/my/vps/vps/caddy/Caddyfile`:

```
cc.cyphy.kz {
	reverse_proxy 127.0.0.1:8080
}
```

Headscale + embedded DERP work through a plain `reverse_proxy` (DERP rides the same HTTPS host; STUN is the separate UDP 3478 from Task 1). If DERP later shows connection issues, revisit header/flush settings — not expected for the probe.

- [ ] **Step 3: Deploy the Caddyfile and reload**

```bash
cd ~/my/vps && cp vps/caddy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
sleep 3
curl -fsS https://cc.cyphy.kz/health
```

Expected: `{"status":"pass"}` over HTTPS (Caddy has fetched a cert for `cc.cyphy.kz` and is proxying). If cert issuance fails, confirm DNS from Step 1 has propagated.

- [ ] **Step 4: Commit (vps repo)**

```bash
cd ~/my/vps
git add vps/caddy/Caddyfile
git commit -m "feat(vps): route cc.cyphy.kz to headscale via Caddy"
```

---

### Task 3: User, pre-auth key, and VPS self-join (first end-to-end proof)

**Files:** none (runtime state on the VPS).

**Interfaces:**
- Consumes: healthy `https://cc.cyphy.kz` (Task 2).
- Produces: a reusable pre-auth key (used by Tasks 4–5) and the VPS as tailnet node `cyphy-hub` — the fixed public endpoint the other nodes test against.

- [ ] **Step 1: Create the fleet user**

```bash
ssh debian@cyphy.kz
sudo headscale users create fleet
sudo headscale users list
```

Expected: a `fleet` user with an ID. Note the ID (newer Headscale takes `--user <id>` numeric).

- [ ] **Step 2: Mint a reusable pre-auth key**

```bash
sudo headscale preauthkeys create --user fleet --reusable --expiration 24h
```

Expected: a long key string. Copy it — it authenticates Tasks 4 and 5. (If `--user fleet` errors, use the numeric ID from Step 1.)

- [ ] **Step 3: Join the VPS to its own tailnet**

```bash
sudo tailscale up --login-server https://cc.cyphy.kz --authkey <KEY> --hostname cyphy-hub --accept-routes=false
sudo tailscale status
```

Expected: `tailscale status` shows `cyphy-hub` with a `100.x.y.z` address.

- [ ] **Step 4: Confirm registration on the control side**

```bash
sudo headscale nodes list
```

Expected: `cyphy-hub` listed, user `fleet`, online. This proves the control plane, cert, reverse proxy, and client registration all work end to end. **Gate: do not proceed until this passes.**

---

### Task 4: latitude — drop AWG, enable Tailscale, join

**Files:**
- Modify: `hosts/latitude5520/nixos/configuration.nix:84-87` (disable meshVpn) and add `services.tailscale`.

**Interfaces:**
- Consumes: the pre-auth key (Task 3).
- Produces: latitude as tailnet node with `awg0` gone — a NAT'd NixOS endpoint for the NAT-to-NAT and LAN-direct tests.

- [ ] **Step 1: Record the pre-state (for the route/rollback check)**

On latitude:

```bash
ip -brief link | grep -E 'awg0|tailscale' || echo "no awg0/tailscale yet"
ip route | grep 10.0.0.0/24 || echo "no 10.0.0.0/24 route"
```

Expected: `awg0` present with a `10.0.0.0/24` route (the current spoke). Note it — Step 4 confirms it's gone.

- [ ] **Step 2: Disable meshVpn and enable Tailscale in latitude's config**

Edit `hosts/latitude5520/nixos/configuration.nix`. Change the `fleet.meshVpn` block (lines 84-87) from `enable = true;` to `enable = false;` (keep the block for reversibility), and add a Tailscale line nearby:

```nix
  # AmneziaWG mesh spoke — DISABLED for the Headscale probe (2026-07-13).
  # Re-enable by flipping to true; nothing load-bearing rides latitude's awg0.
  fleet.meshVpn = {
    enable = false;
    address = "10.0.0.8/32";
  };

  # Headscale/Tailscale fleet transport (probe). Joined imperatively with
  # `tailscale up --login-server https://cc.cyphy.kz` after switch.
  services.tailscale.enable = true;
```

- [ ] **Step 3: Rebuild**

```bash
sudo nixos-rebuild switch --flake ~/machines#latitude5520
```

Expected: build succeeds; `tailscaled` is now running (`systemctl status tailscaled`).

- [ ] **Step 4: Confirm awg0 is gone (default networking restored)**

```bash
ip -brief link | grep awg0 || echo "awg0 gone — good"
ip route | grep 10.0.0.0/24 || echo "no 10.0.0.0/24 route — good"
```

Expected: both print the "good" fallbacks. latitude now has plain ISP networking + `tailscaled`.

- [ ] **Step 5: Join the tailnet**

```bash
sudo tailscale up --login-server https://cc.cyphy.kz --authkey <KEY> --hostname latitude
sudo tailscale status
```

Expected: `latitude` gets a `100.x` address; `cyphy-hub` visible as a peer.

- [ ] **Step 6: First reachability test (latitude ↔ VPS)**

```bash
tailscale ping cyphy-hub
ssh debian@$(tailscale ip -4 cyphy-hub)
```

Expected: `tailscale ping` returns a pong (note whether `via DERP(cc)` or `direct`); SSH to the VPS over the tailnet succeeds. **This satisfies spec validation items 1 and 3.**

- [ ] **Step 7: Commit (machines repo)**

```bash
cd ~/machines && git checkout -b headscale-probe
git add hosts/latitude5520/nixos/configuration.nix
git commit -m "feat(latitude): disable awg0 spoke, enable Tailscale for Headscale probe"
```

---

### Task 5: homeserver — Tailscale beside AWG (services untouched)

**Files:** none in-repo (manual Windows install this increment).

**Interfaces:**
- Consumes: the pre-auth key (Task 3).
- Produces: the homeserver as a second NAT'd tailnet node, enabling NAT-to-NAT, LAN-direct, and RustDesk tests — with its `10.0.0.2` AWG service tunnel intact.

- [ ] **Step 1: Record the pre-state route table (the safety check)**

On the homeserver (PowerShell, admin):

```powershell
Get-NetRoute -DestinationPrefix "10.0.0.0/24" | Format-Table -Auto
```

Expected: the existing AWG route to `10.0.0.0/24`. Screenshot/note it — Step 4 confirms it is unchanged.

- [ ] **Step 2: Install the Tailscale client**

```powershell
winget install --id tailscale.tailscale -e
```

Expected: Tailscale installs. Do NOT sign in to the default Tailscale SaaS.

- [ ] **Step 3: Join our Headscale tailnet**

```powershell
tailscale up --login-server https://cc.cyphy.kz --authkey <KEY> --hostname homeserver
tailscale status
```

Expected: `homeserver` gets a `100.x` address; `latitude` and `cyphy-hub` visible.

- [ ] **Step 4: Confirm the service tunnel is untouched (critical)**

```powershell
Get-NetRoute -DestinationPrefix "10.0.0.0/24" | Format-Table -Auto
```

Expected: identical to Step 1 — Tailscale added a `100.64.0.0/10` route on its own interface and did NOT alter the `10.0.0.0/24` AWG route. Then confirm a public service is still live:

```powershell
curl.exe -fsS -o NUL -w "%{http_code}" https://immich.cyphy.kz
```

Expected: `200` (or the service's normal redirect code). **Gate: if the 10.0.0.0/24 route changed or the service is down, run `tailscale down` and stop — do not continue until the coexistence is clean.**

---

### Task 6: Run the validation matrix and record results

**Files:**
- Create: `docs/superpowers/plans/2026-07-13-headscale-probe-results.md` (findings log)

**Interfaces:**
- Consumes: all three nodes online (Tasks 3–5).
- Produces: a pass/fail record against the spec's validation checklist — the decision input for a fleet-wide rollout.

- [ ] **Step 1: NAT type per ISP (spec item 2)**

On latitude and the homeserver:

```bash
tailscale netcheck
```

Record, for each: the reported **NAT mapping/filtering** (easy/hard/symmetric), whether UDP works, and nearest DERP latency. This predicts how often each ISP rides direct P2P vs. DERP.

- [ ] **Step 2: NAT-to-NAT hole-punch (spec item 4)**

With latitude and the homeserver on **different** networks (e.g. latitude on a phone hotspot), from latitude:

```bash
tailscale ping homeserver
```

Expected/record: whether it reaches `direct` (hole-punch worked) or stays `via DERP(cc)`. Either is a valid finding — record which.

- [ ] **Step 3: LAN-direct (spec item 5)**

With latitude and the homeserver on the **same home WiFi**, from latitude:

```bash
tailscale ping homeserver
```

Expected: `direct` over the LAN address (a `192.168.x.x` endpoint in `tailscale status --peers`), not relayed.

- [ ] **Step 4: Forced DERP through our relay (spec item 6)**

The very first `tailscale ping` after a path resets pongs `via DERP(cc)` before upgrading. To observe our relay explicitly, from latitude:

```bash
tailscale ping --tsmp homeserver     # or: tailscale debug watch-ipn while pinging
tailscale status                     # peer 'relay' column should read "cc" when relayed
```

Because `derp.urls: []` leaves only our region, any relayed pong = traffic through our embedded DERP. Record that a relayed pong via `cc` was observed.

- [ ] **Step 5: RustDesk over the tailnet (spec item 7)**

On the homeserver: RustDesk → Settings → Security → enable **Direct IP Access**, set a permanent password. From latitude's RustDesk, connect by IP to the homeserver's `100.x` (from `tailscale ip -4 homeserver`). Verify the session connects. If both are on the same LAN, confirm it uses the LAN path (fast).

- [ ] **Step 6: Write the results log and commit**

Fill `docs/superpowers/plans/2026-07-13-headscale-probe-results.md` with a table: each spec validation item → observed result → pass/fail, plus the recorded NAT types. State the go/no-go for a fleet-wide rollout.

```bash
cd ~/machines
git add docs/superpowers/plans/2026-07-13-headscale-probe-results.md
git commit -m "docs(probe): Headscale fleet-mesh probe results + rollout decision"
```

---

## Rollback

- **latitude:** flip `fleet.meshVpn.enable` back to `true`, remove `services.tailscale.enable`, `sudo tailscale down`, `nixos-rebuild switch`. awg0 returns.
- **homeserver:** `tailscale down`; uninstall Tailscale if desired. AWG service tunnel was never touched.
- **VPS:** `sudo systemctl disable --now headscale`; remove the `cc.cyphy.kz` Caddy block + reload; `sudo tailscale down`. AmneziaWG hub untouched throughout.

## Verification (end-to-end)

The probe passes when Task 3 Step 4, Task 4 Step 6, and Task 6 Step 4 all succeed (control plane + latitude↔VPS SSH + relay through our DERP), with NAT-to-NAT (Task 6 Step 2), LAN-direct (Step 3), and RustDesk (Step 5) each observed at least once and recorded. The homeserver safety gate (Task 5 Step 4) must be green throughout.
