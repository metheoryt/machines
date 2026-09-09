# wtfutil as a replacement for `provision/statusboard/statusboard.sh` — spike

**Date:** 2026-09-09 · **Verdict: promising, with one structural loss.**
Probed on **g15** (Ubuntu 26.04), binary unpacked to a scratch dir. **Nothing was
installed on any box**, no tier touched, no tty claimed, latitude untouched.

## What was actually in doubt

The board is 3,044 lines plus a 749-line kiosk (`statusboard-gui.sh`), and the
kiosk is not the part a substitution removes — `tier_statusboard` already
installs cage + foot + tmux + btop, and the kiosk file is mostly the argument for
why cage runs from an autologin getty (it needs a logind seat to become DRM
master). So the question is whether an off-the-shelf grid can carry what the
**board** does. Three properties decide it, and none of them is "can it draw a
box":

1. **Two cadences.** The board repaints every 1s so the clock reads like a clock,
   but probes the network every 10s because each probe is two pings plus a
   `tailscale status` fork. A dashboard that ticks everything together cannot
   express that.
2. **Colour by severity**, which is the entire point of an alert strip.
3. **Pages**, because 26 rows do not fit the fleet beside the disks.

## Measured

**Refresh is per-module and non-blocking.** Three CmdRunner panels, 25 seconds,
each logging a timestamp per invocation:

| panel | `refreshInterval` | work | invocations in ~25 s |
|---|---|---|---|
| `fast` | `1s` | reads `/proc/loadavg` | **21** |
| `slow` | `10s` | **`sleep 4`** then prints | **3** |
| `alert`| `2s` | prints three lines | **11** |

The panel sleeping four seconds did not stall the 1s panel. That answers (1)
outright: the board's INTERVAL/PROBE/CELL split becomes three
`refreshInterval`s.

**Raw ANSI passes through; tview colour tags do not.** A panel printing
`\033[31mREDTEXT\033[0m` renders red (verified in the captured pty stream:
`\x1b[m\x1b[31mREDTEXT`). A panel printing `[red]REDTAG[white]` renders the
literal text `TAG:[red]REDTAG[white]`. So (2) works — and works via exactly the
mechanism `statusboard.sh` already uses (`C_BAD=$'\033[31m'`), which means its
formatting helpers port over rather than being rewritten. Anyone reading
wtfutil's docs would reach for the tag syntax and get literal brackets on a wall
display; that is the trap here.

**There is no paging or rotation.** `--help` has no such flag and the binary
carries no rotation concept (the only `NextPage` strings in it are API
pagination for asana/godo/spotify). One grid, one screen. **This is the
structural loss:** the board's page rotation, the arrow-key dwell, and the
"alert strip is on every page, so a page you are not looking at cannot hide a
fault" property all disappear. The replacement has to fit everything on one
grid — plausible at the kiosk's measured 146x36, but it is a design decision,
not a port.

## What it carries and what it costs

Carries: the grid with explicit column/row sizes and per-module `position`, a
built-in Docker module, and — the reason it fits this repo at all — every
irreducible fleet fact stays a small script in a CmdRunner panel: bay names from
sysfs topology, `disks.<hostname>.conf`, the transient-drive semantics, the
tailnet page.

Costs:

- **CmdRunner does not invoke a shell** (Go's `exec.Command`): no pipes, no
  globs, no redirection. Each panel is a standalone script. That is ~6 files
  instead of ~6 functions, which is a wash on line count and a small loss in
  cohesion.
- **75 MB binary** against 150 KB of bash. Not a real cost on a box already
  running the gortex daemon and Docker, but it is a new pinned dependency in the
  same class as `provision/gortex.version` — something to bump, verify and
  remember.
- **`tier_rapl_read` does NOT retire.** A CmdRunner panel reading `energy_uj`
  hits the same root-only sysfs mode the board does, so the tier survives
  unchanged. This is where netdata differs: it installs its plugin with
  `CAP_DAC_READ_SEARCH` (SUID root as fallback), so it needs no sysfs widening
  at all — at the price of a capability that bypasses every file read check on
  the box, which is *broader* than the tier's chgrp of two parent-domain files
  to 0440.
- Upstream is "informally maintained by a small collection of volunteers", and
  v1.0 renames the project to **Tessera**. A rename mid-adoption is a real cost
  for a repo whose whole problem is remembered surface.

## Recommendation

Worth doing, and the honest size of the win is **~3,044 lines minus a config and
~6 panel scripts**, not 5,678: the kiosk stays, `tier_rapl_read` stays, and
`disks.<hostname>.conf` stays. Take it only if losing page rotation is
acceptable — that is the one question a spike cannot answer.

Throwaway artifacts (config, probe scripts, captured frames) live in this
session's scratchpad and are not tracked.
