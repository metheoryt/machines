# Statusboard → metrics stack + Grafana kiosk (design, 2026-09-09)

**Decision.** Retire the homegrown status board. Its probing and rendering move to
`node_exporter` + `smartctl_exporter` + cAdvisor + Prometheus + Grafana; the physical
display keeps the cage session it already has and runs `chromium --kiosk` where it
currently runs `foot`. Three facts no exporter knows stay ours, as a textfile
collector.

Measured feasibility is `docs/2026-09-09-grafana-spike.md` — every metric claim below
was verified on g15 and is not restated here. What that spike did **not** cover: the
tailnet/fleet slice (`sb_reach`, `sb_rtt_tenths`, `sb_fleet_join`, `sb_fleet_alerts`),
which is **out of scope** for this design and comes back later as a
`blackbox_exporter` job. Dropping it is a deliberate, accepted loss of function.

## What is actually being replaced

`statusboard.service` — the *text* board on a Linux VT — is already `disabled` and
`inactive` on latitude. What paints tty1 today is the cage→foot→tmux GUI board. So this
change swaps one client inside an existing Wayland kiosk. It is not a display-stack
change.

## Why every exporter is a container, including the packaged one

trixie ships `prometheus-node-exporter` (1.9.0-1+b4) and this design does **not** use
it. Its systemd unit runs as user `prometheus`, which cannot read
`/sys/class/powercap/intel-rapl:*/energy_uj` (0400 root) — so RAPL would be lost and
`tier_rapl_read`, which chgrps those files at every boot and resume, would have to
stay. A root container reads them directly, and that tier retires.

The obvious objection — a monitoring stack in Docker on the box it monitors dies with
Docker — is **already true of the board being replaced**: `sb_docker` shells out to the
Docker CLI, and the browser will hit a Grafana that is itself a container. One failure
domain, unchanged by this design. Recorded here so it is not re-litigated as a
discovery.

## Layout: which repo owns what

The boundary is the documented one — `machines` owns machines, `vps` owns services —
and the precedent is exact: the restic REST **server** container is in `vps`, the restic
**client** profiles are in `machines`.

**`vps` — `homeserver/monitoring/compose.yml`** (house style: one dir per service,
`extends` `homeserver/compose.base.yml`, ports published on `0.0.0.0:<port>` for tailnet
reach behind NAT):

| container | notes |
|---|---|
| `prometheus` | scrape config + retention; the only stateful one |
| `grafana` | provisioned datasource + dashboards, no hand-clicked state |
| `node-exporter` | `user: root`, `pid: host`, `/:/host:ro,rslave`, collectors `rapl hwmon thermal_zone textfile` |
| `smartctl-exporter` | `privileged: true`; **not packaged in trixie, so this pins an image tag** |
| `cadvisor` | `privileged: true`, `/var/lib/docker:ro` |

**`machines`:**

- `provision/metrics/node-textfile.sh` — the collector for the three fleet-specific
  facts, plus its per-host disk map.
- `provision/statusboard/grafana-kiosk.sh` — the cage→chromium kiosk.
- `provision/lib/tiers.sh` — `tier_statusboard` gains chromium; loses foot/tmux/btop
  and `tier_rapl_read` in commit 2.

Commit 1 spans both repos. Both are checked out on g15 and latitude at `~/my/vps`.

## The three facts that stay ours

No exporter has them, and each is a real operational fact rather than a nicety:

1. **The charge window.** The power_supply collector exports no
   `charge_control_end_threshold` / `_start_threshold` — the exact values
   `tier_battery_limit` writes.
2. **Bay naming.** UUID → "dock 1 upper", from `disks.latitude5520.conf`.
3. **Expected-but-unmounted.** No exporter has the concept of a mount that *should* be
   there. This is the one that catches the flaky dock, and the dock has already cost
   this box two silent multi-day outages.

### Collector contract

