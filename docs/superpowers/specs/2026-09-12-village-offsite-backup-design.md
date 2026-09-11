# Offsite backup site: a box in the village

**Status:** design, approved in direction 2026-09-12. Not started.
**Site:** the owner's family house near Karaganda — mother and grandmother live
there, residential fibre, nobody on site who can administer anything.
**Closes:** the standing offsite gap. `AGENTS.md` and project memory have both
carried *"every copy is in one apartment"* since 2026-07-31, with Task 19 of the
migration plan owning it.

## Why this shape, in one paragraph

Every copy of the irreplaceable data is in one Almaty apartment. The plan of
record was *rotate one dock's drive off-site*; the owner rejected it — he visits
every few months and does not want to carry drives on each trip. So: one live
box in the village, seeded once by carrying a drive on the next trip, then fed
deltas over the fibre link forever.

**The load-bearing arithmetic:** 663 of the 956 GB payload is the closed
1970–2024 archive. It is write-once. It packs once, travels once, and never
uploads again. Steady state is only new immich photos — hundreds of MB/day.
That is why a residential uplink is sufficient, and it is the fact to re-check
if anyone ever proposes cloud storage instead.

## The payload

| Source | Size | Why it goes |
|---|---|---|
| `/mnt/immich` live library | 293 GB | irreplaceable, growing |
| `/mnt/immich-2024` archive 1970–2024 | 663 GB | irreplaceable, **frozen** |
| `/mnt/wd8/restic-rest` (hub: g513ie + g614jv) | 112 GB | only copy of those boxes' data |
| `/mnt/wd8/restic` (latitude's own) | 12 GB | pg_dumpall, ServarrConfig, `~/my/vps` `.env` files |

**Not going:** `Media/movies|torrents|tv|xxx` and everything else re-derivable.
The repo rule is *mirror the bulk, restic almost nothing*; offsite narrows that
further to *only what cannot be re-obtained*.

## Decisions, with the reasoning that is not re-derivable

### Photos move into restic — and this is new

Today the 956 GB of photos travel as plain `rsync` mirrors. Only the 124 GB of
restic repos are encrypted. Putting the photos in restic buys three things at
once: encryption (so a drive living in a house the owner does not occupy needs
no LUKS, and no unattended-unlock problem exists), delta transfer, and versions
— which mirrors have never given the photos.

**The July constraint that blocked this is dead.** *"No drive in the fleet has
815 G free for a restic repo"* was the recorded reason for choosing mirrors.
`/mnt/wd8` now has 6.4 T free.

**Separate repo from `14f4eab544`.** Merging would make the Sunday
`check --read-data-subset 5%` and `prune` on the 12 GB critical set cost ~80×
what they cost now.

**The mirrors stay.** Their second reason survives the space argument: a mirror
is directly browsable, a repo needs a restore. Local recovery stays fast;
offsite is the encrypted, versioned copy. Additive, not a replacement.

**Accepted tradeoff, stated deliberately:** with no second local copy of the
photo repo, recovery from the owner's own `rm` becomes a restore over the
internet. This is a choice, not an accident.

### Direction of trust: the village is append-only

latitude pushes; it cannot delete. `rest-server --append-only`, and `prune` runs
on the village box with its own key. Precedent: `g614jv-maintenance` already
does exactly this for desktop-wsl's repo on latitude's filesystem.

A compromised or misbehaving Almaty then does not take the offsite copy with it.

**The village rest-server must NOT inherit the hub's `--no-auth` posture.** On
latitude, reachability *is* authorisation, and that is defensible on a tailnet
bind on hardware in the owner's own flat. The village box sits on an ISP router
he does not control, in a house with other residents. Bind to the tailnet
address only **and** enable auth.

### Two mechanisms, because the data differs

- **Photos → restic** to `rest:` on the village box. Nightly, after latitude's
  own 04:30 job.
- **The two restic repos → `rsync` over ssh, without `--delete`.** Pack files
  are immutable once written, so a no-delete rsync is append-only by
  construction. Backing up an encrypted repo *with* restic would dedupe nothing
  — the blobs are already random.

### Storage: HDD, and the owner's retention argument is not the reason

Agreed outcome (8 TB HDD), corrected reasoning:

- **Unpowered retention does not apply here.** The box is always on; an SSD
  controller refreshes its cells. Retention matters for a drive on a shelf —
  i.e. for the rotated-drive plan that was rejected.
- **The real argument for HDD, besides price: it dies gradually and warns via
  SMART.** SSDs more often fail at once. Where nobody is on site, weeks of
  warning is the difference between a planned trip and a lost copy. The fleet
  already has `disk-acceptance.sh` and `smart-long.sh` for this.
- **Price, in the owner's market:** his WD80EAAZ 8 TB cost 180 000 ₸. US
  price-per-TB figures ($150-class 8 TB) do not apply in KZ; a 4 TB SATA SSD is
  the more expensive purchase there, not the cheaper one.

**Consequence for the chassis:** an internal 2.5" HDD caps at 2 TB, which is the
capacity already rejected as having no headroom. So the box must take a **3.5"
drive internally** — never in a USB dock. Eight dock drops in six weeks on
latitude were caused by mains dips, and there is nobody in the village to
power-cycle a brick.

**Fanless is therefore off the table, and that is fine.** The dust objection
assumed a box nobody visits; the owner visits every few months, which is exactly
the right interval to blow out a fan.

### Capacity: headroom goes in the chassis, not the drive

8 TB now against a 956 GB payload. If the family moves onto `immich.cyphy.kz`
(the girlfriend alone has ~2 TB of media), **Almaty runs out first**:
`/mnt/immich` is 916 GB with 614 GB free, so that scenario is blocked on local
storage, not on the offsite box. Size the village box for growth by leaving a
slot free, and buy the second drive when the scenario is real.

## Hardware acceptance criteria

Check before buying, not after:

- **BIOS "restore on AC power loss" set to `Power On`** — not `Last State`, not
  absent. It is named differently by every vendor (`Restore AC Power Loss`,
  `State After G3`, `After Power Failure`, `AC Recovery`). Homelab write-ups
  report it defaulting to off on consumer mini-PCs and sometimes missing
  entirely on cheap boards — **not verified against a vendor manual here, so
  check the manual of the specific model before ordering.** This is the single
  setting that makes the site self-recovering, which is the whole premise the
  owner chose.
- **One internal 3.5" bay + one M.2 slot** (M.2 for the OS, 3.5" for data),
  with a second data slot free for later growth.
