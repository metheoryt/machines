# g15 Phase 1 — Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move g15's entire 293 GB payload off the box onto latitude and prove by manifest that nothing was lost, so the installer can be booted without a second copy anywhere. (The target distro moved from Debian 13 to Ubuntu 26.04 LTS on 2026-09-07 — see the spec’s §2. Phase 1 moves bytes and is indifferent to it.)

**Architecture:** One tool, `hosts/g15/staging/stage.sh`, run as root **on g15-wsl**, which pushes each of three payloads outbound over the LAN to `latitude:/mnt/immich-mirror/g15-staging/` with rsync. The distro is NATed, so the tailnet path to latitude is DERP-relayed at 3.3 MB/s while the outbound LAN path is 78 MB/s — NAT blocks reaching *in*, not going out, and that asymmetry is the whole transport design. Verification is a path+size manifest taken on both sides and diffed, never a `du` comparison.

**Tech Stack:** bash, rsync 3.4.1 (both ends), OpenSSH, docker (to quiesce postgres), Windows Task Scheduler (to hold the distro up), `find -printf` manifests.

**Spec:** `docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md`

## Global Constraints

These apply to every task below, without being repeated in it.

- **`< /dev/null` (or `-n`) on every `ssh`, `docker` and `wsl` call inside a script fed on stdin.** Those commands read stdin to EOF and will eat the rest of the script. This bit during planning: a probe's last two lines silently never ran. Same class of failure as the `just test` gate skipping 17 suites.
- **Root on g15-wsl comes from Windows, not from `sudo`.** `me` is in the `sudo` group but has **no NOPASSWD**, so `sudo -n` fails. The route is `ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'` with the script on stdin. Never try to `sudo` inside the distro non-interactively.
- **`me` on latitude DOES have NOPASSWD sudo; `me` on desktop-wsl does NOT** (both checked 2026-09-07 — desktop answers `sudo: A terminal is required to authenticate`). So `--rsync-path='sudo rsync'` is used for the two latitude payloads, where ownership and modes are preserved numerically at copy time instead of being reconstructed on restore, and is **never** used for `music`: a sudo there would hang a 37-minute transfer waiting for a password nobody can type.
- **The destination is SPLIT: `pgdata` and `/home/me` go to latitude, `Music` goes to desktop.** His call, and the boundary is not arbitrary — drvfs on desktop invents ownership and modes (`chown 999:999 && chmod 600` reads back as `me:me 777`), which pgdata and `/home/me`'s `.ssh` cannot survive, and it costs 6.6 ms per file, which `/home/me`'s 226 003 files cannot afford. `Music` has no metadata worth keeping and averages 6 MB a file. desktop-wsl's own ext4 was never an option: 99 GB total, 60 GB free.
- **Music's route is port 2222, and that needed two changes on desktop.** `.wslconfig` puts desktop-wsl in `networkingMode=mirrored`, so the distro shares the Windows adapters and the Windows OpenSSH server already owns 22 — `ssh.socket` had been losing that bind race, and failing, every boot since 2026-08-29. An override moves it to 2222 (both address families spelled out: a bare `ListenStream=2222` bound only `[::]` and IPv4 clients got `Connection refused`), and an inbound Windows firewall rule scoped to `192.168.8.0/24` admits it.
- **Music's destination lives under the user's own directory.** `mkdir /mnt/c/g15-staging` is refused without admin; `/mnt/c/Users/methe/g15-staging` is not.
- **Scripts reach a Windows fleet host as a heredoc on stdin, never as a quoted argument.** PowerShell parses the command line first and eats quotes; a `-printf "%s\t%P\n"` passed as an argument silently returns one line.
- **`pv` and `zstd` are NOT installed on g15-wsl** and installing them needs the password-gated sudo. No step may reach for either. `--info=stats2` is the progress report.
- **`ssh` to a bare IP does not pick up the fleet identity.** The generated config keys on `Host *.gg.ez`, so `ssh me@192.168.8.155` falls through to the default identity and fails in 0.2 s having moved nothing — which reads exactly like having no bandwidth. Always `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`. This produced three false measurements on 2026-09-07.
- **Do not switch g15 to `networkingMode=mirrored`.** It would probably work, and it would also expose the Windows Tailscale adapter inside the distro while g15 has two tailnet nodes (`100.64.0.3` Windows, `100.64.0.9` distro) to fight over routes. Changing the network mode of the box you are about to read 204 GB out of, to save half an hour on a route that already runs at 78 MB/s, is the wrong trade.
- **g15 → desktop is 40 MB/s and that is inherent.** Both are on wifi (desktop has only an `Intel Wi-Fi 6E AX211`), so their traffic crosses the access point twice; latitude sits on cable (`enp0s31f6` holds `192.168.8.155`) and takes 78 MB/s from the same source. Do not go looking for a setting.
- **Postgres stays stopped once Task 3 stops it.** Any restart rewrites `pgdata` and invalidates the manifest taken in Task 7. The container's restart policy is set to `no` deliberately and is **not** restored — the container dies with the disk.
- **Nothing in this plan wipes, formats, deletes or reinstalls anything.** Phase 1 is additive on both boxes. Rollback until Phase 2 is "delete the staging copy".

### Amendments (2026-09-07, recorded after Task 2)

Six changes to what Task 1 delivered. All are in `stage.sh` and its suite
already; the code blocks in Task 1 below are regenerated from the files, so the
plan and the disk agree. Items 4-6 were found while Task 4 was running.

1. **`require_root` never accepted root.** Its comparison read
   `[ "1000 4 24 27 30 46 100 1000 1001id -u)" = 0 ]` — a write-time
   command-substitution leak that was baked into *this document's own code
   block*, so extracting it verbatim reproduced it faithfully. Every mode that
   runs anything (`plan`, `stage`, `verify`, `status`) refused with exit 1 even
   as uid 0. `cmd` and `manifest-cmd` never call it, which is why every
   hand-check and all 59 suite assertions passed: the suite's two root
   assertions both checked the *refusal*, and a require_root broken in the other
   direction produces exactly the same refusal. The suite now shims `id -u` to 0
   and a no-op `rsync` and asserts the ACCEPT path.
2. **A delete pass exists: `./stage.sh restage <payload>`.** Task 8 re-runs
   `home` days after Task 6 and then demands an exact manifest match. Without
   `--delete` a file deleted under `/home/me` in between lingers at the
   destination and that gate fails on a correct copy — at the point of no
   return. `--delete` is opt-in by its own mode word rather than a default,
   because on a first pass it is a no-op and on a mistyped `STAGE_DIR` it is
   not; `restage` additionally refuses (exit 5) a destination that does not
   already hold a first pass. `./stage.sh plan <payload> delete` previews the
   removals. Exit 5 joins the documented codes.
3. **The destination is split, so `stage.sh` resolves host, port, remote shell
   and `--rsync-path` per payload** (`payload_host`, `payload_port`,
   `payload_remote_sudo`, `remote_sh`, `ssh_opts_for`), with `STAGE_DESK`,
   `STAGE_DESK_PORT` and `STAGE_DESKDIR` as the overrides. `Music` goes to
   desktop over port 2222 with no remote sudo; `pgdata` and `/home/me` go to
   latitude on 22 under `sudo rsync`. Task 5's budget moves from ~19 to
   ~37 minutes. The reasons are in the Global Constraints above and, measured,
   in `stage.sh`'s header; the one that decides it is that NTFS cannot hold
   pgdata's ownership or `/home/me`'s modes at all.
4. **`verify`'s verdict never reached the payload log.** `stage` redirects its
   own output there with `exec >>`; `verify` deliberately does not, because it
   runs in the foreground and is read live. But Task 7 Step 4 records the
   outcome with `grep -h MANIFEST /var/log/g15-staging/*.log`, which would have
   grepped three logs and found nothing — and reported that as having recorded
   the verdicts. A `verdict()` helper now renders the line once and writes it to
   both, so the screen and the log cannot carry different timestamps. Suite
   §12 runs `verify` for real against shimmed manifests and asserts the log
   copy, the shared timestamp and both exit codes.
5. **`tail -f` on the log shows nothing for 40 minutes.** There is no
   `--progress`; `--info=stats2` prints its block only when rsync finishes. The
   log carries the two header lines and then goes silent until the end, which
   reads exactly like a dead transfer. The progress signal is the destination:
   `ssh latitude 'sudo du -sh /mnt/immich-mirror/g15-staging/pgdata'`. **The
   `sudo` is not optional** — rsync recreates pgdata's tree with its numeric
   ownership, so `18/docker` lands as mode 700 owned by uid 999 and `me` reads
   `0` for the whole payload. That is ownership being preserved correctly, which
   is what Phase 4's physical restore needs; it is a passed check, not a
   nuisance.
6. **`pgdata` is verified immediately after Task 4, not deferred to Task 7.**
   The dst-side manifest is the one thing the suite cannot exercise against a
   real root-owned 0700 tree, and `verify` is the only step that proves anything
   at all. Finding a broken verify mechanism on the first payload costs a
   re-check; finding it after three transfers costs an hour and a half. Task 7's
   pgdata step then re-reads the recorded verdict instead of re-deriving it.

---

## Measured facts this plan is built on

All measured 2026-09-07. If a number here disagrees with the box, trust the box and stop.

| Fact | Value |
|---|---|
| `/data/qaz-law/pgdata` | 186 GB, 1268 files, **0 hardlinks** |
| ├ file ownership/mode | uniformly `999:999` mode `600` |
| ├ dir ownership/mode | four combinations: `0:0 755`, `999:0 700`, `999:999 700`, `999:999 755` |
| └ live `PGDATA` | `/data/qaz-law/pgdata/18/docker` (postgres 18.4, `data_checksums on`) |
| `/home/me` | 18 GB, 226 003 files, 39 symlinks, 2 sockets, **0 hardlinks**, uniformly `1000:1000` |
| └ the 2 sockets | `~/.config/orca/o-2126-cc81.sock`, `~/.config/orca/daemon/daemon-v36.sock` |
| `/mnt/c/Users/methe/Music` | 89 GB, 14 878 files, drvfs (synthetic ownership and perms) |
| **Total** | **293 GB → ~63 min at 78 MB/s** |
| latitude `/mnt/immich-mirror` | ext4, 610 GB free, writable by `me`, rsync 3.4.1 |
| g15-wsl | rsync 3.4.1, `tmux`/`screen`/`setsid` present, **`pv`/`zstd` absent** |
| docker container | `qaz-law-db-1`, compose project `qaz-law`, restart policy `always` |
| `wsl-keepalive` task | State `Ready`, **last run 2026-09-05 21:42, result `3221225786`** = `STATUS_CONTROL_C_EXIT` |

**That last row is the sharpest finding of the planning pass.** `State: Ready` means *not running*; the keepalive died two days ago and the distro is currently held up only by stray `wsl.exe` orphans from interactive sessions. A WSL distro lives only while a `wsl.exe` client from Windows is attached to it, so a 40-minute transfer started under those orphans can die when one of them exits — and `setsid nohup` does not save it, because the detached process goes down with the distro. Task 2 re-arms the keepalive and verifies it **by PID inside the distro**, not by task state. This repo already learned that lesson once: *verify a scheduled job by firing its schedule, not by reading its status.*