`provision/metrics/node-textfile.sh` writes one `.prom` file atomically (write to
`.prom.$$`, then `mv` — node_exporter reads whatever is there and a half-written file
is a parse error) into the textfile directory the node-exporter container binds. On a
systemd timer, because it needs host tools the container lacks (`findmnt`, `blkid`,
`lsblk`) and `/usr/sbin` is absent from a non-interactive ssh PATH.

Metrics it emits:

```
fleet_disk_bay{device,bay,dock,uuid}         1
fleet_mount_expected{mountpoint,bay}         1 present / 0 absent
fleet_battery_charge_threshold{bound="start|end"}  <percent>
```

`fleet_disk_bay` is a label carrier: dashboards join it on with
`group_left(bay,dock)` to put a human bay name on a `smartctl_device_*` or
`node_disk_*` series. That join is the whole reason bay naming survives as data rather
than as rendering code.

## The kiosk

`sbg_kiosk_argv` is `cage -s -d -- foot … -e <cmd>`. The replacement is
`cage -s -d -- chromium --kiosk --ozone-platform=wayland <url>`, and everything between
`foot` and the board disappears with it: `sbg_tmux_conf_text`, `sbg_tmux_term`,
`sbg_pty_size`, `sbg_board_argv`, `sbg_session_argv`, `--session` mode, the btop strip
and its config.

**What must be copied over unchanged, and why** — these are the parts of the existing
749 lines that encode hardware and systemd facts, not rendering:

- The **autologin getty drop-in**. cage must hold a logind seat to become DRM master on
  `/dev/dri/card0`; a plain `User=me` system service has no seat. The drop-in must clear
  `ExecStart=` first and must **not** pass agetty `-o`, which produced a hung
  `/bin/login -p --` with no autologin at all.
- The **`/etc/profile.d` hook**, with all three guards: only `/dev/tty1` (`/etc/profile`
  is read by `ssh -t` and `su -l` too), bail if `WAYLAND_DISPLAY`/`DISPLAY` is already
  set, and check the script exists (a freshly imaged box may have no checkout). It runs
  the kiosk **without `exec`** on purpose: `exec` would end the login session when the
  compositor dies, respawning the getty in a spin loop, where falling through leaves the
  error on screen with a shell under it.
- **`cage -s`** — VT switching stays enabled. Without it a compositor owning tty1
  swallows Ctrl-Alt-F2 and the only console on the box is unreachable from the box.

New, and chromium-specific: `--noerrdialogs --disable-infobars
--check-for-update-interval=31536000 --password-store=basic` and a `--user-data-dir`
under `/run/user/<uid>`, so a kiosk that is power-cut does not come back with a
"restore pages?" bar over the dashboard.

## Grafana

- **Auth: anonymous `Viewer`, plus a real admin password.** The spike used anonymous
  `Admin`, which is wrong here: the port is published on `0.0.0.0` for tailnet reach and
  this host has no firewall (`iptables -P INPUT ACCEPT`), so the home LAN — guests
  included — can reach it. Viewer makes that read-only; the kiosk needs no more.
- **Page rotation is a Grafana playlist in kiosk mode** (`/playlists/play/<uid>?kiosk`).
  That is the replacement for `sb_page_advance` (149 lines) and `sb_page_tabs`, at zero
  lines of ours.
- **Dashboards are provisioned from JSON in the repo**, never hand-edited in the UI —
  same argument as `install-timers.sh` copying units instead of symlinking them: a
  `git pull` must not silently change what the display shows.
- Dashboard **1860** ships patched. Its only CPU-temperature panel errors on any box
  where one hwmon chip registers two `chip_name` values (measured on the ASUS box:
  `platform_asus_nb_wmi` → `asus` + `asus_custom_fan_curve`), because the panel's
  `* on(chip) group_left(chip_name)` demands uniqueness. Fix: wrap the right-hand side
  in `max by (chip, chip_name)(…)`. Dashboard **22604** ships as-is. **20204** and
  **24629** are rejected — the first hardcodes someone's own device and IP, the second
  is written for nct6775 desktop boards.

## Sequencing

**Commit 1 — prove. Nothing is deleted.**