- **8 GB RAM or more.** `prune` and `check` run here. On a memory-starved box
  the kernel OOM killer does not fire — it grinds swap and freezes; that is why
  `tier_oom_guard` exists.
- **Wired Ethernet.** No Wi-Fi dependency.
- Class: NAS-style mini (Aoostar / Beelink ME / CWWK / Topton), not a fanless
  N100 stick.

**Wake-on-LAN is not a requirement and does not help.** The box is always on,
and when mains drops the NIC is dead too. The BIOS setting above replaces it.

**UPS is optional**, given auto-power-on. Worth adding if the village turns out
to have frequent short dips.

### Drive acceptance is on the critical path to the trip

`hosts/latitude/debian/disk-acceptance.sh`, both gates, in order: `identity`
first (it runs on the shop's return clock — this is the gate that catches a
fraudulent sale, which a surface test alone passes), then `surface`.
`badblocks -w` on 8 TB is multiple days. **Buy with weeks of margin, not the
week before departure.**

## Seeding

The repo cannot be carried before it is created.

1. **Free a dock bay.** All four bays are occupied: `u4-1:0` spare320, `u4-1:1`
   HGST (`immich-2024-backup`), `u4-2:0` wd8, `u4-2:1` immich-2024. The only
   candidate is **spare320** (`u4-1:0`), whose contents are the already-migrated
   restic copies awaiting retirement. Retire them on proof (content hashes),
   not on elapsed days.