---

## File Structure

| File | Responsibility |
|---|---|
| `hosts/g15/staging/stage.sh` | **Create.** The one staging tool. Payload table (source, destination, per-payload rsync flags), the postgres guard, the manifest pipeline, and the six modes: `cmd`, `manifest-cmd`, `plan`, `stage`, `verify`, `status`. Runs on g15-wsl as root. |
| `hosts/g15/staging/stage.test.sh` | **Create.** Gate suite. Asserts the guards and the *composed* command lines without moving a byte, so it runs on any box, non-root, inside `just test`. |
| `hosts/g15/staging/identity-snapshot.txt` | **Create in Task 2.** The identity set that must move together, captured from live commands rather than retyped. |

`hosts/g15/` is new — `hosts/server/` was deleted with the 2026-08-01 decommission and `hosts/g15/<platform>/` will appear in Phase 4 — and what that directory is called is an open question now that the box is Ubuntu and latitude’s is `hosts/latitude/debian/`: the convention says `<platform>`, and whether that means the distro or the class has never had to be decided. Nothing existing is modified. The tests directory convention in this repo is co-location (`agents/plugin/skills/*/tests/`, `provision/*.test.sh`), and `just _test-suites` is a recursive `find`, so a suite here is picked up by the gate with no wiring.

**Why one script with modes rather than three scripts:** the three payloads differ only in source path and four rsync flags. The parts that are easy to get wrong — the ssh identity, `--partial-dir`, `--rsync-path='sudo rsync'`, the manifest pipeline — are identical, and duplicating them three times is how two of the three end up subtly different. Same shape `hosts/latitude/debian/archive-mirror.sh` uses (`-n` / `-go` / `-verify` in one file).

---

### Task 1: The staging tool and its guard suite

**Files:**
- Create: `hosts/g15/staging/stage.test.sh`
- Create: `hosts/g15/staging/stage.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the CLI every later task drives —
  `stage.sh cmd <payload> [dry]` → prints the rsync command line, runs nothing, needs no root;
  `stage.sh manifest-cmd <payload> {src|dst}` → prints the manifest pipeline, runs nothing;
  `stage.sh plan <payload>` → `rsync -n`, needs root;
  `stage.sh stage <payload>` → the copy, needs root, logs to `/var/log/g15-staging/<payload>.log`;
  `stage.sh verify <payload>` → manifests both sides, diffs, exit 4 on mismatch;
  `stage.sh status` → sizes on both sides plus log tails.
  Payloads: `pgdata`, `home`, `music`. Env overrides: `STAGE_LAT`, `STAGE_DIR`, `STAGE_KEY`, `STAGE_LOGDIR`, `STAGE_PGPID`.
  Exit codes: `0` ok, `1` not root, `2` usage, `3` postgres still running, `4` manifest mismatch.

- [x] **Step 1: Write the failing test suite**

Create `hosts/g15/staging/stage.test.sh`:

```bash
#!/usr/bin/env bash
# hosts/g15/staging/stage.test.sh — guard the staging tool's composed commands.
#
# WHY THIS SUITE EXISTS AND WHAT IT CAN AND CANNOT CHECK. stage.sh moves 293 GB
# in three runs of about 40, 19 and 5 minutes, on a box that is about to be
# wiped. There is no second attempt after the disk is gone, so the flags have to
# be right the FIRST time — but a test cannot move 293 GB, and a test that moved
# a token file would exercise none of the flags that matter.
#
# So stage.sh separates COMPOSING a command from RUNNING it (`cmd` and
# `manifest-cmd` print and exit), and this suite asserts the composition. It
# needs no root, no g15, no latitude and no network, which is what lets it run
# in `just test` on any box in the fleet.
#
# The four things it pins are the four that were actually got wrong by hand
# during planning:
#   - the fleet identity (`-i`, `IdentitiesOnly=yes`) — three false zero-byte
#     "measurements" came from a bare-IP ssh falling through to the default key
#   - `--partial-dir`, never `--append-verify` (archive-mirror.sh's header says
#     why: a torn write is not a strict prefix of the source)
#   - `-a` on the ext4 payloads but NOT on the drvfs one, where it would copy
#     synthetic ownership and then fail setting it
#   - the postgres guard, because a running PGDATA copies torn and the result
#     looks exactly like a backup
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/stage.sh"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

[ -f "$SH" ] || { echo "FAIL: $SH missing" >&2; exit 1; }
[ -x "$SH" ]
check $? "stage.sh is executable"

# `me` runs the gate, never root — every assertion below must hold non-root.
if [ "$(id -u)" = 0 ]; then
    echo "FAIL: run this suite as a normal user; the non-root assertions need it" >&2
    exit 1
fi

# ── 1. Usage and exit codes ───────────────────────────────────────────────────
# Exit CODES, not messages: a caller (and Task 4's launcher) branches on the
# code, and pinning the prose makes the suite fail on a reworded error.
"$SH" >/dev/null 2>&1; [ "$?" = 2 ]
check $? "no arguments exits 2"

"$SH" frobnicate pgdata >/dev/null 2>&1; [ "$?" = 2 ]
check $? "an unknown mode exits 2"

"$SH" cmd >/dev/null 2>&1; [ "$?" = 2 ]
check $? "cmd with no payload exits 2"

"$SH" cmd nosuchpayload >/dev/null 2>&1; [ "$?" = 2 ]
check $? "an unknown payload exits 2"

# ── 2. cmd/manifest-cmd compose without root and without touching anything ────
"$SH" cmd pgdata >/dev/null 2>&1
check $? "cmd runs as a normal user (it composes, it does not copy)"

# ── 3. The flags that must be on EVERY payload ────────────────────────────────
for p in pgdata home music; do
    c="$("$SH" cmd "$p" 2>/dev/null)"

    printf '%s' "$c" | grep -q -- "--partial-dir=.rsync-partial"
    check $? "$p: --partial-dir=.rsync-partial is present"

    printf '%s' "$c" | grep -q -- "--append-verify"
    if [ $? -eq 0 ]; then
        fail "$p: uses --append-verify, which assumes the destination is a strict prefix of the source"
    else
        pass "$p: does not use --append-verify"
    fi

    printf '%s' "$c" | grep -q -- "IdentitiesOnly=yes"
    check $? "$p: ssh pins the fleet identity (IdentitiesOnly=yes)"

    printf '%s' "$c" | grep -q -- "id_fleet"
    check $? "$p: ssh names id_fleet"

    printf '%s' "$c" | grep -qE -- "(^| )-x( |$)|(^| )'-x'( |$)"
    check $? "$p: -x (one file system), so the copy and the manifest agree"

    case "$p" in music) want=192.168.8.145 ;; *) want=192.168.8.155 ;; esac
    printf '%s' "$c" | grep -q -- "$want"
    check $? "$p: targets $want over the LAN, not a relayed tailnet name"

    printf '%s' "$c" | grep -q -- "gg.ez"
    if [ $? -eq 0 ]; then
        fail "$p: targets a .gg.ez name — that path is DERP-relayed at 3.3 MB/s from this distro"
    else
        pass "$p: does not target a .gg.ez name"
    fi
done

# ── 4. Per-payload flags ──────────────────────────────────────────────────────
pg="$("$SH" cmd pgdata 2>/dev/null)"
printf '%s' "$pg" | grep -qE -- "(^| )'?-a'?( |$)"
check $? "pgdata: -a (perms, owners, times)"
printf '%s' "$pg" | grep -q -- "--numeric-ids"
check $? "pgdata: --numeric-ids, so uid 999 is not renamed on the way over"
printf '%s' "$pg" | grep -q "/data/qaz-law/pgdata/"
check $? "pgdata: source is /data/qaz-law/pgdata/"

mu="$("$SH" cmd music 2>/dev/null)"
printf '%s' "$mu" | grep -qE -- "(^| )'?-a'?( |$)"
if [ $? -eq 0 ]; then
    fail "music: uses -a, which copies drvfs's invented ownership and then fails to set it"
else
    pass "music: does not use -a"
fi
printf '%s' "$mu" | grep -q -- "--no-perms"
check $? "music: --no-perms"
printf '%s' "$mu" | grep -q -- "--no-owner"
check $? "music: --no-owner"
printf '%s' "$mu" | grep -q -- "--modify-window=1"
check $? "music: --modify-window=1 (drvfs timestamp granularity)"
printf '%s' "$mu" | grep -q "/mnt/c/Users/methe/Music/"
check $? "music: source is /mnt/c/Users/methe/Music/"

ho="$("$SH" cmd home 2>/dev/null)"
printf '%s' "$ho" | grep -qE -- "exclude=.*\.sock"
check $? "home: excludes *.sock (the two orca sockets; rsync cannot copy a socket)"
printf '%s' "$pg" | grep -qE -- "exclude=.*\.sock"
if [ $? -eq 0 ]; then
    fail "pgdata: carries the home-only *.sock exclude"
else
    pass "pgdata: does not carry the home-only *.sock exclude"
fi

# ── 5. dry mode ───────────────────────────────────────────────────────────────
printf '%s' "$("$SH" cmd pgdata dry 2>/dev/null)" | grep -qE -- "(^| )'?-n'?( |$)"
check $? "cmd <payload> dry composes rsync -n"
printf '%s' "$pg" | grep -qE -- "(^| )'?-n'?( |$)"
if [ $? -eq 0 ]; then
    fail "cmd <payload> without 'dry' composes a DRY RUN — the real copy would move nothing"
else
    pass "cmd <payload> without 'dry' is not a dry run"
fi

# ── 6. The manifest pipeline ──────────────────────────────────────────────────
# Sizes for regular files ONLY. A directory's reported size is a property of the
# filesystem, not of the content, so comparing it yields false diffs — and on
# drvfs -> ext4 it would make every single directory differ. Sockets are dropped
# on both sides: rsync never copies one, so the two orca sockets would otherwise
# read as two missing files forever.
m="$("$SH" manifest-cmd pgdata src 2>/dev/null)"
printf '%s' "$m" | grep -q "LC_ALL=C"
check $? "manifest: LC_ALL=C (sort order must be byte order on both sides)"
printf '%s' "$m" | grep -q "type f -printf"
check $? "manifest: regular files get a size"
printf '%s' "$m" | grep -q "type l -printf"
check $? "manifest: symlinks record their target"
# Path first, or `sort` orders by size-as-a-string and a single changed size
# relocates its line, turning a one-path diff into a spurious block.
bad=$(printf '%s' "$m" | grep -o -- "-printf '[^']*'" | grep -cv "^-printf '%p")
[ "$bad" = 0 ]
check $? "manifest: every -printf starts with %p, so the manifest sorts by PATH ($bad did not)"
printf '%s' "$m" | grep -q "type s"
check $? "manifest: sockets are handled explicitly"
printf '%s' "$m" | grep -q ".rsync-partial"
check $? "manifest: .rsync-partial is pruned (a parked torn file is not content)"
printf '%s' "$m" | grep -q "du -s"
if [ $? -eq 0 ]; then
    fail "manifest: reaches for du — du totals match even when one file is truncated"
