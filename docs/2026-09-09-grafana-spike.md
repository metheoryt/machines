# Spike: can the metrics stack replace the statusboard? (2026-09-09)

**Question.** The statusboard is 3,856 lines of ours plus a 1,822-line suite. Its
content looked like the standard `node_exporter` + `smartctl_exporter` surface. Does
it actually map, and do the published community dashboards render it?

**Answer: yes for the hardware half, with three named gaps and one real bug in the
most-recommended dashboard.** Throwaway stack ran on **g15 only** — nothing was
installed on latitude, nothing was added to the repo but this file.

Stack (scratchpad, `docker compose`, deleted after): `prom/prometheus:v3.13.3`,
`grafana/grafana-oss:13.0.2`, `node-exporter:v1.9.1` (rapl + hwmon + thermal_zone +
textfile), `smartctl-exporter:v0.14.0`, `cadvisor:v0.55.1`.

## What maps, measured on the box

| board mechanism | replacement | verified |
|---|---|---|
| `sb_rapl_watts`, `sb_rapl_pick` | `node_rapl_package_joules_total` | yes, live value |
| `sb_battery_line`, `sb_source_watts` | `node_power_supply_{capacity,voltage_volt,current_ampere,energy_watthour,info{status}}` | yes |
| `sb_uwatts` / `sb_uwatthours` | PromQL `current_ampere * voltage_volt` — the collector exports whatever `/sys` files exist, so latitude's Dell (no `power_now`) still yields a wattage | metric shape yes; Dell arithmetic is a recording rule |
| `sb_hwmon_temp`, `sb_temp_cell` | `node_hwmon_temp_celsius` × `node_hwmon_chip_names` | yes — 8 sensors |
| `sb_smart_temp` | `smartctl_device_temperature` | yes |
| `sb_smart_asleep` | **upstream default** `--smartctl.powermode-check=standby` | yes, in `--help` |
| `sb_apm_parks`, `sb_drive_parks` | `smartctl_device_attribute{attribute_name="Load_Cycle_Count",attribute_value_type="raw"}` | metric confirmed in use by dash 22604; **not** verifiable here — g15 is NVMe-only, no ATA attribute table |
| `sb_disk_busy`, `sb_io_mbs`, `sb_dev_sectors` | `node_disk_io_time_seconds_total`, `node_disk_{read,written}_bytes_total` | yes |
| `sb_mounts`, `sb_disk_bar` | `node_filesystem_*` | yes |
| `sb_docker`, `sb_docker_alerts` | cAdvisor `container_health_state` (1 healthy / 0 unhealthy / **-1 = container declares no healthcheck**), plus per-container cpu/mem/net | yes — read a real `1` off cadvisor's own container |
| paging, ring buffers, cell folding, colour ramps, glyph widths (~1,000 lines) | Grafana | n/a |
| **`tier_rapl_read`** — chgrp `energy_uj` at every boot/resume | not needed: the exporter runs as root **in a container**, no host permission change | yes, RAPL read with no host chgrp |

## The three gaps — our code that survives

1. **Charge window has no metric.** `charge_control_end_threshold` /
   `_start_threshold` are **not** exported by the power_supply collector (checked the
   full scrape). This is exactly what `tier_battery_limit` writes and the board
   displays.
2. **Bay naming.** `sb_bay_label` / `sb_diskmap_parse` / `disks.latitude5520.conf` —
   turning a UUID into "dock 1 upper" is ours and nothing upstream knows it.
3. **Expected-but-unmounted.** No exporter has the concept of a mount that *should*
   be there. This is the concept that catches latitude's flaky dock.

All three land in the **textfile collector**, verified working: a `.prom` file dropped
in the collector dir appeared in the scrape as `fleet_disk_bay{device,bay,dock,uuid}`
and `fleet_mount_expected{mountpoint,bay}` within one interval, and `group_left` joins
the bay label onto any node/smartctl series. That is one script, roughly the size of
`sb_diskmap_parse` + `sb_unmounted`, and its output is asserted the same way — so the
suite keeps a target, much smaller.

**Not spiked at all — the one part of the board with zero measurement here.** The
tailnet/fleet slice: `sb_lan`, `sb_reach`, `sb_rtt_tenths`, `sb_bounded`, `sb_tailnet`,
`sb_ts_parse`, `sb_fleet_join`, `sb_fleet_alerts`, `sb_fleet_parse` — the
second-largest homegrown cluster after the probes. `blackbox_exporter` is the standard
answer for per-target up/down and RTT, and the fleet-join view would be a Grafana table
over that, but **none of it was verified**. Treat it as an open question, not as
presumed solved: cross-host reachability ("is every fleet member up") is a different
shape from a single-target probe, and it is the half of the board that has nothing to
do with `/sys`.

## Do the community dashboards render it? Panel-query coverage, measured

Every panel expression extracted, template variables substituted, run against the live
Prometheus:

| dashboard | queries | returned data | verdict |
|---|---|---|---|
| **1860 Node Exporter Full** | 284 | **243** | use it. Empties are collectors we did not enable (systemd, pressure/PSI, IRQ), not missing content |
| **22604 SMARTctl Exporter** | 13 | 2 here | properly templated (`$node`/`$disk`/`$type`); the empties are an NVMe-only box lacking the ATA attribute table, plus SSD-wear panels. Disk-temperature panel returned the real model name and 37 °C |
| 20204 "Dashboard for smartctl_exporter" | 9 | 7 | **do not use** — it hardcodes `device="nvme0"` and `instance="192.168.1.7:9633"`. It worked here by coincidence |
| 24629 Intel hwmon | 22 | 7 | **not applicable** — written for nct6775 desktop boards (SYSTIN/CPUTIN/PECI, voltage rails, chassis intrusion). Wrong hardware class |

**The bug.** 1860's *Hardware Temperature Monitor* — the only CPU-temperature panel in
the most-recommended dashboard in the ecosystem — **errors** on the ASUS box:

```
found duplicate series for the match group {chip="platform_asus_nb_wmi"} …
many-to-many matching not allowed: matching labels must be unique on one side
```

`platform_asus_nb_wmi` registers two hwmon chip names (`asus`,
`asus_custom_fan_curve`), and the panel's `* on(chip) group_left(chip_name)` requires
uniqueness. Same for *Hardware Fan Speed*. Wrapping the right-hand side in
`max by (chip, chip_name)(…)` fixes it and returns all 8 sensors. Untested on latitude
(Intel, no `asus_nb_wmi`), where it probably works as shipped — which is how a
dashboard ships broken for a whole hardware class without anyone noticing.

## Cost

Idle RSS: prometheus 115 MiB, grafana 126 MiB, cadvisor 155 MiB, node-exporter 10 MiB,
smartctl-exporter 8 MiB. TSDB 976 KB for ~20 min of 5 targets at 10 s.

## Recommendation

Replace the board's *rendering and probing* with the stack; keep a textfile collector
for the three fleet-specific facts. Our code goes from 3,856 + 1,822 to roughly: one
compose file, a scrape config, a datasource/dashboard provisioning pair, one patched
1860 JSON, and one bay/mount collector script.

**Open decisions, not resolved by this spike:** where the stack runs (latitude already
carries immich/servarr/restic), whether the tty board is replaced or kept alongside,
and whether `statusboard-gui.sh` swaps `foot`+`tmux` for `chromium --kiosk` under the
cage session that is already there.