2. **Seed drive goes in dock A (`usb4/4-1`), never dock B.** The archive source
   `immich-2024` sits on `4-2:1` and shares one 5 Gbps link with wd8 on `4-2:0`.
   Putting the destination on the same dock is the exact mistake the 2026-09-10
   archive copy was routed around. Measure topology (`udevadm info -q path -n
   sdX`) before choosing a bay, not capacity.
3. `restic init` on the travel drive, full backup into it at local speed.
4. Baseline `restic check` **at the source, before travel**. A failed check at
   the destination is otherwise unexplainable.
5. Carry, install in the village box, serve with `rest-server --append-only`.
6. latitude switches to `restic backup` straight at `rest:` — no `restic copy`,
   no second local repo. Nightly runs then upload only new photos.

### Measure on the trip

None of these are guessable from Almaty:

- **Upload speed specifically.** "Good speed" is almost certainly the download
  figure; upload is what this design consumes.
- **`tailscale ping latitude`** — direct or DERP. A relayed pair goes through
  hub's DERP on a metered VPS in Almaty. Note it, do not accept it silently:
  the repo already lost a migration design to a stale *"expected and accepted"*
  DERP claim.
- **Whether the village ISP does the TLS-SNI filtering Almaty's does**
  (recorded in global memory, measured 2026-09-09).

## Alerting is a gating deliverable, not a follow-up

The village box will be the least-observed machine the owner has: one drive, no
admin on site, 900 km away. An offsite copy nobody verifies is a *belief* in a
second copy.

The fleet has eaten this failure twice — the `server` immich tasks reported
`State: Ready` while every run failed for 13 days, and the REST hub served 401
for 2 days while `systemctl show -p Result` said `success`.

Deliverables, both before the site is trusted:

- **`sb_backup_alerts`** in `provision/statusboard/statusboard.sh`, keyed on
  newest-snapshot age. Already named in project memory as the right home and
  still not built. Fixture-testable severity policy, like `sb_fleet_alerts` and
  `sb_docker_alerts` beside it.
- **`restic check` on the village box**, on a timer, with its result visible
  from Almaty. Checking from Almaty over the link is not equivalent — it cannot
  distinguish "repo is fine" from "link is down".

Note for whoever writes the freshness check: snapshot age is a *client*
liveness signal too, so it fires when the source box is merely asleep. Check 8
of the hub selfcheck has exactly this property and is documented as unusable as
a sentinel for that reason.

## Fleet integration

- **Logical name: `offsite`.** Role-based, per the naming rule. Recorded risk:
  `server` was renamed for exactly this reason once the role moved. If a second
  offsite site ever exists, rename to the place name then — a rename moves the
  tailnet node, the dotfiles branch and `fleet-authorized-keys` in one change.
- **`platform: debian`** in `fleet.json` whatever apt distro is installed. The
  token is a platform *class*; `ubuntu` makes every posix role executor print
  "no posix executor (skipped)" and return 0 while `--apply` reports success.
- **New role `backup-offsite`** — rest-server with auth + append-only, the
  rsync landing directory, `prune`, `check`. Distinct from `backup-hub`, whose
  posture (`--no-auth`, no append-only) is deliberately the opposite.
  **Implementing it means deleting its name from `PLANNED_ROLES`**, or the
  executor is never demanded of the box that needs it.
- Roles: `base, ssh-server, backup-offsite`. No `agents`, no `repos` — this is
  an appliance.
- New Headscale node + `fleet-authorized-keys` entry + dotfiles branch, together.
- `restic` and `resticprofile` are static binaries; user scope, `~/.local/bin`,
  no root needed for the client side.

## Out of scope, recorded once

Mother's and grandmother's phone photos are backed up nowhere. The owner's
answer: they do not want it yet, and when they do, `immich.cyphy.kz` in Almaty
serves them — the link is good. So the village box does **not** become a photo
target for the household; it stays a pure backup sink.