else
    pass "manifest: does not use du"
fi

printf '%s' "$("$SH" manifest-cmd pgdata dst 2>/dev/null)" | grep -q "/mnt/immich-mirror/g15-staging/pgdata"
check $? "manifest-cmd dst points at the staging tree"

"$SH" manifest-cmd pgdata >/dev/null 2>&1; [ "$?" = 2 ]
check $? "manifest-cmd without src|dst exits 2"

# ── 7. The postgres guard ─────────────────────────────────────────────────────
# STAGE_PGPID is overridable so this is testable at all — and because a moved
# PGDATA would need it anyway. Without the guard the copy runs against a live
# postgres and produces a torn tree that looks like a backup.
pid="$(mktemp)"; trap 'rm -f "$pid"' EXIT
STAGE_PGPID="$pid" "$SH" stage pgdata >/dev/null 2>&1; [ "$?" = 3 ]
check $? "stage pgdata refuses with exit 3 while postmaster.pid exists"

# Greps for the OVERRIDE path, not the literal string "postmaster.pid": the
# message names the file it actually checked, and STAGE_PGPID has replaced the
# default here. Asserting the literal would only test that the default is
# hard-coded into the prose.
STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | grep -qF "$pid"
check $? "the refusal names the pid file it checked"

# die() takes the exit code as its SECOND argument; printing "$*" instead of
# "$1" appends it to the message. Measured while writing this plan: the root
# refusal ended in a stray " 1".
STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | tail -1 | grep -qE '(^| )3$'
if [ $? -eq 0 ]; then
    fail "the refusal message leaks its exit code (die prints \$* instead of \$1)"
else
    pass "the refusal message does not leak its exit code"
fi

STAGE_PGPID="$pid" "$SH" stage home >/dev/null 2>&1; [ "$?" = 3 ]
if [ $? -eq 0 ]; then
    fail "the postgres guard fires for the home payload, which does not touch PGDATA"
else
    pass "the postgres guard is scoped to pgdata"
fi

rm -f "$pid"
STAGE_PGPID="$pid" "$SH" stage pgdata >/dev/null 2>&1; [ "$?" = 1 ]
check $? "with no postmaster.pid, a non-root stage exits 1 (root refusal, guard passed)"

STAGE_PGPID="$pid" "$SH" stage pgdata 2>&1 | grep -q "wsl -d Ubuntu-26.04 -u root"
check $? "the root refusal prints the route to root (sudo needs a password on this distro)"

# ── 8. Env overrides ──────────────────────────────────────────────────────────
STAGE_LAT="me@10.0.0.1" "$SH" cmd pgdata 2>/dev/null | grep -q "me@10.0.0.1"
check $? "STAGE_LAT overrides the destination host"

STAGE_DIR="/srv/elsewhere" "$SH" cmd pgdata 2>/dev/null | grep -q "/srv/elsewhere/pgdata"
check $? "STAGE_DIR overrides the staging root"


# ── 9. require_root must ACCEPT root, not only refuse non-root ────────────────
# Section 7's two root assertions both check the REFUSAL, and a require_root
# that is broken in the *other* direction produces exactly the same refusal —
# so it passed a green suite while `plan`, `stage`, `verify` and `status` were
# all dead. That is what happened: the comparison in require_root read
#   [ "1000 4 24 27 30 46 100 1000 1001id -u)" = 0 ]
# a write-time command-substitution leak baked into the plan document's own code
# block, so extracting it verbatim reproduced it faithfully. `cmd` and
# `manifest-cmd` never call require_root, which is why every hand-check passed.
#
# The shim gives uid 0 without root and a no-op rsync, so the accept path is
# reachable in the gate on any box.
shim="$(mktemp -d)"
cat > "$shim/id" <<'SHIM'
#!/bin/sh
case "$1" in -u) echo 0 ;; *) exec /usr/bin/id "$@" ;; esac
SHIM
cat > "$shim/rsync" <<'SHIM'
#!/bin/sh
echo "SHIM-RSYNC $*"
SHIM
cat > "$shim/ssh" <<'SHIM'
#!/bin/sh
exit "${SHIM_SSH_RC:-0}"
SHIM
chmod +x "$shim/id" "$shim/rsync" "$shim/ssh"
LOGD="$(mktemp -d)"
trap 'rm -rf "$shim" "$LOGD" "$pid"' EXIT

root_out="$(PATH="$shim:$PATH" "$SH" plan pgdata 2>&1)"
printf '%s' "$root_out" | grep -q "SHIM-RSYNC"
check $? "require_root ACCEPTS uid 0 — plan reaches rsync"
printf '%s' "$root_out" | grep -q "must run as root"
if [ $? -eq 0 ]; then
    fail "require_root refuses uid 0 — its comparison is broken, every running mode is dead"
else
    pass "require_root does not refuse uid 0"
fi

# ── 10. The delete pass: opt-in by its own mode word ──────────────────────────
# Task 8 re-runs `home` days after Task 6 and then demands an EXACT manifest
# match. Without --delete, a file deleted under /home/me in between lingers at
# the destination and that gate fails on a copy which is otherwise correct —
# at the point of no return. So a delete pass exists; it is NOT the default,
# because on a mistyped STAGE_DIR --delete is not a no-op.
for p in pgdata home music; do
    printf '%s' "$("$SH" cmd "$p" 2>/dev/null)" | grep -q -- "--delete"
    if [ $? -eq 0 ]; then
        fail "$p: the DEFAULT composition carries --delete"
    else
        pass "$p: the default composition carries no --delete"
    fi
done

del="$("$SH" cmd home delete 2>/dev/null)"
printf '%s' "$del" | grep -q -- "--delete"
check $? "cmd <payload> delete composes --delete"
printf '%s' "$del" | grep -qE -- "(^| )'?-n'?( |$)"
if [ $? -eq 0 ]; then
    fail "cmd <payload> delete is also a dry run — the delete pass would move nothing"
else
    pass "cmd <payload> delete is not a dry run"
fi
printf '%s' "$del" | grep -q -- "--delete-excluded"
if [ $? -eq 0 ]; then
    fail "delete pass carries --delete-excluded, which would remove the parked .rsync-partial files and the protected sockets"
else
    pass "delete pass does not carry --delete-excluded"
fi
printf '%s' "$del" | grep -q -- "--exclude=.rsync-partial/"
check $? "delete pass still excludes .rsync-partial/ (excluded means protected from deletion)"

dd="$("$SH" cmd home delete-dry 2>/dev/null)"
printf '%s' "$dd" | grep -q -- "--delete" && \
    printf '%s' "$dd" | grep -qE -- "(^| )'?-n'?( |$)"
check $? "cmd <payload> delete-dry composes --delete AND -n (see what would be removed first)"

"$SH" restage >/dev/null 2>&1; [ "$?" = 2 ]
check $? "restage with no payload exits 2"
"$SH" restage nosuchpayload >/dev/null 2>&1; [ "$?" = 2 ]
check $? "restage with an unknown payload exits 2"

pid="$(mktemp)"
STAGE_PGPID="$pid" "$SH" restage pgdata >/dev/null 2>&1; [ "$?" = 3 ]
check $? "restage pgdata refuses with exit 3 while postmaster.pid exists"
rm -f "$pid"

STAGE_PGPID="$pid" "$SH" restage home >/dev/null 2>&1; [ "$?" = 1 ]
check $? "a non-root restage exits 1 (the root refusal, same as stage)"

# The destination guard: a delete pass is only ever a SECOND pass, so it refuses
# an absent or empty destination rather than mirroring a fresh tree with
# --delete armed. Exit 5. The shimmed ssh stands in for the remote check.
out5="$(PATH="$shim:$PATH" SHIM_SSH_RC=1 STAGE_LOGDIR="$LOGD" \
        STAGE_PGPID="$pid" "$SH" restage home 2>&1)"; rc5=$?
[ "$rc5" = 5 ]
check $? "restage refuses with exit 5 when the destination is absent or empty (got $rc5)"
printf '%s' "$out5" | grep -qi "second pass"
check $? "the exit-5 refusal says why: a delete pass is only ever a second pass"

# ...and with a destination that does exist, the delete pass actually arms
# --delete. stage/restage redirect their output into the log, so read it there.
rm -f "$LOGD"/home.log
PATH="$shim:$PATH" SHIM_SSH_RC=0 STAGE_LOGDIR="$LOGD" STAGE_PGPID="$pid" \
    "$SH" restage home >/dev/null 2>&1
grep -q -- "--delete" "$LOGD/home.log" 2>/dev/null
check $? "restage runs rsync WITH --delete"

rm -f "$LOGD"/home.log
PATH="$shim:$PATH" SHIM_SSH_RC=0 STAGE_LOGDIR="$LOGD" STAGE_PGPID="$pid" \
    "$SH" stage home >/dev/null 2>&1
grep -q -- "--delete" "$LOGD/home.log" 2>/dev/null
if [ $? -eq 0 ]; then
    fail "plain stage runs rsync WITH --delete — the first pass must not delete"
else
    pass "plain stage runs rsync without --delete"
fi

# ── 11. The split destination ─────────────────────────────────────────────────
# pgdata and /home/me go to latitude; Music goes to desktop. Two reasons, both
# measured 2026-09-07 and neither about space:
#   - drvfs on desktop INVENTS ownership and modes: after chown 999:999 +
#     chmod 600, stat reads `me:me 777`. pgdata's files are 999:999 mode 600
#     under directories in four different combinations, and /home/me carries
#     .ssh — neither survives NTFS. Music has no metadata worth keeping.
#   - drvfs costs 6.6 ms per file (19.8 s for 3000 files, against 0.03 s on
#     ext4). /home/me is 226003 files, so NTFS would add ~25 minutes of pure
#     per-file overhead. Music is 14878 files averaging 6 MB.
# desktop-wsl's own ext4 is not an option either: 99 GB total, 60 GB free.
for p in pgdata home; do
    c="$("$SH" cmd "$p" 2>/dev/null)"
    printf '%s' "$c" | grep -q -- "rsync-path=sudo"
    check $? "$p: destination runs rsync under sudo (ownership preserved numerically at copy time)"
    printf '%s' "$c" | grep -q -- "2222"
    if [ $? -eq 0 ]; then
        fail "$p: carries desktop's ssh port — it goes to latitude on 22"
    else
        pass "$p: does not carry desktop's ssh port"
    fi
done

mu="$("$SH" cmd music 2>/dev/null)"
# The port lives inside the single -e argument, so printf %q escapes the space:
# the composed text reads `-p\ 2222`, not `-p 2222`. Matching the literal space
# is the third time that escaping has broken an assertion in this suite.
printf '%s' "$mu" | grep -qE -- '-p[^a-zA-Z0-9]{0,2}2222'
check $? "music: ssh uses port 2222 (Windows OpenSSH owns 22 on desktop, mirrored networking)"
printf '%s' "$mu" | grep -q -- "rsync-path=sudo"
if [ $? -eq 0 ]; then
    fail "music: runs the destination rsync under sudo — desktop-wsl's \`me\` has NO passwordless sudo, so it would hang for a password"
