# tailscale-wsl.sh self-service enrollment (`--enroll`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--enroll` flag to `provision/tailscale-wsl.sh` that mints a fresh Headscale pre-auth key over SSH to the control server, plus a `--hostname` arg and a TTY-gated interactive hostname prompt — so enrolling a WSL distro needs no hand-pasted key.

**Architecture:** Extend the existing standalone bash script. One new pure, unit-tested helper (`ts_extract_key_json`) parses headscale's JSON; one impure helper (`ts_mint_key`) runs the SSH mint. `--enroll` prepends a "mint" source above the existing key precedence and feeds the minted key into the already-shipped persist + boot-autoconnect path unchanged. Hostname gains an arg + interactive source above the computed default.

**Tech Stack:** bash, ssh, headscale v0.29.2 (native binary on `debian@cyphy.kz`, `--user` takes the numeric ID), sed (no `jq` dependency).

## Global Constraints

- Target: Debian/Ubuntu, x86_64 only. `set -u`. `info/ok/warn/die/have` helpers already defined — reuse verbatim.
- **Idempotent**; safe to re-run. `--enroll` on an already-up node mints + persists a fresh key (rotation) but does NOT re-run `tailscale up`.
- **Non-interactive safety (hard requirement):** when stdin is not a TTY (`[ -t 0 ]` false), the script MUST NOT prompt — scripted/piped provisioning must never block on stdin.
- Control server: native `headscale` v0.29.2 at `/usr/bin/headscale` on `debian@cyphy.kz`, **no sudo needed**. User `fleet` = **ID 1**. `preauthkeys create` uses `-u/--user <uint ID>`, `--reusable`, `-e/--expiration <human>`, `-o json`.
- Defaults (all overridable via env): `HEADSCALE_SSH=debian@cyphy.kz`, `HEADSCALE_USER_ID=1`, `HEADSCALE_KEY_EXPIRY=2160h` (90d).
- Key-source precedence: **`--enroll` (mint) > `--authkey-file` > `$HEADSCALE_AUTHKEY` > persisted `/etc/headscale/authkey`.**
- Hostname precedence: **`--hostname` > `$ORCA_TS_HOSTNAME` > interactive prompt (TTY only) > `wsl-<sanitized $WSL_DISTRO_NAME>`.** Every source is run through `ts_sanitize_hostname`.
- New pure helpers go ABOVE the `TS_WSL_LIB_ONLY` early-return so `tailscale-wsl.test.sh` can source them.
- Verify with `nix run nixpkgs#shellcheck -- <files>` (no system shellcheck on this NixOS host; the pre-commit hook also runs it). `[VPS]`/`[WSL]` steps run against the real control server / a real distro.
- Repo workflow: straight to `main`, commit per task. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- Modify: `provision/tailscale-wsl.sh` — add helpers, args, mint wiring, hostname resolution.
- Modify: `provision/tailscale-wsl.test.sh` — add `ts_extract_key_json` unit tests.
- Modify: `provision/README.md` — document `--enroll` / `--hostname` in the Orca section.

Spec: `docs/superpowers/specs/2026-07-17-tailscale-wsl-self-enroll-design.md`.

---

### Task 1: `ts_extract_key_json` — parse the key from headscale JSON (TDD)

**Files:**
- Modify: `provision/tailscale-wsl.sh` (add helper above the `TS_WSL_LIB_ONLY` guard)
- Modify: `provision/tailscale-wsl.test.sh` (add tests)

**Interfaces:**
- Produces: `ts_extract_key_json <json-string>` → echoes the value of the single `"key"` field; echoes nothing (empty) when absent. Pure; tolerates multiline/pretty JSON. Relied on by `ts_mint_key` (Task 3).

- [ ] **Step 1: Write the failing tests**

Append to `provision/tailscale-wsl.test.sh`, immediately before the final `echo "PASS: …"` line:

```bash
# ── ts_extract_key_json ───────────────────────────────────────────────────────
json_line='{"id":"5","key":"abc123def456","user":{"id":"1","name":"fleet"},"reusable":true}'
eq "$(ts_extract_key_json "$json_line")" 'abc123def456' 'extract key (single line, nested user obj)'

json_pretty='{
  "id": "5",
  "key": "K9xYz-Token_007",
  "reusable": true
}'
eq "$(ts_extract_key_json "$json_pretty")" 'K9xYz-Token_007' 'extract key (pretty/multiline)'

eq "$(ts_extract_key_json '{"id":"5","reusable":true}')" '' 'extract key (missing → empty)'
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/me/machines && bash provision/tailscale-wsl.test.sh`
Expected: FAIL — `ts_extract_key_json: command not found` (or a `FAIL:` line), non-zero exit.

- [ ] **Step 3: Add the helper**

In `provision/tailscale-wsl.sh`, insert this function directly AFTER the `ts_pick_key` function and BEFORE the `# Allow sourcing just the functions …` comment + guard:

```bash
# Extract the single "key" field from headscale's JSON preauthkey output — no
# jq dependency (the WSL box needs nothing extra installed). Tolerates
# pretty-printed / multiline JSON. Echoes the key, or nothing if absent.
ts_extract_key_json() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -n -E 's/.*"key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/me/machines && bash provision/tailscale-wsl.test.sh`
Expected: PASS — ends with `PASS: tailscale-wsl.test.sh`, exit 0.

- [ ] **Step 5: Lint**

Run: `cd /home/me/machines && nix run nixpkgs#shellcheck -- provision/tailscale-wsl.sh provision/tailscale-wsl.test.sh; echo "exit=$?"`
Expected: `exit=0`, no findings.

- [ ] **Step 6: Commit**

```bash
cd /home/me/machines
git add provision/tailscale-wsl.sh provision/tailscale-wsl.test.sh
git commit -m "feat(provision): jq-free ts_extract_key_json helper for tailscale-wsl

Parses the single \"key\" field out of headscale's JSON preauthkey output so
--enroll (next) can mint over SSH without a jq dependency on the WSL box.
Unit-tested for single-line, pretty-printed, and missing-key inputs.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `--hostname` arg + interactive hostname prompt

**Files:**
- Modify: `provision/tailscale-wsl.sh` (arg parser, hostname resolution, usage text)

**Interfaces:**
- Consumes: `ts_sanitize_hostname` (existing).
- Produces: `HOSTNAME_TS` resolved by the new precedence. Introduces the `HOSTNAME_ARG` variable set by the arg parser (also read by nothing else). No new functions.

- [ ] **Step 1: Add `--hostname` to the arg parser and initialise `HOSTNAME_ARG`**

In `provision/tailscale-wsl.sh`, replace the entire `# ── Args ──` block:

```bash
# ── Args ──────────────────────────────────────────────────────────────────────
AUTHKEY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --authkey-file) AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done
```

with:

```bash
# ── Args ──────────────────────────────────────────────────────────────────────
AUTHKEY_FILE=""
HOSTNAME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --authkey-file) AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    --hostname) HOSTNAME_ARG="${2:-}"; [ -n "$HOSTNAME_ARG" ] || die "--hostname needs a name."; shift 2 ;;
    --hostname=*) HOSTNAME_ARG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done
```

- [ ] **Step 2: Replace the hostname-resolution block**

Replace the entire `# ── Node hostname ──` block:

```bash
# ── Node hostname ─────────────────────────────────────────────────────────────
DEFAULT_NAME="wsl-$(ts_sanitize_hostname "${WSL_DISTRO_NAME:-$(uname -n)}")"
HOSTNAME_TS="${ORCA_TS_HOSTNAME:-$DEFAULT_NAME}"
info "Node hostname: $HOSTNAME_TS"
```

with:

```bash
# ── Node hostname ─────────────────────────────────────────────────────────────
# Precedence: --hostname > $ORCA_TS_HOSTNAME > interactive prompt (TTY only) >
# computed default. Every source is sanitized to a DNS-safe label. A prompt
# fires ONLY on a TTY, so piped/automated runs never block on stdin.
DEFAULT_NAME="wsl-$(ts_sanitize_hostname "${WSL_DISTRO_NAME:-$(uname -n)}")"
if [ -n "$HOSTNAME_ARG" ]; then
  HOSTNAME_TS="$(ts_sanitize_hostname "$HOSTNAME_ARG")"
elif [ -n "${ORCA_TS_HOSTNAME:-}" ]; then
  HOSTNAME_TS="$(ts_sanitize_hostname "$ORCA_TS_HOSTNAME")"
elif [ -t 0 ]; then
  printf '\033[0;36m▸ Node hostname [%s]: \033[0m' "$DEFAULT_NAME" >&2
  read -r reply || reply=""
  HOSTNAME_TS="$([ -n "$reply" ] && ts_sanitize_hostname "$reply" || printf '%s' "$DEFAULT_NAME")"
else
  HOSTNAME_TS="$DEFAULT_NAME"
fi
[ -n "$HOSTNAME_TS" ] || HOSTNAME_TS="$DEFAULT_NAME"   # sanitizing junk (e.g. "!!!") → empty
info "Node hostname: $HOSTNAME_TS"
```

