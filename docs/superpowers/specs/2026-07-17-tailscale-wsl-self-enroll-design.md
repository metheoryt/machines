# tailscale-wsl.sh self-service enrollment (`--enroll`) — design

Date: 2026-07-17
Status: approved
Topic: let `provision/tailscale-wsl.sh` mint its own Headscale pre-auth key over
SSH to the control server, so enrolling a WSL distro needs no hand-pasted key.
Extends the shipped zero-touch design
(`docs/superpowers/specs/2026-07-15-orca-serve-wsl-design.md`, §5/§5b).

## Goal

Today the operator SSHes to the VPS, runs `headscale preauthkeys create` by
hand, copies the key, and feeds it to `tailscale-wsl.sh` via `--authkey-file` /
`$HEADSCALE_AUTHKEY`. This design collapses that into one flag: `--enroll` mints
a fresh key from the control server and runs the existing
enroll → persist → boot-autoconnect flow, fully hands-free.

## Control-server facts (probed 2026-07-17, read-only SSH to `debian@cyphy.kz`)

- Headscale is a **native binary** at `/usr/bin/headscale`, **v0.29.2**. Not
  Docker.
- **Socket-touching `headscale` commands need `sudo`** (corrected 2026-07-17
  after a live mint probe). The control socket
  (`/var/run/headscale/headscale.sock`) is `headscale:headscale` mode `0770`
  and the SSH user `debian` is **not** in the `headscale` group, so a bare
  `headscale preauthkeys create` fails `permission denied`. `debian` has
  **passwordless sudo**, and `sudo headscale …` runs non-interactively over
  SSH — so `--enroll` requires the SSH user to have passwordless sudo on the
  control server. (`--help` and other non-socket subcommands work without it.)
- User `fleet` = **ID 1** (confirmed via `sudo headscale users list`).
- `headscale preauthkeys create` flags (v0.29.2):
  `-u, --user uint` — **the numeric user ID, NOT the name** (so `--user 1`, not
  `--user fleet`). `--reusable`, `--ephemeral`, `-e/--expiration <human>`
  (default `1h`), `--tags`. Global `-o/--output` supports `json` / `json-line` /
  `yaml`; empty = human-readable.

## The `--enroll` flag

Opt-in. Never SSHes unless `--enroll` is passed (no surprise network calls; a
box without VPS SSH access is unaffected unless it asks to mint).

Flow when `--enroll` is set:

1. **Mint** over SSH:
   `ssh "$HEADSCALE_SSH" 'sudo headscale preauthkeys create --user <ID> --reusable --expiration <TTL> -o json'`
   - `$HEADSCALE_SSH` — SSH target, default `debian@cyphy.kz` (the
     `manage-peers.sh` target). Normal SSH auth (operator's key/agent); a
     `ConnectTimeout` guards a dead host; **not** `BatchMode` (a key passphrase
     prompt must still work). `die` with a clear message on SSH failure.
   - `$HEADSCALE_USER_ID` — default `1` (fleet). Overridable if the user's ID
     ever differs.
   - `$HEADSCALE_KEY_EXPIRY` — default `2160h` (90d), overridable. **Reusable +
     expiring**: reusable so the persisted key can drive the boot-autoconnect
     unit's re-enroll after a rebuild/logout; expiring so a leaked
     root-readable key eventually dies. Rotate quarterly (re-running `--enroll`
     mints a fresh key and overwrites the persisted one — `--enroll` doubles as
     key rotation).
2. **Extract** the key from the JSON with a pure helper `ts_extract_key_json`
   (`sed`, no `jq` dependency) so the WSL box needs nothing extra installed.
3. **Feed** the minted key into the existing `AUTHKEY` path: persist to
   `/etc/headscale/authkey` (`root:root 0600`), bake into
   `tailscale-autoconnect.service` — unchanged from §5b.

`--enroll` on an **already-up** node still mints + persists a fresh key (this is
how you rotate the persisted key) but does **not** redundantly re-run
`tailscale up`.

Key-source precedence becomes: **`--enroll` (mint) > `--authkey-file` >
`$HEADSCALE_AUTHKEY` > persisted `/etc/headscale/authkey`.**

## Hostname resolution

Precedence: **`--hostname <name>` (arg) > `$ORCA_TS_HOSTNAME` (env) >
interactive prompt (TTY only) > computed default `wsl-<sanitized $WSL_DISTRO_NAME>`.**

- `--hostname <name>` — new arg, for automation. Value is run through
  `ts_sanitize_hostname` like every other source.
- **Interactive prompt** — only when stdin is a **TTY** (`[ -t 0 ]`) and no
  hostname was supplied by arg or env: `Node hostname [<default>]:`. Empty input
  keeps the default. **Non-TTY (piped/automated) NEVER prompts** — hard
  requirement so scripted provisioning is not blocked waiting on stdin.

## Components / interfaces

- **New pure helper `ts_extract_key_json <json>`** → the `.key` value. Placed
  above the `TS_WSL_LIB_ONLY` guard so `tailscale-wsl.test.sh` can exercise it.
  Tolerates surrounding whitespace/newlines; assumes exactly one `"key"` field
  (true of headscale's preauthkey object).
- **`ts_mint_key`** (main-only; does IO) — builds and runs the SSH command,
  passes stdout through `ts_extract_key_json`, `die`s on empty result.
- **Arg parser** gains `--enroll`, `--hostname <name>` (and `--hostname=…`),
  keeping the existing `--authkey-file` / `-h|--help`.
- Env inputs: `HEADSCALE_SSH`, `HEADSCALE_USER_ID`, `HEADSCALE_KEY_EXPIRY`
  (all with defaults), plus the existing `HEADSCALE_AUTHKEY`, `ORCA_TS_HOSTNAME`.

## Testing

- **Unit (anywhere, `tailscale-wsl.test.sh`):** extend with `ts_extract_key_json`
  cases — a realistic headscale JSON blob → the key; pretty-printed multi-line
  JSON → the key; missing key → empty. Keep the existing sanitizer + `ts_pick_key`
  cases.
- **shellcheck** clean; `bash -n` clean.
- **[VPS] mint probe:** `ssh debian@cyphy.kz 'sudo headscale preauthkeys create --user 1 --reusable --expiration 2160h -o json'` returns parseable JSON; the key enrolls; expire it afterward with `sudo headscale preauthkeys expire --id <n> --force` (`expire` takes `-i/--id` only — no `--user`). Ran 2026-07-17: minted id=4, `ts_extract_key_json` pulled the key correctly, expired it.
- **[WSL] end-to-end:** `bash tailscale-wsl.sh --enroll` on a fresh distro →
  prompts hostname (TTY), mints, enrolls, persists, installs the unit; node
  appears in `headscale nodes list`. Re-run `--enroll` → rotates the persisted
  key. `--hostname foo --enroll` under a non-TTY (piped) → no prompt.

## Security / tradeoffs

- A **reusable** key sits root-readable at `/etc/headscale/authkey` — inherited
  from §5b. Mitigation unchanged: expiring key (90d default) + rotation via
  re-`--enroll`.
- `--enroll` is **opt-in**; the default path makes no network calls beyond
  what shipped. SSH uses the operator's own credentials — no new secret is
  distributed to the WSL box.
- `--enroll` needs the SSH user to have **passwordless sudo** on the control
  server (the mint runs `sudo headscale`, since the headscale socket is
  group-restricted). This is an operator/control-server prerequisite, not a
  secret the WSL box holds.

## Out of scope

- Auto-minting as a silent fallback (rejected: surprising SSH, fails noisily on
  no-access boxes).
- Headscale HTTP-API minting (rejected: an API key is the same bootstrap-secret
  problem plus version coupling).
- Re-minting from inside the boot unit (the unit has no SSH creds and must run
  headless as root; it re-enrolls from the persisted key only).
- ACL/tag assignment on the minted key (`--tags`) — tailnet is default-open
  today; ACLs are a separate roadmap item.