else
    pass "music: does not run the destination rsync under sudo"
fi
printf '%s' "$mu" | grep -q "/mnt/c/Users/methe/g15-staging/Music"
check $? "music: destination is under the user's own directory (C:\\ root refuses a mkdir without admin)"
printf '%s' "$("$SH" manifest-cmd music dst 2>/dev/null)" | grep -q "/mnt/c/Users/methe/g15-staging/Music"
check $? "manifest-cmd music dst points at the desktop tree"

STAGE_DESK="me@10.0.0.2" "$SH" cmd music 2>/dev/null | grep -q "me@10.0.0.2"
check $? "STAGE_DESK overrides the Music destination host"
STAGE_DESK_PORT=2323 "$SH" cmd music 2>/dev/null | grep -q "2323"
check $? "STAGE_DESK_PORT overrides the Music destination port"
STAGE_DESK="me@10.0.0.2" "$SH" cmd pgdata 2>/dev/null | grep -q "me@10.0.0.2"
if [ $? -eq 0 ]; then
    fail "STAGE_DESK leaks into the pgdata destination"
else
    pass "STAGE_DESK does not affect pgdata"
fi


# --- 12. the verdict reaches the payload log, not just the operator's screen ---
# Task 7's last step records the outcome with `grep -h MANIFEST
# /var/log/g15-staging/*.log`. `stage` redirects its own output into that log
# with `exec >>`; `verify` deliberately does not, because it runs in the
# foreground and is meant to be read live. So the verdict lines are the one
# thing that has to reach both, and until 2026-09-07 they reached only stdout —
# the record step would have grepped three logs and found nothing.
#
# This section runs verify FOR REAL. The manifests come from shims: `bash`
# stands in for the local `manifest_cmd | bash`, `ssh` for the remote one, each
# printing a fixed file. That is why stage.sh is invoked as `/bin/bash "$SH"` —
# its shebang is `/usr/bin/env bash`, which would resolve to the shim.
shim2="$(mktemp -d)"; LOGD2="$(mktemp -d)"
cp "$shim/id" "$shim2/id"
cat > "$shim2/bash" <<'SHIM'
#!/bin/sh
cat > /dev/null
cat "$SHIM_SRC_MANIFEST"
SHIM
cat > "$shim2/ssh" <<'SHIM'
#!/bin/sh
cat > /dev/null
cat "$SHIM_DST_MANIFEST"
SHIM
chmod +x "$shim2/bash" "$shim2/ssh"
printf './PG_VERSION\tf\t3\n./base\td\t-\n' > "$LOGD2/m.src"
printf './PG_VERSION\tf\t3\n./base\td\t-\n' > "$LOGD2/m.same"
printf './PG_VERSION\tf\t4\n./base\td\t-\n' > "$LOGD2/m.diff"
trap 'rm -rf "$shim" "$LOGD" "$pid" "$shim2" "$LOGD2"' EXIT

v_out="$(PATH="$shim2:$PATH" STAGE_LOGDIR="$LOGD2" \
    SHIM_SRC_MANIFEST="$LOGD2/m.src" SHIM_DST_MANIFEST="$LOGD2/m.same" \
    /bin/bash "$SH" verify pgdata 2>&1)"; v_rc=$?
[ "$v_rc" = 0 ]
check $? "verify: a matching pair exits 0 (got $v_rc)"
printf '%s' "$v_out" | grep -q "MANIFEST MATCH — 2 entries"
check $? "verify: prints the match verdict to stdout"
grep -q "MANIFEST MATCH — 2 entries" "$LOGD2/pgdata.log" 2>/dev/null
check $? "verify: the match verdict also lands in the payload log (Task 7 greps it)"
grep -q "entries: src=2 dst=2" "$LOGD2/pgdata.log" 2>/dev/null
check $? "verify: the entry counts land in the payload log too"
# One render, two copies: a second `date` call would let the log and the screen
# disagree by a second, and then nobody can line the two up.
ts_screen="$(printf '%s' "$v_out" | grep -o '^\[[^]]*\] MANIFEST MATCH' | head -1)"
grep -qF "$ts_screen" "$LOGD2/pgdata.log"
check $? "verify: screen and log carry the SAME timestamp for the verdict"

rm -f "$LOGD2/pgdata.log"
PATH="$shim2:$PATH" STAGE_LOGDIR="$LOGD2" \
    SHIM_SRC_MANIFEST="$LOGD2/m.src" SHIM_DST_MANIFEST="$LOGD2/m.diff" \
    /bin/bash "$SH" verify pgdata > /dev/null 2>&1
[ $? = 4 ]
check $? "verify: a differing pair exits 4"
grep -q "MANIFEST MISMATCH" "$LOGD2/pgdata.log" 2>/dev/null
check $? "verify: the MISMATCH verdict lands in the payload log as well"

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "$FAIL FAILED" >&2; exit 1; fi
```

- [x] **Step 2: Run the suite to verify it fails**

```bash
bash hosts/g15/staging/stage.test.sh
```

Expected: `FAIL: hosts/g15/staging/stage.sh missing`, exit 1.

- [x] **Step 3: Write `stage.sh`**

Create `hosts/g15/staging/stage.sh`, then `chmod +x` it:

```bash
#!/usr/bin/env bash
# hosts/g15/staging/stage.sh — move g15's payload off the box before the
# Windows -> Linux wipe. Phase 1 of
# docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md
#
# RUNS ON g15-wsl, AS ROOT. Not on latitude, not on Windows.
#
#   ./stage.sh cmd          <payload> [kind]  print the rsync command, run nothing
#   ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
#   ./stage.sh plan         <payload> [delete] rsync -n: what would move (or remove)
#   ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
#   ./stage.sh restage      <payload>         a SECOND pass, with --delete
#   ./stage.sh verify       <payload>         manifest both sides and diff
#   ./stage.sh status                         sizes on both sides + log tails
#
#   payload: pgdata | home  -> latitude (ext4)
#            music          -> desktop  (NTFS, port 2222)
#   kind:    go | dry | delete | delete-dry
#   exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest
#            mismatch · 5 restage into a missing or empty destination
#
# WHY `restage` IS A SEPARATE WORD. Task 8 re-runs `home` days after Task 6 and
# then demands an EXACT manifest match — the spec's point of no return. Without
# --delete, a file deleted under /home/me in between lingers at the destination
# and that gate fails on a copy which is otherwise correct. But --delete must
# not be the default: on a first pass it is a no-op, and on a mistyped
# STAGE_DIR it removes whatever is at that path instead.
#
# WHY ROOT, ALWAYS, EVEN TO LOOK. pgdata's directories are mode 700 owned by
# uid 999, so `find` cannot descend as `me` — the manifest, not just the copy,
# needs root. And `me` has no NOPASSWD sudo here, so root comes from Windows:
#   printf '%s\n' 'cd /home/me/machines/hosts/g15/staging' './stage.sh …' \
#     | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
#
# WHY THE LAN ADDRESS AND NOT latitude.gg.ez. This distro runs in NAT
# networking mode, so tailscale cannot punch through to another NATed peer and
# the tailnet path is DERP-relayed via hub in Kazakhstan — 3.3 MB/s, re-measured
# 2026-09-07 with both laptops on a 1201 Mbps WiFi 6 link, so the radio was
# never the problem. NAT permits OUTBOUND, which is why pushing to latitude's
# LAN address gets 78 MB/s. 293 GB is 63 minutes one way and 20 hours the other.
#
# WHY rsync AND NOT THE CHUNKED TAR THE SPEC NAMES — a deliberate deviation.
# scratchpad/xfer2.sh was chunked because that transfer went through Windows
# sshd -> wsl.exe, where a raw tar stream was the only simple fast path. This
# route is the distro pushing outbound over plain ssh; rsync 3.4.1 is on both
# ends; and there are ZERO hardlinks in either ext4 tree (checked 2026-09-07:
# `find -type f -links +1` is empty for pgdata and for /home/me), which was the
# other thing tar bought. rsync then resumes per file with no marker
# bookkeeping AND lands an extracted tree — which is what the spec's own
# manifest check needs, since chunked tar would have to be extracted on arrival
# before it could be verified at all. The spec's requirement was resumability;
# this satisfies it with less to get wrong.
#
# --partial-dir, NOT --append-verify — the settled answer in this repo, see
# hosts/latitude/debian/archive-mirror.sh's header. A drop mid-file leaves a
# truncated file at the destination; --partial-dir parks it under
# .rsync-partial/ so it is never mistaken for a complete one, and rsync uses it
# as the delta basis next run. --append-verify assumes the destination is a
# strict prefix of the source, which a torn write does not guarantee.
#
# --rsync-path='sudo rsync' because `me` on latitude HAS NOPASSWD sudo (checked
# 2026-09-07) and pgdata's metadata is NOT uniform: 999:999 mode 600 files under
# directories that are 0:0 755, 999:0 700, 999:999 700 and 999:999 755. A
# blanket chown+chmod on restore would get it wrong, so ownership and modes are
# preserved numerically at copy time instead.
#
# NO pv, NO zstd — neither is installed and installing needs the password-gated
# sudo. --info=stats2 is the progress report.
set -uo pipefail

KEY="${STAGE_KEY:-/home/me/.ssh/id_fleet}"
LAT="${STAGE_LAT:-me@192.168.8.155}"
# Music goes to desktop, not latitude — his machine, his call. Port 2222 because
# .wslconfig puts desktop-wsl in mirrored networking, so the distro shares the
# Windows adapters and the Windows OpenSSH server already owns 22 (ssh.socket
# had been losing that bind race since 2026-08-29). Inbound 2222 needs a
# Windows firewall rule; it is in place, scoped to 192.168.8.0/24.
DESK="${STAGE_DESK:-me@192.168.8.145}"
DESK_PORT="${STAGE_DESK_PORT:-2222}"
STAGE="${STAGE_DIR:-/mnt/immich-mirror/g15-staging}"
DESKDIR="${STAGE_DESKDIR:-/mnt/c/Users/methe/g15-staging}"
LOGDIR="${STAGE_LOGDIR:-/var/log/g15-staging}"
PGPID="${STAGE_PGPID:-/data/qaz-law/pgdata/18/docker/postmaster.pid}"

# -i + IdentitiesOnly: ssh to a bare IP does NOT pick up the fleet identity,
# because the generated config keys on `Host *.gg.ez`. Without these it fails in
# 0.2 s having moved nothing, which reads exactly like no bandwidth — three
# false measurements on 2026-09-07 came from precisely this.
# ServerAlive*: a 40-minute transfer over wifi needs the connection probed, or a
# silent stall is indistinguishable from progress.
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