- [ ] **Step 3: Update `usage()` to document `--hostname`**

In `usage()`, replace this line:

```bash
  --authkey-file <path>   read the reusable pre-auth key from <path>
  -h, --help              show this help
```

with:

```bash
  --authkey-file <path>   read the reusable pre-auth key from <path>
  --hostname <name>       node name (else $ORCA_TS_HOSTNAME, else prompt on a
                          TTY, else wsl-<distro>)
  -h, --help              show this help
```

- [ ] **Step 4: Lint + syntax + regression**

Run:
```bash
cd /home/me/machines
nix run nixpkgs#shellcheck -- provision/tailscale-wsl.sh && echo LINT_OK
bash -n provision/tailscale-wsl.sh && echo SYNTAX_OK
bash provision/tailscale-wsl.test.sh
```
Expected: `LINT_OK`, `SYNTAX_OK`, then `PASS: tailscale-wsl.test.sh` (helpers unchanged — still pass).

- [ ] **Step 5: Behaviour check — arg wins, no prompt when non-TTY**

Run (pipes empty stdin, so `[ -t 0 ]` is false; preconditions will `die` early on this NixOS host, which is fine — we only assert it does NOT hang waiting for input, and that `--hostname` parses):
```bash
cd /home/me/machines
echo | timeout 10 bash provision/tailscale-wsl.sh --hostname 'My Box!' ; echo "exit=$?"
```
Expected: returns within the timeout (exit is a `die` from `apt-get`/`systemd` preconditions, NOT 124/timeout). Confirms no stdin block. (The full arg→sanitize path is exercised on a real distro in the [WSL] step of Task 3.)

- [ ] **Step 6: Commit**

```bash
cd /home/me/machines
git add provision/tailscale-wsl.sh
git commit -m "feat(provision): --hostname arg + TTY-gated hostname prompt for tailscale-wsl

Hostname precedence: --hostname > \$ORCA_TS_HOSTNAME > interactive prompt (only
when stdin is a TTY) > wsl-<distro>. Every source is sanitized. Piped/automated
runs never prompt, so scripted provisioning does not block on stdin.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `--enroll` — SSH-mint a key and wire it into the key precedence

**Files:**
- Modify: `provision/tailscale-wsl.sh` (add `ts_mint_key`, `--enroll` arg, mint wiring, usage text)

**Interfaces:**
- Consumes: `ts_extract_key_json` (Task 1); `HEADSCALE_SSH`/`HEADSCALE_USER_ID`/`HEADSCALE_KEY_EXPIRY` env (with defaults); the existing `AUTHKEY`/`KEY_SRC` persist + autoconnect path.
- Produces: `ts_mint_key` → echoes a minted key on success, returns non-zero on ssh/headscale failure. `ENROLL` variable (0/1). When `ENROLL=1`, `KEY_SRC="enroll"` and `AUTHKEY` is the minted key.

- [ ] **Step 1: Add the `ts_mint_key` helper**

In `provision/tailscale-wsl.sh`, insert directly AFTER the `ts_extract_key_json` function (still ABOVE the `TS_WSL_LIB_ONLY` guard):

```bash
# Mint a fresh reusable + expiring pre-auth key from the control server over
# SSH (headscale is native there and the ssh user runs it without sudo). Echoes
# the key on success; returns non-zero on ssh/headscale failure. Overridable via
# $HEADSCALE_SSH, $HEADSCALE_USER_ID, $HEADSCALE_KEY_EXPIRY.
ts_mint_key() {
  local target="${HEADSCALE_SSH:-debian@cyphy.kz}"
  local uid="${HEADSCALE_USER_ID:-1}"
  local ttl="${HEADSCALE_KEY_EXPIRY:-2160h}"
  local json
  json="$(ssh -o ConnectTimeout=15 "$target" \
    "headscale preauthkeys create --user $uid --reusable --expiration $ttl -o json")" || return 1
  ts_extract_key_json "$json"
}
```

- [ ] **Step 2: Add `--enroll` to the arg parser**

In the `# ── Args ──` block, add an `--enroll` case and initialise `ENROLL=0`. Replace:

```bash
AUTHKEY_FILE=""
HOSTNAME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --authkey-file) AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    --hostname) HOSTNAME_ARG="${2:-}"; [ -n "$HOSTNAME_ARG" ] || die "--hostname needs a name."; shift 2 ;;
    --hostname=*) HOSTNAME_ARG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done
```

with:

```bash
AUTHKEY_FILE=""
HOSTNAME_ARG=""
ENROLL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --enroll) ENROLL=1; shift ;;
    --authkey-file) AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    --hostname) HOSTNAME_ARG="${2:-}"; [ -n "$HOSTNAME_ARG" ] || die "--hostname needs a name."; shift 2 ;;
    --hostname=*) HOSTNAME_ARG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done
```

- [ ] **Step 3: Wire the mint into key resolution**

Replace the tail of the `# ── Resolve the pre-auth key ──` block. Replace:

```bash
picked="$(ts_pick_key "$FILE_KEY" "${HEADSCALE_AUTHKEY:-}" "$STORE_KEY")"
tab=$'\t'
KEY_SRC="${picked%%"$tab"*}"
AUTHKEY="${picked#*"$tab"}"
[ -n "$KEY_SRC" ] && info "Pre-auth key source: $KEY_SRC"
```

with:

```bash
if [ "$ENROLL" = 1 ]; then
  info "Minting a reusable key via ${HEADSCALE_SSH:-debian@cyphy.kz} (user ${HEADSCALE_USER_ID:-1}, expiry ${HEADSCALE_KEY_EXPIRY:-2160h})…"
  AUTHKEY="$(ts_mint_key)" || die "mint failed — check \$HEADSCALE_SSH and your SSH access to the control server."
  [ -n "$AUTHKEY" ] || die "mint returned no key — check 'headscale preauthkeys create' on the control server."
  KEY_SRC="enroll"
else
  picked="$(ts_pick_key "$FILE_KEY" "${HEADSCALE_AUTHKEY:-}" "$STORE_KEY")"
  tab=$'\t'
  KEY_SRC="${picked%%"$tab"*}"
  AUTHKEY="${picked#*"$tab"}"
fi
[ -n "$KEY_SRC" ] && info "Pre-auth key source: $KEY_SRC"
```

(The existing persist block that follows — `if [ -n "$AUTHKEY" ] && [ "$KEY_SRC" != persisted ]` — already persists an `enroll`-sourced key, overwriting the store: that IS the rotation behaviour.)

- [ ] **Step 4: Update `usage()` to document `--enroll`**

In `usage()`, replace this line:

```bash
  --authkey-file <path>   read the reusable pre-auth key from <path>
```

with:

```bash
  --enroll                mint a fresh reusable key over SSH to the control
                          server, then enroll (needs SSH access to the VPS)
  --authkey-file <path>   read the reusable pre-auth key from <path>
```

And replace the `Env:` line:

```bash
Env: HEADSCALE_AUTHKEY (key), ORCA_TS_HOSTNAME (node name; default wsl-<distro>).
```

with:

```bash
Env: HEADSCALE_AUTHKEY (key), ORCA_TS_HOSTNAME (node name; default wsl-<distro>),
     HEADSCALE_SSH (default debian@cyphy.kz), HEADSCALE_USER_ID (default 1),
     HEADSCALE_KEY_EXPIRY (default 2160h) — the last three drive --enroll.
EOF
```

Note: the `EOF` above is the existing heredoc terminator — do not add a second one; the replacement simply extends the text on the line before it. Concretely, the final lines of `usage()` become:

```bash
Env: HEADSCALE_AUTHKEY (key), ORCA_TS_HOSTNAME (node name; default wsl-<distro>),
     HEADSCALE_SSH (default debian@cyphy.kz), HEADSCALE_USER_ID (default 1),
     HEADSCALE_KEY_EXPIRY (default 2160h) — the last three drive --enroll.
EOF
}
```

