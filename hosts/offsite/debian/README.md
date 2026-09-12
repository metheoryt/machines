# offsite — the village box (900 km from Almaty)

An appliance in a house nobody technical occupies. It is a SINK for latitude's
restic backups: it receives, it proves its own bytes are intact, and it can
never delete anything. Design:
`docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md`.

## 1. This box holds no repository password, and must never be given one

`restic-pack-verify.sh` (referenced from `hosts/latitude/debian/`, never
copied — two copies drift) proves the repository's bytes keylessly, because a
restic pack file's name IS the SHA-256 of its own stored bytes: hashing every
file under `data/`, `index/` and `snapshots/` and comparing against its own
name is a 100% read-data check that needs no key at all. `config` and
`keys/*` are not content-addressed and are judged only against a recorded
baseline (`--baseline /var/lib/offsite/baseline.sha`), never against their
names.

A key here would mean a stolen box hands over every photo. If a step ever
tempts you toward a repository password or a `restic` invocation that needs
one — `check --read-data`, `prune`, `forget`, `unlock` — that is the wrong
step. Nothing on this box runs any of them.

## 2. It never prunes

The repository grows forever. That is intended: this is a copy of last
resort, and the payload is small enough on an 8 TB HDD (~1 TB today, most of
it a frozen archive that dedupes to nothing) that never forgetting costs
nothing a trip out here could fix faster than more disk. `forget --prune`
cannot run from the client either way, because `--append-only` blocks it —
see point 3 — and this box has no password to run it locally.

## 3. It serves `--append-only`

`install-rest-server.sh` starts `rest-server` with `--private-repos
--append-only`. Almaty can add snapshots and can never remove them, lock
files aside. Granting this box an ssh key INTO Almaty would open, in the
other direction, exactly the hole `--append-only` closes — so it doesn't get
one. **Latitude PULLS `/var/lib/offsite/status.json`; this box pushes
nothing** — no outbound ssh, mail, webhook, or push of any kind. On the
Almaty end, the file's own mtime is this box's liveness signal and its
contents are the verdict: two conditions on one file, which is what keeps
"the sweep failed" distinguishable from "the link is down". A check run over
the link cannot tell those apart either, and a `--read-data` check from
Almaty would pull tens of gigabytes over a residential uplink on every run —
which is the whole reason `offsite-selfcheck.sh` and `offsite-verify.sh` (via
`restic-pack-verify.sh`) exist and run locally instead.

## 4. Recovery runbook

- **The box is found off.** Check the BIOS/UEFI restore-on-AC-power setting
  first — that is the single point of the whole unattended-appliance design.
  If it is not set to power on automatically, a routine outage in that house
  becomes an indefinite one; nobody there will press the button. Fix that
  setting before assuming anything else is wrong.
- **The disk is full (`vault_pct` near or past 95%).** Do not delete
  anything from this box's repository to free space — it never prunes on
  purpose (point 2) and a keyless sink cannot tell "safe to remove" from
  "safe to remove" without a password it does not have. The fix is a bigger
  or second disk, decided and installed on the next trip.
- **The sweep reports bad packs (`offsite-verify.timer`, `sweep_bad > 0` in
  `status.json`).** Do not delete or overwrite the bad file. The canonical
  copy is in Almaty; re-seeding this box's copy of it is a trip, not an `rm`.
  Record which pack(s) `restic-pack-verify.sh` named as `BAD` and treat the
  disk as suspect until it can be re-imaged from Almaty in person.
- **The sweep has not run in three weeks, or has never run
  (`offsite-verify.timer` failed or was never installed).** A stopped weekly
  job is exactly the silence this whole design exists to catch —
  `offsite-selfcheck.sh` already flags it in `detail`. Check
  `systemctl status offsite-verify.timer` and `journalctl -u
  offsite-verify.service` first; it is far more likely to be a stopped timer
  than a bad disk.

## 5. What to check on each visit

- Blow out the fan. This is an appliance in an uncontrolled room, not a
  server closet.
- `smartctl -t long /dev/<vault disk>` and read back the result once it
  finishes (a long self-test runs for hours; do not wait for it on-site) —
  the hourly selfcheck only reads the already-cached SMART attributes and
  overall health, it does not trigger a self-test itself.
- `journalctl -u rest-server --since '3 months ago' | grep -c 403` — a
  nonzero, growing count is someone on that LAN guessing at the htpasswd
  credential; `--private-repos` and `--append-only` limit the damage a
  successful guess could do, but a rising count is still worth knowing about.

## Files

- `offsite-selfcheck.sh` — hourly. Mount by UUID, free space, SMART, newest
  snapshot age, and the result of the last weekly sweep. Writes
  `/var/lib/offsite/status.json` (`{"ok":true|false,"detail":"...",...}` —
  the exact contract `backup-status.sh` on latitude reads).
- `systemd/offsite-selfcheck.{service,timer}` — runs the above hourly.
- `offsite-verify.sh` — weekly sweep script. Calls
  `hosts/latitude/debian/restic-pack-verify.sh` against
  `/mnt/vault/restic/latitude` and writes `/var/lib/offsite/verify.json`,
  which the selfcheck reads. A real script file, not an inline unit blob —
  `ExecStart=` is specifier-expanded by systemd itself, and an inline `%s` in
  a printf format there is silently replaced with the unit's own shell path
  rather than run as a shell format spec (see the script's own header).
- `systemd/offsite-verify.{service,timer}` — weekly, runs the above.
- `install-timers.sh` — copies (never symlinks) the four units into
  `/etc/systemd/system` and writes `/etc/default/offsite` with `VAULT_UUID`.
  `VAULT_UUID=<uuid> ./install-timers.sh -go` to install.
- `install-rest-server.sh` — the restic REST server itself (Task 8).