usage() {
    # A heredoc, not `sed -n '5,16p' "$0"`: a line-range into this file's own
    # header drifts silently the first time a comment is added above, and no
    # test catches it — the suite can only assert the exit code.
    cat >&2 <<'USAGE'
stage.sh — move g15's payload onto latitude. Runs ON g15-wsl, AS ROOT.

  ./stage.sh cmd          <payload> [kind]  print the rsync command, run nothing
  ./stage.sh manifest-cmd <payload> src|dst print the manifest pipeline, run nothing
  ./stage.sh plan         <payload> [delete] rsync -n: what would move (or remove)
  ./stage.sh stage        <payload>         the copy (logs to $LOGDIR; detach it)
  ./stage.sh restage      <payload>         a SECOND pass, with --delete
  ./stage.sh verify       <payload>         manifest both sides and diff
  ./stage.sh status                         sizes on both sides + log tails

  payload: pgdata | home  -> latitude (ext4)
           music          -> desktop  (NTFS, port 2222)
  kind:    go | dry | delete | delete-dry
  exit:    0 ok · 1 not root · 2 usage · 3 postgres running · 4 manifest
           mismatch · 5 restage into a missing or empty destination
USAGE
    exit 2
}
# "$1", NOT "$*": the second argument is the exit code, and $* would print it
# as part of the message — measured, the root refusal ended in a stray " 1".
die()  { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit "${2:-1}"; }
say()  { printf '[%s] %s\n' "$(date +%F_%H:%M:%S)" "$*"; }

# `verify` has no `exec >>` of its own the way `stage` does — it runs in the
# foreground and its output is meant to be read live. But Task 7's record step
# greps the payload logs for the verdict, so the verdict lines have to reach
# BOTH. Rendered once, so the two copies cannot carry different timestamps.
verdict() {
    local m; m="$(say "$*")"
    printf '%s\n' "$m"
    printf '%s\n' "$m" >>"$LOGDIR/$P.log"
}

require_root() {
    [ "$(id -u)" = 0 ] && return 0
    # $MODE/$P rather than "$@": the caller passes nothing, and the point of the
    # message is to hand back a runnable line.
    die "must run as root (pgdata's dirs are mode 700 owned by uid 999, so even
find cannot descend as $(id -un); and sudo needs a password on this distro).
Route:
  printf '%s\\n' 'cd $(cd "$(dirname "$0")" && pwd)' './${0##*/} $MODE $P' \\
    | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'" 1
}

payload_src() {
    case "$1" in
        pgdata) printf '%s\n' /data/qaz-law/pgdata ;;
        home)   printf '%s\n' /home/me ;;
        music)  printf '%s\n' /mnt/c/Users/methe/Music ;;
        *)      return 1 ;;
    esac
}

payload_dst() {
    case "$1" in
        pgdata) printf '%s\n' "$STAGE/pgdata" ;;
        home)   printf '%s\n' "$STAGE/home-me" ;;
        # Under the user's own directory: a mkdir at C:\ root is refused
        # without admin (measured 2026-09-07).
        music)  printf '%s\n' "$DESKDIR/Music" ;;
        *)      return 1 ;;
    esac
}

# WHY THE DESTINATION IS SPLIT. Two facts, both measured 2026-09-07 on desktop,
# and neither of them about free space:
#   - drvfs INVENTS ownership and modes. After chown 999:999 + chmod 600, stat
#     reads `me:me 777`. pgdata's files are 999:999 mode 600 under directories
#     in four different combinations, and /home/me carries .ssh — on NTFS both
#     arrive with fictional metadata and a restore would have to guess.
#   - drvfs costs 6.6 ms per file: 19.8 s for 3000 files against 0.03 s on ext4.
#     /home/me is 226003 files, so NTFS would add ~25 minutes of pure per-file
#     overhead. Music is 14878 files averaging 6 MB and loses nothing.
# desktop-wsl's own ext4 is not a third option: 99 GB total, 60 GB free.
#
# The cost is throughput: g15 and desktop are both on wifi, so their traffic
# crosses the access point twice — 40 MB/s measured, against 78 MB/s to
# latitude, which sits on cable (enp0s31f6). Music therefore takes ~37 minutes
# rather than ~19. Inherent to the path, not a setting.
payload_host() {
    case "$1" in
        pgdata|home) printf '%s\n' "$LAT" ;;
        music)       printf '%s\n' "$DESK" ;;
        *)           return 1 ;;
    esac
}

payload_port() {
    case "$1" in
        pgdata|home) printf '%s\n' 22 ;;
        music)       printf '%s\n' "$DESK_PORT" ;;
        *)           return 1 ;;
    esac
}

# `me` on latitude HAS NOPASSWD sudo; `me` on desktop-wsl does NOT — measured,
# it answers "sudo: A terminal is required to authenticate". A sudo there would
# hang a 37-minute transfer waiting for a password nobody can type, and Music
# needs no privilege anyway: drvfs would discard the metadata regardless.
payload_remote_sudo() {
    case "$1" in
        pgdata|home) printf '%s\n' yes ;;
        music)       printf '%s\n' no ;;
        *)           return 1 ;;
    esac
}

# The destination manifest must descend pgdata's mode-700 directories, so it
# needs root there; on desktop everything is drvfs and readable as `me`, and
# sudo would block on a password prompt.
remote_sh() {   # $1 payload
    case "$(payload_remote_sudo "$1")" in
        yes) printf '%s\n' 'sudo bash -s' ;;
        no)  printf '%s\n' 'bash -s' ;;
        *)   return 1 ;;
    esac
}

ssh_opts_for() {   # $1 payload
    local port
    port="$(payload_port "$1")" || return 1
    printf '%s' "$SSH_OPTS"
    [ "$port" = 22 ] || printf ' -p %s' "$port"
}

payload_flags() {
    # -x on every payload so the copy and the manifest's pruning agree about
    # where the tree ends.
    case "$1" in
        pgdata)
            printf '%s\n' -a -x --numeric-ids ;;
        home)
            # rsync cannot copy a socket; without the exclude it prints
            # "skipping non-regular file" and exits 23, which then has to be
            # distinguished from a real error on every run.
            printf '%s\n' -a -x --numeric-ids '--exclude=*.sock' ;;
        music)
            # drvfs invents ownership and permissions for every NTFS file, so -a
            # would copy fiction and then fail to set it. Same shape
            # archive-mirror.sh uses for exfat, for the same reason. mtimes ARE
            # real, hence -t and --modify-window=1 for the granularity.
            printf '%s\n' -rlt -x --no-perms --no-owner --no-group --modify-window=1 ;;
        *)  return 1 ;;
    esac
}

CMD=()
build_cmd() {   # $1 payload  $2 go|dry|delete|delete-dry
    local src dst host opts
    src="$(payload_src "$1")" || return 1
    dst="$(payload_dst "$1")" || return 1
    host="$(payload_host "$1")" || return 1
    opts="$(ssh_opts_for "$1")" || return 1
    local -a f=()
    mapfile -t f < <(payload_flags "$1")
    f+=(--partial --partial-dir=.rsync-partial '--exclude=.rsync-partial/'
        --human-readable --info=stats2)
    # --delete is opt-in by its own word and never a default. On the FIRST
    # pass into a fresh directory it is a no-op; on a mistyped STAGE_DIR it is
    # not. See the restage arm for the guard that goes with it.
    case "$2" in
        dry)        f+=(-n) ;;
        delete)     f+=(--delete) ;;
        delete-dry) f+=(--delete -n) ;;
    esac
    local -a rp=()
    [ "$(payload_remote_sudo "$1")" = yes ] && rp=(--rsync-path='sudo rsync')
    CMD=(rsync "${f[@]}" -e "ssh $opts" "${rp[@]+"${rp[@]}"}"
         "$src/" "$host:$dst/")
    return 0
}

# The manifest: PATH, type, size, symlink target — one line per entry, with a
# size for REGULAR FILES ONLY. A directory's reported size is a property of the
# filesystem rather than of its contents, so comparing it produces false diffs,
# and across drvfs -> ext4 it would make every single directory differ. Sockets
# are dropped on both sides because rsync never copies one. .rsync-partial is
# pruned: a parked torn file is not content.
#
# PATH IS THE FIRST FIELD, and that is not cosmetic. With the size first, `sort`
# orders by size as a STRING (5000 before 6), so the manifest is not in path
# order and one file whose size differs moves its line to a different position
# entirely — the diff then reports a large spurious block instead of pointing at
# the one path that is wrong. Caught while writing this plan, on exactly that
# tree of test entries.
#
# Compared on both sides with `diff`, and NEVER with `du`: du totals match even
# when one file is truncated, which is exactly what a killed transfer leaves.
manifest_find() {
    cat <<'MF'
LC_ALL=C find . -mindepth 1 -name .rsync-partial -prune -o \
  \( -type f -printf '%p\tf\t%s\n' \) -o \
  \( -type l -printf '%p\tl\t-\t%l\n' \) -o \
  \( -type s \) -o \
  \( -printf '%p\t%y\t-\n' \) | LC_ALL=C sort
MF
}

manifest_cmd() {   # $1 payload  $2 src|dst
    local d
    case "$2" in
        src) d="$(payload_src "$1")" || return 1 ;;
        dst) d="$(payload_dst "$1")" || return 1 ;;
        *)   return 1 ;;
    esac
    printf 'cd %q && \\\n' "$d"
    manifest_find
}

MODE="${1:-}"; P="${2:-}"; ARG="${3:-}"

case "$MODE" in
    cmd)
        [ -n "$P" ] || usage
        case "${ARG:-go}" in go|dry|delete|delete-dry) ;; *) usage ;; esac
        build_cmd "$P" "${ARG:-go}" || die "unknown payload: $P" 2
        printf '%q ' "${CMD[@]}"; printf '\n'
        ;;

    manifest-cmd)
        [ -n "$P" ] || usage
        case "$ARG" in src|dst) ;; *) usage ;; esac
        manifest_cmd "$P" "$ARG" || die "unknown payload: $P" 2
        ;;

    plan)
        [ -n "$P" ] || usage
        # `plan` means dry, so `plan <payload> delete` is the DRY delete pass:
        # it lists what --delete would remove, which is the whole point of
        # previewing it.
        case "${ARG:-}" in ''|dry) K=dry ;; delete) K=delete-dry ;; *) usage ;; esac
        build_cmd "$P" "$K" || die "unknown payload: $P" 2
        require_root
        say "dry run: $P"
        "${CMD[@]}"
        ;;

    stage|restage)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        # The guard comes BEFORE the root check so it is reachable in the gate,
        # and because "postgres is still running" is the more useful message of
        # the two when both are true.
        if [ "$P" = pgdata ] && [ -e "$PGPID" ]; then
            die "postgres is still running — $PGPID exists.