- [ ] **Step 5: Lint + syntax + regression**

Run:
```bash
cd /home/me/machines
nix run nixpkgs#shellcheck -- provision/tailscale-wsl.sh && echo LINT_OK
bash -n provision/tailscale-wsl.sh && echo SYNTAX_OK
bash provision/tailscale-wsl.test.sh
```
Expected: `LINT_OK`, `SYNTAX_OK`, `PASS: tailscale-wsl.test.sh`.

- [ ] **Step 6: `--help` renders the new flags**

Run: `cd /home/me/machines && bash provision/tailscale-wsl.sh --help`
Expected: help text lists `--enroll`, `--hostname`, `--authkey-file`, and the `HEADSCALE_SSH`/`HEADSCALE_USER_ID`/`HEADSCALE_KEY_EXPIRY` env line; exit 0.

- [ ] **Step 7: [VPS] mint probe (real control server)**

Run:
```bash
ssh debian@cyphy.kz 'headscale preauthkeys create --user 1 --reusable --expiration 2160h -o json'
```
Expected: a JSON object containing `"key":"…"`. Sanity-check the extractor against it:
```bash
cd /home/me/machines
out="$(ssh debian@cyphy.kz 'headscale preauthkeys create --user 1 --reusable --expiration 2160h -o json')"
TS_WSL_LIB_ONLY=1 bash -c 'source provision/tailscale-wsl.sh; ts_extract_key_json "$1"' _ "$out"
```
Expected: prints the same key string the JSON carried. **Then expire the two probe keys** so they don't linger:
```bash
ssh debian@cyphy.kz 'headscale preauthkeys list --user 1'   # note the IDs just created
ssh debian@cyphy.kz 'headscale preauthkeys expire --id <n>' # for each probe key
```

- [ ] **Step 8: [WSL] end-to-end on a real distro**

On an Ubuntu WSL distro with SSH access to the VPS:
```bash
cd ~/machines && git pull
bash provision/tailscale-wsl.sh --enroll            # TTY: prompts hostname, mints, enrolls
```
Expected: prompts `Node hostname [wsl-<distro>]:`, mints a key, persists `/etc/headscale/authkey`, enrolls, installs+enables `tailscale-autoconnect.service`, ends with `node '…' up at 100.64.x.y`. Verify on the VPS: `headscale nodes list` shows the node. Then:
- Rotation: `bash provision/tailscale-wsl.sh --enroll` again → mints a fresh key, `/etc/headscale/authkey` changes, node stays up (no redundant `tailscale up`).
- Non-TTY + arg: `echo | bash provision/tailscale-wsl.sh --enroll --hostname devbox` → NO prompt, node name `devbox`.

- [ ] **Step 9: Commit**

```bash
cd /home/me/machines
git add provision/tailscale-wsl.sh
git commit -m "feat(provision): --enroll self-service key minting for tailscale-wsl

--enroll SSHes to the Headscale control server (default debian@cyphy.kz), mints
a reusable+expiring pre-auth key (headscale preauthkeys create --user 1 -o json,
90d default), extracts it jq-free, and runs the existing enroll/persist/boot-
autoconnect flow. Precedence: --enroll > --authkey-file > \$HEADSCALE_AUTHKEY >
persisted. Re-running --enroll rotates the persisted key. SSH target/user/expiry
are env-overridable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Document `--enroll` / `--hostname` in `provision/README.md`

**Files:**
- Modify: `provision/README.md` (Orca headless server section)

**Interfaces:**
- Consumes: the flags from Tasks 2–3. Produces: operator docs.

- [ ] **Step 1: Add the one-shot self-service option to step 1**

In `provision/README.md`, replace this block:

```markdown
    # 1. Join the fleet tailnet as this distro's own node (needs systemd + sudo).
    #    Supply the reusable pre-auth key by ANY of (precedence high→low):
    export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
    bash ~/machines/provision/tailscale-wsl.sh          # → wsl-<distro> @ 100.64.x.y
    #    …or from a local (gitignored) file, or reuse the persisted key:
    bash ~/machines/provision/tailscale-wsl.sh --authkey-file provision/secrets/authkey
    bash ~/machines/provision/tailscale-wsl.sh          # reuse /etc/headscale/authkey