1. `vps`: `homeserver/monitoring/` — compose, `prometheus.yml`, Grafana provisioning,
   the two dashboard JSONs.
2. `machines`: `provision/metrics/node-textfile.sh`; `provision/statusboard/grafana-kiosk.sh`;
   chromium added to `tier_statusboard`; the collector's systemd timer in
   `hosts/latitude/debian/` alongside the existing ones, installed by `install-timers.sh`
   (which **copies** units into `/etc/systemd/system` rather than symlinking, so a pull
   cannot change what root runs on a timer without review).
3. Two new suites (below).
4. On latitude: `sudo bash grafana-kiosk.sh --install`. That rewrites the same
   `/etc/profile.d` hook path the current board uses — which is what makes the switch and
   the revert the same shape.

`disks.latitude5520.conf` does **not** move in commit 1. The collector reads it where it
sits. A move plus a new consumer in one change makes the revert harder for no gain.

**Commit 2 — delete, once the kiosk has held up.** `statusboard.sh` (3,044),
`statusboard-gui.sh` (749), `statusboard.test.sh` (1,386), `statusboard-gui.test.sh`
(436), `tier_rapl_read`, and `foot`, `foot-terminfo`, `tmux`, `ncurses-term` and `btop` from
`tier_statusboard` — `cage` stays, chromium needs it.
`disks.latitude5520.conf` moves to `provision/metrics/`. On the box:
`systemctl disable statusboard.service` is already the state, so nothing to undo there —
but the unit file itself must be removed by hand, since nothing in the repo installs it.

`smartmontools` stays in the tier: the container bundles its own `smartctl`, but the host
copy is what a human uses to check a disk by hand, and it is the only route to a
temperature on a USB-attached drive.

**Rollback from commit 1 is one command:** `sudo bash statusboard-gui.sh --install`,
which rewrites the hook back to the foot/tmux chain. This is the entire reason the change
is split in two.

## Tests

The 1,822-line suite loses most of its target, which is the point of the initiative — but
not all of it, and the remainder keeps the property that made it worth having: hardware
truth as executable assertions.

- `provision/tests/metrics-textfile.test.sh` — sources the collector with a `LIB_ONLY`
  guard (the same architecture that made a battery meter testable on a mac) and asserts
  its `.prom` output from fixtures: a disk map parsed into `fleet_disk_bay` labels, an
  absent expected mount emitting `0` rather than being omitted, label values escaped, and
  the atomic-rename path.
- `provision/tests/grafana-kiosk.test.sh` — asserts the kiosk argv (`cage -s` present, one
  argument per line), the getty drop-in text (`ExecStart=` cleared, no `-o`), and all
  three guards in the profile.d hook.

## Facts preserved from things being deleted

`statusboard.service` is **untracked** — it exists only on latitude and nothing in this
repo writes it. After commit 2 there would be no record that tty1 was ever driven by a
text board, or of the trap in doing so. Captured here before deletion:

- `Conflicts=getty@tty1.service`, `TTYPath=/dev/tty1`, `StandardInput=tty`,
  `ProtectSystem=strict`, `ProtectHome=read-only`, `Restart=always`.
- **`SupplementaryGroups=tty` is required, and its absence is why the first install left a
  dead console.** `/dev/tty1` is `root:tty` mode 620; a getty normally chowns it to
  whoever logs in, so with the getty stopped an unprivileged service simply cannot open
  it. The unit failed to start, the getty was already disabled, and tty1 was left with a
  blinking cursor and no way in.

That is the shape any future "put something on a VT as a non-root user" work needs, and
it is not re-derivable from the code being deleted.

## Out of scope

- The tailnet/fleet slice (`blackbox_exporter`) — named above, deliberately deferred.
- g15 and the other fleet members. This design provisions latitude only. The exporters
  are per-host and generalise, but a second scrape target is a separate change.
- Alerting. Prometheus makes it possible for the first time; nothing here configures it.
- Retention tuning. Prometheus defaults until there is a measured reason.