A live PGDATA copies torn, and the result looks exactly like a backup; see
hosts/latitude/debian/mirror-refresh.sh's header. Stop it first:
  docker update --restart=no qaz-law-db-1 && docker stop qaz-law-db-1" 3
        fi
        require_root
        K=go
        if [ "$MODE" = restage ]; then
            K=delete
            # A delete pass is only ever a SECOND pass. Refuse a destination
            # that does not already hold a first one: with --delete armed
            # against the wrong path, rsync removes what is there. The check
            # goes AFTER require_root so a non-root run in `just test` stops at
            # the root refusal instead of reaching for the network.
            dstq="$(payload_dst "$P")"
            q="$(printf 'test -d %q && [ -n "$(ls -A %q)" ]' "$dstq" "$dstq")"
            # A here-string, not a pipe: with pipefail on, a pipe would let the
            # writer's EPIPE outvote ssh's own exit code.
            ssh $(ssh_opts_for "$P") "$(payload_host "$P")" "$(remote_sh "$P")" <<<"$q" \
                || die "restage refuses: $(payload_host "$P"):$dstq is missing or empty.
A delete pass is only ever a SECOND pass over a destination that already holds
one. Run 'stage $P' first, or fix STAGE_DIR." 5
        fi
        build_cmd "$P" "$K" || die "unknown payload: $P" 2
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        # 755 so the log is tailable over the DIRECT ssh into the distro as
        # `me`, instead of every progress check having to go back through
        # Windows for root.
        exec >>"$LOGDIR/$P.log" 2>&1
        say "=== $MODE $P"
        say "src=$(payload_src "$P")  dst=$(payload_host "$P"):$(payload_dst "$P")"
        mk="mkdir -p $(payload_dst "$P")"
        [ "$(payload_remote_sudo "$P")" = yes ] \
            && mk="sudo $mk && sudo chown me:me $(payload_dst "$P")"
        ssh $(ssh_opts_for "$P") "$(payload_host "$P")" "$mk" </dev/null \
            || die "could not create the destination directory"
        "${CMD[@]}"; rc=$?
        case "$rc" in
            0)  say "rsync clean" ;;
            24) say "rsync exit 24 (source files vanished mid-run) — benign here, treating as done"; rc=0 ;;
            *)  say "rsync exit $rc — re-run '$MODE $P', it resumes from .rsync-partial" ;;
        esac
        say "=== done rc=$rc"
        exit $rc
        ;;

    verify)
        [ -n "$P" ] || usage
        payload_src "$P" >/dev/null || die "unknown payload: $P" 2
        require_root
        mkdir -p "$LOGDIR" && chmod 755 "$LOGDIR"
        s="$LOGDIR/$P.src.manifest"; d="$LOGDIR/$P.dst.manifest"
        say "manifest: source $(payload_src "$P")"
        manifest_cmd "$P" src | bash > "$s" || die "source manifest failed"
        say "manifest: destination $(payload_host "$P"):$(payload_dst "$P")"
        manifest_cmd "$P" dst | ssh $(ssh_opts_for "$P") "$(payload_host "$P")" \
            "$(remote_sh "$P")" > "$d" || die "destination manifest failed"
        sn=$(wc -l < "$s"); dn=$(wc -l < "$d")
        verdict "entries: src=$sn dst=$dn"
        if cmp -s "$s" "$d"; then
            verdict "MANIFEST MATCH — $sn entries, path+size+symlink-target identical"
        else
            verdict "MANIFEST MISMATCH — first 40 differing lines:"
            diff -u "$s" "$d" | head -40
            say "full manifests: $s and $d"
            exit 4
        fi
        ;;

    status)
        require_root
        for p in pgdata home music; do
            printf '%-7s %8s  %s\n' "$p" \
                "$(du -sh "$(payload_src "$p")" 2>/dev/null | cut -f1)" \
                "$(payload_src "$p")"
        done
        printf -- '--- destinations:\n'
        for p in pgdata home music; do
            dd="$(payload_dst "$p")"; pre=""
            [ "$(payload_remote_sudo "$p")" = yes ] && pre="sudo "
            printf '%-7s %s:%s\n' "$p" "$(payload_host "$p")" "$dd"
            ssh $(ssh_opts_for "$p") "$(payload_host "$p")" \
                "df -h ${dd%/*} | tail -1; ${pre}du -sh $dd 2>/dev/null" </dev/null \
                | sed 's/^/  /'
        done
        printf -- '--- logs:\n'
        for f in "$LOGDIR"/*.log; do
            [ -e "$f" ] || continue
            printf '%s:\n' "$f"; tail -3 "$f" | sed 's/^/  /'
        done
        ;;

    *)  usage ;;
esac
```

- [x] **Step 4: Run the suite to verify it passes**

```bash
chmod +x hosts/g15/staging/stage.sh
bash hosts/g15/staging/stage.test.sh
```

Expected: every line `PASS`, last line `ALL PASS`, exit 0.

- [x] **Step 5: Run the whole gate**

```bash
for t in $(just _test-suites); do bash "$t" < /dev/null || echo "FAILED: $t"; done
```

Expected: no `FAILED:` lines. (`just` is not installed on every box — on one without it, use `find . -name '*.test.sh' -not -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort` in place of `just _test-suites`, which is exactly what that recipe is.) The suite count goes from 49 to 50.

- [x] **Step 6: Commit and push**

```bash
git add hosts/g15/staging/stage.sh hosts/g15/staging/stage.test.sh
git commit -m "feat(g15): the phase-1 staging tool, and a suite that pins its flags

293 GB has to leave g15 correctly on the first attempt — the disk is wiped
after. So stage.sh separates composing an rsync command from running it, and
stage.test.sh asserts the composition on any box, non-root, with no network.

Deviates from the spec's chunked-tar mandate, deliberately: xfer2.sh was
chunked because it ran through Windows sshd -> wsl.exe, where a raw tar stream
was the only simple fast path. This route is the distro pushing outbound over
plain ssh, both ends have rsync 3.4.1, and neither ext4 tree has a single
hardlink. rsync resumes per file with no marker bookkeeping and lands an
extracted tree, which is what the spec's own manifest check needs."
git push
```

---

### Task 2: The three gates before a byte moves

**Files:**
- Create: `hosts/g15/staging/identity-snapshot.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: a live distro with a verified keepalive holder; `latitude:/mnt/immich-mirror/g15-staging/` existing and owned by `me`; the identity record committed.

- [x] **Step 1: Confirm OneDrive has actually finished uploading — by hand, on the box**

This is a **manual step and stays one.** The spec's disposition for `OneDrive` (3.7 GB: Documents, Desktop, Pictures) is *no action, already in the cloud* — and that is only true if the client has finished, not if the folder merely exists. There is no reliable command for "is OneDrive caught up"; the client's own UI is the authority.

On g15, in the Windows session: click the OneDrive cloud icon in the tray. It must read **"Your files are up to date"** — not "Syncing", not "Processing changes", not a paused icon. Then in File Explorer open `C:\Users\methe\OneDrive` and confirm the Status column shows green checks or cloud icons, with no ⟳ arrows.

**If it is NOT up to date:** let it finish before continuing. If it cannot finish (a stuck file, an account problem), OneDrive becomes a fourth payload rather than a no-action item — add these two arms to `stage.sh` and re-run its suite:

```bash
        onedrive) printf '%s\n' /mnt/c/Users/methe/OneDrive ;;   # in payload_src
        onedrive) printf '%s\n' "$STAGE/OneDrive" ;;             # in payload_dst
        onedrive)                                                # in payload_flags
            printf '%s\n' -rlt -x --no-perms --no-owner --no-group --modify-window=1 ;;
```

It reads through `/mnt/c` and is drvfs, so it takes the `music` flag set verbatim. 3.7 GB adds under a minute.

- [x] **Step 2: Re-arm the keepalive, and verify it by PID**

`State: Ready` means *not running*. The task last ran 2026-09-05 21:42 and exited `3221225786` (`STATUS_CONTROL_C_EXIT`) — it was killed. The distro is currently up only because stray `wsl.exe` clients from interactive sessions happen to be attached, and a distro dies when the last one detaches, taking any `setsid nohup`'d transfer with it.

From this box, base64 the script because PowerShell over ssh eats quotes:

```bash
SP=/tmp/claude-1000/-home-me-machines/scratch; mkdir -p "$SP"
cat > "$SP"/ka.ps1 <<'PS'
Start-ScheduledTask -TaskName 'wsl-keepalive'
Start-Sleep -Seconds 3
$i = Get-ScheduledTaskInfo -TaskName 'wsl-keepalive'
"state:  $((Get-ScheduledTask -TaskName 'wsl-keepalive').State)"
"lastrun: $($i.LastRunTime)  result: $($i.LastTaskResult)"
PS
iconv -f UTF-8 -t UTF-16LE "$SP"/ka.ps1 | base64 -w0 > "$SP"/ka.b64
ssh methe@g15.gg.ez "powershell -NoProfile -EncodedCommand $(cat "$SP"/ka.b64)"
```

Expected: `state: Running`.

Then the check that actually matters — the holder process inside the distro:

```bash
ssh g15-wsl.gg.ez 'ps -eo pid,user,args | grep -F "sleep infinity" | grep -v grep'
```

Expected: one line, `root ... /bin/sleep infinity`. **If that line is absent, stop here.** `State: Running` without the PID means the task fired and the client detached again, and a 40-minute transfer will not survive. Re-run `Start-ScheduledTask`; if the PID still never appears, hold the distro up for the duration with a foreground client instead and keep it open:

```bash
ssh -o ServerAliveInterval=30 methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- /bin/sleep 14400'
```

- [x] **Step 3: Create the staging root on latitude — and on desktop**

```bash
ssh latitude.gg.ez 'sudo mkdir -p /mnt/immich-mirror/g15-staging && \
  sudo chown me:me /mnt/immich-mirror/g15-staging && \
  df -h /mnt/immich-mirror && ls -ld /mnt/immich-mirror/g15-staging'
```

Expected: the directory exists owned by `me:me`, and `Avail` is at least **204 GB** — that is what latitude now takes, `Music` having moved to desktop. It was 610 GB on 2026-09-07. If it is under 350 GB, stop and find out what grew — the immich mirror shares this drive.

Then Music's destination on desktop. It must sit under the user's own directory: a `mkdir` at the `C:\` root is refused without admin.

```bash
ssh -p 2222 me@192.168.8.145 'mkdir -p /mnt/c/Users/methe/g15-staging && \
  df -h /mnt/c | tail -1 && ls -ld /mnt/c/Users/methe/g15-staging'
```

Expected: the directory exists and `/mnt/c` shows at least **90 GB** free; it was 1.2 TB on 2026-09-07. If that ssh is refused rather than timing out, `ssh.socket` in desktop-wsl is down again — see the Global Constraints for the override that fixes it.

- [x] **Step 4: Record the identity set**

The spec's phase 0 asks for the identities that must move together. Capture them from live commands rather than retyping them:

```bash
{
  printf 'g15 identity snapshot — %s\n' "$(date -u +%FT%TZ)"
  printf '\n## tailnet nodes (tailscale status)\n'
  tailscale status | grep -E '^100\.64\.0\.(3|9) '
  printf '\n## fleet-authorized-keys entries\n'
  grep -n -E 'methe@g15$|me@g15-wsl$' provision/fleet-authorized-keys
  printf '\n## dotfiles branches\n'
  printf 'g15-wsl: %s\n' "$(ssh g15-wsl.gg.ez 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD')"
  printf '\n## what phase 5 does with each of these\n'
  cat <<'NOTE'
100.64.0.3  g15      windows -> becomes linux; the NODE IS KEPT, g15 inherits it
100.64.0.9  g15-wsl  linux   -> RETIRED with the distro
fleet-authorized-keys: methe@g15 kept; me@g15-wsl removed
dotfiles branch g15-wsl: retired. Its host-local content is not on main, so the
  only copies of those files are the branch on the remote and the /home/me
  staging copy from Task 6. Do not delete the branch in phase 5 — leave it.
NOTE
} > hosts/g15/staging/identity-snapshot.txt

cat hosts/g15/staging/identity-snapshot.txt
```

Expected: two tailnet rows, two `fleet-authorized-keys` line numbers (40 and 41 as of `de1fad2`), and `g15-wsl: g15-wsl`.

- [x] **Step 5: Commit the snapshot**

```bash
git add hosts/g15/staging/identity-snapshot.txt
git commit -m "docs(g15): the identity set phase 1 has to preserve

Captured live rather than retyped. The load-bearing line is the last one: the
g15-wsl dotfiles branch holds host-local files that are on no other branch, so
retiring the distro in phase 5 must not delete the branch."
git push
```

---

### Task 3: Quiesce postgres and prove the shutdown was clean

**Files:** none — this task changes state on g15-wsl only.

**Interfaces:**
- Consumes: Task 2's live distro.
- Produces: `postmaster.pid` absent from `/data/qaz-law/pgdata/18/docker`, which is what unblocks `stage.sh stage pgdata`.

- [x] **Step 1: Take the restart policy off the container first**

`qaz-law-db-1` has `restart: always`. Stopping it by hand is not enough — a docker daemon restart, or a WSL bounce, brings postgres back up and starts writing into the tree that is being copied. Set the policy before the stop, so there is no window:

```bash
ssh g15-wsl.gg.ez 'docker update --restart=no qaz-law-db-1 && \
  docker inspect qaz-law-db-1 --format "restart={{.HostConfig.RestartPolicy.Name}}"'
```

Expected: `restart=no`.

This is **not undone.** The container dies with the disk in Phase 2; the new box gets a fresh one in Phase 4. Restoring `always` here would only reopen the hole.

- [x] **Step 2: Stop the container**

```bash
ssh g15-wsl.gg.ez 'docker stop -t 120 qaz-law-db-1 && \
  docker inspect qaz-law-db-1 --format "state={{.State.Status}} exit={{.State.ExitCode}}"'
```

Expected: `state=exited exit=0`. The `-t 120` matters: `docker stop`'s default 10-second grace, on a 186 GB database with 8 GB of shared buffers, can expire mid-checkpoint and escalate to `SIGKILL`, which is an unclean shutdown — recoverable by postgres, but it leaves a WAL replay that a *physical copy* then has to carry, and there is no reason to accept that when waiting is free.

- [x] **Step 3: Prove the shutdown was clean — two independent checks**

```bash
ssh g15-wsl.gg.ez 'docker logs --tail 20 qaz-law-db-1 2>&1 | tail -8'
```

Expected: the log ends with `database system is shut down`. Absent that, look for `received smart shutdown request` / `shutting down` / `checkpoint complete` and no `received immediate shutdown request`.

The log line can scroll, so check the file-level evidence too:

```bash
printf '%s\n' \
  'ls -l /data/qaz-law/pgdata/18/docker/postmaster.pid 2>&1' \
  'echo "---"' \
  'ls -1 /data/qaz-law/pgdata/18/docker/ | head -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `No such file or directory` for `postmaster.pid`. **A present `postmaster.pid` after an `exited` container means the shutdown was not clean** — start the container, stop it again with `-t 120`, and re-check. `stage.sh` refuses with exit 3 while that file exists, so this check and the tool agree.

---

### Task 4: Stage `pgdata` — 186 GB, ~40 minutes

**Files:** none — this task produces `latitude:/mnt/immich-mirror/g15-staging/pgdata/`.

**Interfaces:**
- Consumes: Task 1's `stage.sh` (present on g15-wsl at `/home/me/machines/hosts/g15/staging/`), Task 2's staging root, Task 3's stopped postgres.
- Produces: the staged tree, and `/var/log/g15-staging/pgdata.log`.

- [x] **Step 1: Get the tool onto the box**

`~/machines` on g15-wsl is a normal checkout (at `de1fad2`, clean, as of 2026-09-07):

```bash
ssh g15-wsl.gg.ez 'cd ~/machines && git pull --ff-only && \
  ls -l hosts/g15/staging/stage.sh && git log --oneline -1'
```

Expected: the file is present and executable, and HEAD is at or past **Task 1's** commit — that is the one that adds `stage.sh`. Task 2's identity-snapshot commit is later and irrelevant here; the plan document itself (`c331260`) does not contain the tool.

- [x] **Step 2: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan pgdata 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: rsync's stats block reporting about **1268 regular files and ~186 GB** to transfer, and no `Permission denied`. If it reports 0 files, the destination already holds the tree — check `stage.sh status` before assuming the source is empty.

- [x] **Step 3: Launch it detached**

`setsid --fork` so it survives the ssh session; the script redirects its own output to the log, so no shell redirection has to survive PowerShell:

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage pgdata' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage pgdata" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line showing the running script. No output there means it exited immediately — read the log in the next step for why.

- [ ] **Step 4: Watch it — at the DESTINATION, not in the log**

`tail -f` on the log is the obvious move and it shows nothing for 40 minutes. There is no `--progress`; `--info=stats2` prints its block only when rsync finishes, so the log holds two header lines and then goes silent until the end. That reads exactly like a dead transfer. Confirm the header once, then watch the destination grow:

```bash
ssh g15-wsl.gg.ez 'head -3 /var/log/g15-staging/pgdata.log'
ssh latitude 'sudo du -sh /mnt/immich-mirror/g15-staging/pgdata; date +%T'
```

**The `sudo` is not optional.** rsync recreates the tree with its numeric ownership, so `18/docker` arrives as mode 700 owned by uid 999 and an unprivileged `du` reports `0` for the entire payload — which looks like a transfer that never started. Sample twice a minute apart to get the rate. Measured on the real run: 38 GiB at 9 minutes, ~72 MB/s, done in **~45 minutes**.

Also note `ssh me@192.168.8.155` fails from desktop-wsl with `Host key verification failed` — `known_hosts` carries the tailnet name. Use the `latitude` alias for these checks; the transfer itself uses the IP with the fleet identity and is unaffected.

If it dies mid-run, re-run Step 3 verbatim — rsync picks the partial file up from `.rsync-partial/` and continues. That is what `--partial-dir` is for.

- [ ] **Step 5: Confirm it finished cleanly**

```bash
ssh g15-wsl.gg.ez 'tail -6 /var/log/g15-staging/pgdata.log'
```

Expected: `rsync clean` then `=== done rc=0`. Any other `rc` is reported with the resume instruction; re-run Step 3. **Do not proceed to Task 5 on a non-zero rc** — the link is shared and a half-finished payload competing with the next one only makes both slower.

- [ ] **Step 6: Verify `pgdata` NOW, before launching Music**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify pgdata' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `entries: src=1298 dst=1298`, then `MANIFEST MATCH`.

Task 7 verifies all three, and this step does not replace it — it front-loads the one payload whose destination-side manifest exercises something no test could: a root-owned, mode-700 tree read back through `sudo bash -s`. The suite pins how the command is composed, never that it can read that tree. If the verify mechanism is broken, this is the cheap place to find out; after three transfers it costs the whole ninety minutes again. `pgdata` is also the only payload that cannot change under us — postgres is stopped and stays stopped — so a match here is final.

---

### Task 5: Stage `Music` — 89 GB, ~37 minutes, to DESKTOP

**Files:** none — this task produces `desktop:C:\Users\methe\g15-staging\Music\`.

**Interfaces:**
- Consumes: Task 1's `stage.sh`, Task 4's finished transfer. **Still run one at a time, though the shared link is no longer the reason** — Music crosses a different link to a different host now. What is shared is g15's radio: 78 + 40 MB/s is 944 Mbps against a 1201 Mbps nominal association, so running both would bid against itself for a marginal gain and give up clean failure attribution.
- Produces: the staged tree, and `/var/log/g15-staging/music.log`.

- [ ] **Step 1: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan music 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: about **14 878 files and 94.81 G bytes** (the same 88.3 GiB the spec names — rsync reports decimal). Read from `/mnt/c/Users/methe/Music` inside g15's distro and written to `/mnt/c/Users/methe/g15-staging/Music` inside desktop-wsl, so drvfs is on both ends; there is no separate Windows-side transfer, and `desktop.ini` in that tree is expected and harmless. **Confirm the destination line reads `me@192.168.8.145`, not latitude.**

- [ ] **Step 2: Launch it detached**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage music' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage music" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line.

- [ ] **Step 3: Watch it and confirm**

```bash
ssh g15-wsl.gg.ez 'tail -f /var/log/g15-staging/music.log'
```

Expected: `rsync clean`, `=== done rc=0`, in **~37 minutes**. Two independent reasons it runs behind the byte budget, both measured and neither a fault: the link is 40 MB/s because g15 and desktop are both on wifi and the traffic crosses the access point twice, and drvfs is on both ends at 6.6 ms per file. 14 878 files averaging 6 MB is the one payload where that per-file cost is affordable.

---

### Task 6: Stage `/home/me` — 18 GB, first pass

**Files:** none — this task produces `latitude:/mnt/immich-mirror/g15-staging/home-me/`.

**Interfaces:**
- Consumes: Task 1's `stage.sh`, Task 5's finished transfer.
- Produces: the staged tree, and `/var/log/g15-staging/home.log`. **This copy is not final** — Task 8 re-runs it as a delta with the box quiesced.

- [ ] **Step 1: Dry run**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan home 2>&1 | tail -20' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: roughly **226 000 files and ~18 GB**, and no `skipping non-regular file` lines — `--exclude=*.sock` covers the two orca sockets. If such a line does appear, a new socket was created under a name that does not end in `.sock`; add it to the exclude list rather than accepting exit 23.

- [ ] **Step 2: Launch it detached**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  'setsid --fork ./stage.sh stage home' \
  'sleep 3' \
  'ps -eo pid,etime,args | grep -F "stage.sh stage home" | grep -v grep' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: one `ps` line.

- [ ] **Step 3: Watch it and confirm**

```bash
ssh g15-wsl.gg.ez 'tail -f /var/log/g15-staging/home.log'
```

Expected: `rsync clean`, `=== done rc=0`. 18 GB is 4 minutes of bytes, but 226 000 files carry real per-file cost, so budget **10–20 minutes**.

`rc=24` (source files vanished mid-run) is treated as done by the script, and on a live home directory it is the *likely* outcome — a shell history file or an editor swap file disappearing between the file list and the transfer. That is precisely why Task 8 exists and why this pass is not the one the manifest is taken from.

- [ ] **Step 4: Check the total against the budget**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh status' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: source sizes near 186G / 18G / 89G, and destination sizes within a percent or two of each.

**The free-space expectation is per host now, and this line said otherwise until the split.** latitude receives `pgdata` + `/home/me` only, about **205 GB**: `Avail` on `/mnt/immich-mirror` goes from 610 GB to roughly **405 GB**. Music's 89 GB lands on desktop's `C:`, which had 1.2 TB free. The old "down by about 293 GB to roughly 315 GB" was the all-on-latitude number — chasing the missing 90 GB, or waving it through, are both worse than the number being right.

**These `du` numbers are orientation, not verification.** A `du` total matches even when one file is truncated, which is exactly what a killed transfer leaves behind. Task 7 is the verification.

---

### Task 7: Verify all three payloads by manifest

**Files:** none — this task reads both sides and writes manifests to `/var/log/g15-staging/`.

**Interfaces:**
- Consumes: Tasks 4, 5 and 6.
- Produces: `<payload>.src.manifest` and `<payload>.dst.manifest` on g15-wsl for each payload, and a `MANIFEST MATCH` line for each.

- [ ] **Step 1: Verify `pgdata`**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify pgdata' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `entries: src=N dst=N` with the two equal, then `MANIFEST MATCH — N entries, path+size+symlink-target identical`. Exit 4 with a diff means a real discrepancy: re-run `stage.sh stage pgdata` (it resumes), then verify again.

Task 4 Step 6 already ran this. Re-running is free and idempotent — postgres is stopped, so nothing on either side has moved — but if it was recorded there, reading `/var/log/g15-staging/pgdata.log` is enough.

- [ ] **Step 2: Verify `music`**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify music' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `MANIFEST MATCH`. Note what this check deliberately does not compare: mode, ownership and mtime. On drvfs all three are invented by the filesystem, so comparing them would report thousands of differences that mean nothing. Path, size and symlink target are the content.

- [ ] **Step 3: Verify `home` — and expect a small mismatch here**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify home' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: **either** `MANIFEST MATCH`, **or** exit 4 with a handful of differing lines under `.cache/`, `.local/state/`, `.bash_history`, `.zsh_history`, `.config/orca/` or a `.claude/projects/` transcript.

A mismatch here is not a failure of the copy — `/home/me` is a live tree and the manifest is taken minutes after the transfer. Read the diff and confirm every differing line is a file that changed after the copy, then continue: Task 8 is what settles it. **A differing line anywhere else — under `my/`, `.ssh/`, `.gnupg/` — is a real problem and stops the plan.**

- [ ] **Step 4: Record the three verdicts where the next phase can find them**

```bash
ssh g15-wsl.gg.ez 'grep -h MANIFEST /var/log/g15-staging/*.log | tail -20'
```

Expected: one `MANIFEST MATCH` line for `pgdata` and one for `music`, each naming its entry count. Those two are now final and must not be re-copied: `pgdata` because postgres is stopped and stays stopped, `music` because nothing on the box writes to it.

---

### Task 8: The final `/home/me` delta — the point of no return

**Files:** none.

**Interfaces:**
- Consumes: Tasks 4 through 7.
- Produces: a `MANIFEST MATCH` for `home` taken on a quiesced box. **This is the gate the spec names: "phase 1's manifest check is the point of no return and must pass before the installer boots."**

**Run this immediately before Phase 2, not right after Task 7.** Days may pass between them; that is fine and expected. What must not happen is booting the installer on the strength of Task 7's `home` verdict, which was taken while the box was in use.

- [ ] **Step 1: Quiesce the box**

Close every editor, terminal, Orca window and agent session that writes under `/home/me` on g15-wsl. Then confirm nothing is still writing:

```bash
ssh g15-wsl.gg.ez 'who; echo "---"; ps -eo user,pid,args | grep -E "^me " | grep -vE "sshd|ps -eo|grep" | head -20'
```

Expected: only the ssh session running this check. A leftover `orca`, `node`, `claude` or shell is what makes this pass unreliable — end it before continuing. The one process that must **stay** is the keepalive's `sleep infinity`, which runs as root and does not appear in this list.

- [ ] **Step 2: Run the delta**

Small enough to run in the foreground and watch:

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh plan home delete' \
  './stage.sh restage home' \
  'tail -20 /var/log/g15-staging/home.log' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: the `plan … delete` line first lists what would be REMOVED at the
destination — read it before the real pass; a long list of live-looking files
means something is wrong with the path, not with the copy. Then a few hundred MB
at most, `rsync clean`, `=== done rc=0`. A large delta means something is still
running — go back to Step 1.

**`restage`, not `stage`, and that is the whole reason this step can pass.**
Task 6 copied `/home/me` days ago; anything deleted under it since then still
sits at the destination, and Step 3 below demands an exact manifest match. A
plain second `stage` never removes it, so the gate would fail on a copy that is
otherwise correct. `restage` is `stage` plus `--delete`, and it refuses (exit 5)
a destination that does not already hold a first pass.

- [ ] **Step 3: Verify, and this time demand an exact match**

```bash
printf '%s\n' \
  'cd /home/me/machines/hosts/g15/staging' \
  './stage.sh verify home' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `MANIFEST MATCH`, exit 0, **no tolerated differences.** Unlike Task 7 Step 3, a diff here is a stop: either something is still writing (back to Step 1) or the copy is genuinely incomplete (re-run Step 2).

- [ ] **Step 4: Re-confirm `pgdata` has not moved since Task 7**

Cheap, and it catches the one thing that silently invalidates the largest payload — postgres having been started again in the meantime:

```bash
printf '%s\n' \
  'ls -l /data/qaz-law/pgdata/18/docker/postmaster.pid 2>&1' \
  'docker inspect qaz-law-db-1 --format "state={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}}" 2>&1 </dev/null' \
  | ssh methe@g15.gg.ez 'wsl -d Ubuntu-26.04 -u root -- bash -s'
```

Expected: `No such file or directory`, and `state=exited restart=no`. If postgres was started, its manifest is stale: stop it again per Task 3 and re-run `stage.sh stage pgdata` and `verify pgdata` before the installer boots.

- [ ] **Step 5: Declare phase 1 done, and say what that permits**

```bash
ssh g15-wsl.gg.ez 'grep -h MANIFEST /var/log/g15-staging/*.log | tail -6; \
  echo "---"; ls -l /var/log/g15-staging/*.manifest'
ssh latitude.gg.ez 'df -h /mnt/immich-mirror; sudo du -sh /mnt/immich-mirror/g15-staging/*'
```

Expected: a `MANIFEST MATCH` for each of `pgdata`, `music` and `home`; three payload directories on latitude totalling ~293 GB; `Avail` around 315 GB.

**With those three lines present, Phase 2 may boot the installer. Without all three, it may not.** Nothing on g15 has been destroyed up to this point, so this is the last moment at which rollback is free.

The staging copy stays on latitude until the rebuilt box has run for a week, then is deleted deliberately — not left to be reclaimed by accident.

---

## Self-review

**Spec coverage.** Phase 0's OneDrive confirmation → Task 2 Step 1; its identity record → Task 2 Steps 4–5. Phase 1's transport (`ssh -i ~/.ssh/id_fleet -o IdentitiesOnly=yes me@192.168.8.155`) → `stage.sh`'s `SSH_OPTS` and `LAT`, pinned by the suite. Its item 1 (stop postgres cleanly) → Task 3, with two independent proofs. Its item 2 (resumable, an interruption costs one chunk) → satisfied by `--partial-dir` per-file resume instead of chunk markers, which is a **stated deviation** argued in `stage.sh`'s header and in Task 1's commit message: xfer2.sh's chunking existed because that route ran through `wsl.exe`, and rsync additionally lands the extracted tree the manifest check requires. Its item 3 (`Music` via `/mnt/c`) → Task 5. Its manifest check, "never by `du`" → Task 7 and `stage.sh verify`, with the `du` reach explicitly failed by the suite. Its budget (~1 h 5 m) → 40 + 19 + 15 minutes across Tasks 4–6. Its point-of-no-return rule → Task 8.

Two things this plan adds that the spec does not state. The keepalive gate (Task 2 Step 2) — the spec assumes the distro stays up, and it is currently held only by stray `wsl.exe` orphans while the task that should hold it died on 2026-09-05. And the final quiesced `/home/me` delta (Task 8) — the spec says the manifest check is the point of no return without saying that a manifest of a *live* home directory cannot be that check.

One spec item is deliberately out of scope: `Downloads` (2.2 GB, "owner reviews before the wipe"). That is a human review with no staging step, and inventing a copy for it would contradict the spec's own disposition. It belongs in Phase 2's pre-wipe checklist.

**Both code blocks were extracted from this document and run before it was committed**, on desktop-wsl, non-root, with no g15 and no latitude involved. `bash -n` passes on both; the suite reports **ALL PASS** (77 assertions) against the script exactly as written above, and the blocks are regenerated from the files, so the two cannot drift. Three defects were found that way and are fixed in the text: the manifest sorted by size-as-a-string instead of by path; `die()` printed `"$*"`, appending its exit-code argument to the message (the root refusal ended in a stray ` 1`); and `usage()` was a `sed` line-range into the script's own header, which drifts the first time a comment is added above it. **A fourth defect survived all of that and is the one worth learning from:** `require_root` compared a leaked literal to `0` and therefore refused even uid 0, killing `plan`, `stage`, `verify` and `status` — and the suite could not see it, because both of its root assertions checked the refusal, which a require_root broken in the other direction still produces. Extracting and running a script only proves the paths you actually take; `cmd` and `manifest-cmd` were the only modes reachable without root, and they never call it. The suite now shims `id -u` to 0 and asserts the accept path. Every assertion added for these four defects, and for the `restage` delete pass, was mutation-tested by reintroducing the bug it guards. The manifest pipeline was separately run against a tree carrying a regular file, a symlink, a broken symlink, a fifo, a socket and a `.rsync-partial/` directory, and handles all six as this plan claims.

**The repo gate was not re-run for this change and does not need to be** — the change adds a markdown file and no executable. `stage.sh` and its suite land in Task 1, and Task 1 Step 5 runs the gate there.

**Placeholder scan.** No `TBD`, no "add error handling", no "similar to Task N". Every code step carries the code. The one manual step (Task 2 Step 1) is manual on purpose and says exactly what to look at, with the concrete four-line fallback if the answer is no.

**Name consistency.** Payload tokens are `pgdata` / `home` / `music` everywhere — in `payload_src`, `payload_dst`, `payload_flags`, the `stage.sh` modes, the suite's loop, and every task's commands. Destination directories are `pgdata` / `home-me` / `Music` (asymmetric on purpose: `home-me` names the box's user, `Music` matches what comes back). Env overrides are `STAGE_LAT` / `STAGE_DIR` / `STAGE_KEY` / `STAGE_LOGDIR` / `STAGE_PGPID`, all read in `stage.sh` and the last three exercised by the suite. Log paths are `/var/log/g15-staging/<payload>.log` in the script and in every task that tails one. Exit codes 0/1/2/3/4 are defined in the header, produced by `require_root`, `usage`, `die … 3` and `verify`, and asserted by the suite.