```

with:

```markdown
    # 1. Join the fleet tailnet as this distro's own node (needs systemd + sudo).
    #    Easiest — self-service: mint a key over SSH to the control server and
    #    enroll in one shot (needs your SSH access to the VPS):
    bash ~/machines/provision/tailscale-wsl.sh --enroll   # prompts hostname on a TTY
    #    …or supply the key yourself (precedence high→low):
    export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
    bash ~/machines/provision/tailscale-wsl.sh            # → wsl-<distro> @ 100.64.x.y
    bash ~/machines/provision/tailscale-wsl.sh --authkey-file provision/secrets/authkey
    bash ~/machines/provision/tailscale-wsl.sh            # reuse /etc/headscale/authkey
    #    Automation can name the node non-interactively:
    bash ~/machines/provision/tailscale-wsl.sh --enroll --hostname devbox
```

- [ ] **Step 2: Add a self-service note**

In the `Notes:` list of the same section, insert this bullet immediately BEFORE the `- **Zero-touch re-enroll.**` bullet:

```markdown
- **Self-service enrollment.** `--enroll` SSHes to the control server
  (`$HEADSCALE_SSH`, default `debian@cyphy.kz`) and mints a reusable, expiring
  pre-auth key (`$HEADSCALE_KEY_EXPIRY`, default `2160h`/90d; `$HEADSCALE_USER_ID`,
  default `1`) with `headscale preauthkeys create` — no hand-pasted key. Opt-in:
  without `--enroll` nothing SSHes. Re-running `--enroll` rotates the persisted
  key. Hostname precedence: `--hostname` → `$ORCA_TS_HOSTNAME` → interactive
  prompt (TTY only) → `wsl-<distro>`.
```

- [ ] **Step 3: Verify the section renders**

Run:
```bash
cd /home/me/machines
grep -n -- '--enroll' provision/README.md
echo "backticks: $(grep -c '```' provision/README.md) (want even)"
```
Expected: `--enroll` matches present; backtick count even.

- [ ] **Step 4: Commit**

```bash
cd /home/me/machines
git add provision/README.md
git commit -m "docs(provision): document tailscale-wsl --enroll and --hostname

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `--enroll` mint over SSH, reusable+expiring, feeds existing persist/autoconnect → Task 3. ✓
- Probed control-server facts (native, `--user 1`, `-o json`, no sudo) → encoded in `ts_mint_key` + [VPS] step, Task 3. ✓
- `ts_extract_key_json` pure helper, jq-free, unit-tested (single-line/pretty/missing) → Task 1. ✓
- `--hostname` arg + TTY-gated interactive prompt + non-TTY safety → Task 2. ✓
- Hostname precedence (arg > env > prompt > default), all sanitized → Task 2. ✓
- Key precedence (enroll > file > env > persisted) → Task 3 wiring. ✓
- `--enroll` on already-up node = rotation, no redundant `tailscale up` → Task 3 (mint runs before the ALREADY_UP-gated enroll; persist overwrites store). ✓
- Env overrides `HEADSCALE_SSH`/`HEADSCALE_USER_ID`/`HEADSCALE_KEY_EXPIRY` with defaults → Task 3 `ts_mint_key` + usage. ✓
- Docs → Task 4. ✓
- Out-of-scope items (auto-fallback, HTTP API, boot-unit re-mint, tags) → correctly untouched. ✓

**Placeholder scan:** `<path>`, `<name>`, `<n>`, `<distro>`, `<reusable pre-auth key …>` are user-supplied runtime values in commands/help text, not plan placeholders. No TBD/TODO/"handle edge cases". ✓

**Type/name consistency:** `ts_extract_key_json`, `ts_mint_key`, `ts_pick_key`, `ts_sanitize_hostname`, `HOSTNAME_ARG`, `ENROLL`, `AUTHKEY`, `KEY_SRC`, `AUTHKEY_STORE`, env names `HEADSCALE_SSH`/`HEADSCALE_USER_ID`/`HEADSCALE_KEY_EXPIRY`, expiry `2160h`, user id `1`, login server `https://cc.cyphy.kz` — used identically across tasks and match the spec. ✓
