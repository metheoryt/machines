# fleet-gather.sh Windows Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `agents/plugin/skills/kb-refresh/fleet-gather.sh` harvest the Windows fleet members (`desktop`=g614jv, `server`=methe-server) instead of silently returning 0 digests from them.

**Architecture:** Move all per-host decision logic into pure bash functions driven by `fleet.json` (tested offline against a fixture, à la `provision/ssh-wsl.sh`); keep `main` a thin IO wrapper. Every remote command is bash-wrapped (`ssh $h bash …`, never bare — bare lands in PowerShell), all dynamic values cross as positional args (no string interpolation into remote command bodies), and transport is unified on `cat`/`tar` (rsync dropped — it fails on the Windows boxes and its unix-remote path is never exercised today).

**Tech Stack:** Bash 4+, `jq`, Python 3 (`distill.py`, unchanged), ssh into WSL bash.

## Global Constraints

- **Every remote command MUST be bash-wrapped:** `ssh $h bash -lc '…'` or `ssh $h bash -s -- <args>`. A bare `ssh $h <cmd>` lands in PowerShell on Windows boxes and breaks. This includes the reachability/`mkdir`, the self-exclusion `hostname` probe, all file transfers, and the distill call.
- **Dynamic values cross as positional arguments, never interpolated** into a quoted remote command body. The remote run-script is static text read from stdin; roots/host/matches arrive as `$1`, `$2`, `"$@"`.
- **Transport is `cat` (single JSON files) / `tar` (digest tree). No `rsync`.** Keep `--exclude=manifest.tsv` on the digest tar — the local manifest accumulates and a plain copy would clobber it.
- **`--host` is always the fleet `detect.hostname`** (local and remote), resolved from `fleet.json` — never the ssh alias, never raw `$(hostname)`. This makes each digest's `# host:` line match the `agents/hosts/*.md` filenames.
- **Invariants preserved:** local-first distill; read-once seed→distill→merge-back→pull; self-exclusion (skip a box whose resolved identity equals this controller's); raw transcripts never leave their box (only digests return).
- **Hub is excluded** from the harvest — it is the VPS, identified in `fleet.json` by having `ssh.host` set (the only member that does).
- Tests run **offline** (no ssh/network): they `KB_GATHER_NO_MAIN=1 source` the script and exercise only pure functions. jq-dependent cases guard with `command -v jq` + a `SKIP:` line.

**Reference — current file:** `agents/plugin/skills/kb-refresh/fleet-gather.sh` is 93 lines: a hardcoded `FLEET_WORKSTATIONS=(latitude desktop server)` array, a `detect_hosts` that intersects it with `~/.ssh/config`, and an rsync/deployed-symlink `main`. `distill.py` (unchanged) accepts `--projects-root` (NOT expanduser'd when passed explicitly — a literal `~` will NOT expand), repeatable `--match`, `--out`, `--state`, `--host`, and `--merge-from <file>`.

**Reference — fixture fleet.json** (used by every test task; each test writes it to a tmp file):

```json
{ "machines": {
  "latitude": { "platform": "nixos", "detect": { "hostname": "latitude5520" } },
  "desktop":  { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "g614jv" } },
  "server":   { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "methe-server" } },
  "hub":      { "platform": "debian", "ssh": { "user": "debian", "host": "cyphy.kz" }, "detect": { "hostname": "27608" } }
} }
```

---

### Task 1: Pure helper `fleet_hosts` — fleet.json → per-host tuples

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh` (add `FLEET_JSON` var + `fleet_hosts`)
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`

**Interfaces:**
- Produces: `fleet_hosts [json_path]` — prints one TSV line per non-hub workstation: `alias<TAB>platform<TAB>detect.hostname<TAB>ssh.user` (ssh.user empty when absent). Defaults `json_path` to `$FLEET_JSON`. Hub excluded via `select(.value.ssh.host == null)`. Missing file → no output, rc 0.
- Produces: `FLEET_JSON` — global, defaults to `$SKILL_DIR/../../../../fleet.json`, overridable via env (tests set it / pass an explicit arg).

- [ ] **Step 1: Write the failing test.** Append to `tests/test_fleet_gather.sh` (after the existing `detect_hosts` block, before nothing — it's currently the last content):

```bash
# ── fixture fleet.json (shared by the pure-function tests) ────────────────────
fixture_json="$tmp/fleet.json"
cat > "$fixture_json" <<'JSON'
{ "machines": {
  "latitude": { "platform": "nixos", "detect": { "hostname": "latitude5520" } },
  "desktop":  { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "g614jv" } },
  "server":   { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "methe-server" } },
  "hub":      { "platform": "debian", "ssh": { "user": "debian", "host": "cyphy.kz" }, "detect": { "hostname": "27608" } }
} }
JSON

if command -v jq >/dev/null 2>&1; then
  # ── fleet_hosts: hub excluded, correct tuples ───────────────────────────────
  fh="$(fleet_hosts "$fixture_json")"
  [ "$(printf '%s\n' "$fh" | wc -l)" = 3 ] || { echo "FAIL: fleet_hosts expected 3 rows, got: $fh"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^latitude\tnixos\tlatitude5520\t$' || { echo "FAIL: fleet_hosts latitude tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^desktop\twindows\tg614jv\tmethe$'  || { echo "FAIL: fleet_hosts desktop tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^server\twindows\tmethe-server\tmethe$' || { echo "FAIL: fleet_hosts server tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -q 'hub' && { echo "FAIL: fleet_hosts must exclude hub"; exit 1; }
else
  echo "SKIP: fleet_hosts test (jq not installed)"
fi
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — `fleet_hosts: command not found` (or the FAIL line for fleet_hosts).

- [ ] **Step 3: Write minimal implementation.** In `fleet-gather.sh`, replace the `FLEET_WORKSTATIONS=(…)` line (line 6) with the `FLEET_JSON` var and add `fleet_hosts` just below `SKILL_DIR`:

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fleet.json (repo root) is the machine manifest; four levels up from the skill dir.
FLEET_JSON="${FLEET_JSON:-$SKILL_DIR/../../../../fleet.json}"

fleet_hosts() {
  # Emit one TSV row per non-hub workstation: alias<TAB>platform<TAB>hostname<TAB>user.
  # The hub is the only member with ssh.host set (it's the VPS) — exclude it.
  local json="${1:-$FLEET_JSON}"
  [ -f "$json" ] || return 0
  jq -r '
    .machines | to_entries[]
    | select(.value.ssh.host == null)
    | [ .key, (.value.platform // "unknown"),
        (.value.detect.hostname // ""), (.value.ssh.user // "") ]
    | @tsv
  ' "$json"
}
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: the fleet_hosts assertions pass. (The existing `detect_hosts` test still uses the old hardcoded contract and may now fail because `FLEET_WORKSTATIONS` is gone — that is fixed in Task 5. If `detect_hosts` errors here, confirm it is ONLY that pre-existing block failing, then proceed.)

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb): fleet_hosts — read fleet.json instead of hardcoded workstation list"
```

---

### Task 2: Pure helper `roots_for_platform` — platform → projects roots

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh`
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`

**Interfaces:**
- Produces: `roots_for_platform <platform> <ssh_user>` — prints the projects roots for that box, one per line, in distill order. `windows` → `/mnt/c/Users/<ssh_user>/.claude/projects` then `~/.claude/projects` (WSL). Anything else → `~/.claude/projects`. Emits a literal leading `~` for the WSL root; the remote run-script (Task 4) expands it against `$HOME`.

- [ ] **Step 1: Write the failing test.** Append to `tests/test_fleet_gather.sh` (inside no jq guard needed — pure string logic):

```bash
# ── roots_for_platform ────────────────────────────────────────────────────────
rw="$(roots_for_platform windows methe)"
eq "$(printf '%s\n' "$rw" | sed -n 1p)" '/mnt/c/Users/methe/.claude/projects' 'roots windows: profile root first'
eq "$(printf '%s\n' "$rw" | sed -n 2p)" '~/.claude/projects'                  'roots windows: WSL root second'
[ "$(printf '%s\n' "$rw" | wc -l)" = 2 ] || { echo "FAIL: roots windows expected 2 roots"; exit 1; }
ru="$(roots_for_platform nixos '')"
eq "$ru" '~/.claude/projects' 'roots unix: single WSL/home root'
```

Note: this reuses the `eq`/`fail` helpers — add them near the top of the file if not already present (the existing file uses ad-hoc `echo FAIL; exit 1`; define `fail`/`eq` once after the `trap` line):

```bash
fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — `roots_for_platform: command not found`.

- [ ] **Step 3: Write minimal implementation.** Add to `fleet-gather.sh` below `fleet_hosts`:

```bash
roots_for_platform() {
  # Projects roots to distill on the remote, in order. Windows boxes keep live
  # transcripts in the Windows profile AND (partially) in WSL — distill both.
  local platform="$1" user="$2"
  case "$platform" in
    windows)
      printf '/mnt/c/Users/%s/.claude/projects\n' "$user"
      printf '~/.claude/projects\n'
      ;;
    *)
      printf '~/.claude/projects\n'
      ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: the `roots_for_platform` assertions pass.

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb): roots_for_platform — Windows profile + WSL roots"
```

---

### Task 3: Pure helper `local_host_id` — live hostname → fleet identity

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh`
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`

**Interfaces:**
- Produces: `local_host_id <json_path> <live_hostname>` — if `<live_hostname>` matches any member's `detect.hostname` in fleet.json, prints that `detect.hostname`; otherwise prints `<live_hostname>` unchanged (fallback). Used both for the local `--host` and for resolving a remote's `hostname` during self-exclusion.

- [ ] **Step 1: Write the failing test.** Append (inside the existing jq guard block, alongside `fleet_hosts` — it needs jq):

```bash
  # ── local_host_id: known hostname → canonical id; unknown → passthrough ──────
  eq "$(local_host_id "$fixture_json" latitude5520)" 'latitude5520' 'local_host_id: known → canonical'
  eq "$(local_host_id "$fixture_json" g614jv)"       'g614jv'       'local_host_id: windows known → canonical'
  eq "$(local_host_id "$fixture_json" Weird.Box)"    'Weird.Box'    'local_host_id: unknown → passthrough'
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — `local_host_id: command not found`.

- [ ] **Step 3: Write minimal implementation.** Add to `fleet-gather.sh`:

```bash
local_host_id() {
  # Map a live `hostname` to its fleet detect.hostname; passthrough if unknown.
  local json="${1:-$FLEET_JSON}" live="$2" id=""
  if [ -f "$json" ]; then
    id="$(jq -r --arg h "$live" '
      .machines | to_entries[]
      | select((.value.detect.hostname // "") == $h)
      | .value.detect.hostname' "$json" 2>/dev/null | head -1)"
  fi
  [ -n "$id" ] && printf '%s\n' "$id" || printf '%s\n' "$live"
}
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: the `local_host_id` assertions pass.

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb): local_host_id — resolve live hostname to fleet detect.hostname"
```

---

### Task 4: Pure helper `remote_distill_script` — static argv-driven run-script

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh`
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`

**Interfaces:**
- Produces: `remote_distill_script` — prints a **static** bash script (no interpolated values) to stdout. When run on a remote as `bash -s -- <hostid> <nroots> <root>... <match>...`, it: reads `$1`=host id, `$2`=root count, the next N args as roots, the rest as match substrings; expands a leading `~` in each root against `$HOME`; and runs `python3 ~/.cache/distill.py --projects-root "$root" --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json --host "$hostid" --match … ` once per root.

- [ ] **Step 1: Write the failing test.** Append (no jq needed — checks the emitted text shape):

```bash
# ── remote_distill_script: static, argv-driven, per-root loop ─────────────────
rds="$(remote_distill_script)"
printf '%s\n' "$rds" | grep -q -- '--projects-root' || fail 'rds: has --projects-root'
printf '%s\n' "$rds" | grep -q -- '--host'          || fail 'rds: passes --host'
printf '%s\n' "$rds" | grep -q '~/.cache/distill.py' || fail 'rds: invokes pushed distiller'
# argv-driven (values arrive as positional args, not interpolated):
printf '%s\n' "$rds" | grep -q 'shift'              || fail 'rds: consumes positional args'
printf '%s\n' "$rds" | grep -qF '"$@"'              || fail 'rds: reads remaining args'
# leading-~ expansion against remote $HOME:
printf '%s\n' "$rds" | grep -qF '${root/#\~/$HOME}' || fail 'rds: expands leading ~ against HOME'
# It is valid bash:
printf '%s\n' "$rds" | bash -n || fail 'rds: emitted script is not valid bash'
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — `remote_distill_script: command not found`.

- [ ] **Step 3: Write minimal implementation.** Add to `fleet-gather.sh`. Use a quoted heredoc (`<<'EOS'`) so nothing is interpolated at emit time:

```bash
remote_distill_script() {
  # Static run-script executed on a remote via `bash -s -- <hostid> <nroots>
  # <root>... <match>...`. All dynamic values arrive as positional args; the
  # only expansion is a leading ~ → remote $HOME (distill.py does NOT expanduser
  # an explicit --projects-root).
  cat <<'EOS'
set -euo pipefail
host="$1"; shift
nroots="$1"; shift
roots=(); for _ in $(seq 1 "$nroots"); do roots+=("$1"); shift; done
margs=(); for m in "$@"; do margs+=(--match "$m"); done
mkdir -p ~/.cache/kb-digests
for root in "${roots[@]}"; do
  root="${root/#\~/$HOME}"
  python3 ~/.cache/distill.py --projects-root "$root" \
    --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json \
    --host "$host" "${margs[@]}"
done
EOS
}
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: the `remote_distill_script` assertions pass.

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb): remote_distill_script — static argv-driven remote distiller"
```

---

### Task 5: Rewrite `detect_hosts` to drive off fleet.json + fix its test

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh` (`detect_hosts`)
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh` (the pre-existing `detect_hosts` block)

**Interfaces:**
- Consumes: `fleet_hosts` (Task 1).
- Produces: `detect_hosts [json_path] [ssh_config]` — emits the `fleet_hosts` TSV rows (`alias<TAB>platform<TAB>hostname<TAB>user`) **filtered** to aliases present as a `Host` entry in the ssh config. Defaults: `json_path`=`$FLEET_JSON`, `ssh_config`=`$HOME/.ssh/config`. Missing config → no output, rc 0.

- [ ] **Step 1: Rewrite the failing test.** Replace the existing `detect_hosts` block (the current lines that build `$tmp/.ssh/config`, source the script, and assert `got = "latitude server "`) with a version that passes the fixture json and asserts on the first field of each row:

```bash
# ── detect_hosts: fleet.json workstations ∩ ssh config Host entries ───────────
mkdir -p "$tmp/.ssh"
cat > "$tmp/.ssh/config" <<'EOF'
Host latitude
  HostName 100.64.0.2
Host server
  HostName 100.64.0.3
EOF
if command -v jq >/dev/null 2>&1; then
  aliases="$(detect_hosts "$fixture_json" "$tmp/.ssh/config" | cut -f1 | sort | tr '\n' ' ')"
  # desktop absent from config → excluded; hub never a workstation
  eq "$aliases" 'latitude server ' 'detect_hosts: config-present workstations only'
  # the emitted row is the full tuple, not just the alias
  detect_hosts "$fixture_json" "$tmp/.ssh/config" | grep -qP '^server\twindows\tmethe-server\tmethe$' \
    || fail 'detect_hosts: emits full tuple per host'
else
  echo "SKIP: detect_hosts test (jq not installed)"
fi
```

Ensure `$fixture_json` is defined before this block (Task 1 added it inside the jq guard; if the source order puts `detect_hosts` first, move the `fixture_json=` heredoc up so it is created before any test uses it). The `KB_GATHER_NO_MAIN=1 source "$script"` line and the `HOME`/`tmp` setup at the top of the file stay as-is.

- [ ] **Step 2: Run test to verify it fails.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — the old `detect_hosts` still ignores its args / references removed `FLEET_WORKSTATIONS`, so either a wrong alias set or an "unbound variable" error.

- [ ] **Step 3: Rewrite the implementation.** Replace the current `detect_hosts` (old lines ~9-23) with:

```bash
detect_hosts() {
  # fleet.json workstations that also have a Host entry in the ssh config.
  # Emits the full fleet_hosts tuple (alias<TAB>platform<TAB>hostname<TAB>user)
  # so main has platform/identity/user without a second jq pass.
  local json="${1:-$FLEET_JSON}" cfg="${2:-$HOME/.ssh/config}"
  [ -f "$cfg" ] || return 0
  local alias rest
  while IFS=$'\t' read -r alias rest; do
    [ -n "$alias" ] || continue
    if grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b${alias}\b" "$cfg"; then
      printf '%s\t%s\n' "$alias" "$rest"
    fi
  done < <(fleet_hosts "$json")
}
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: PASS — all pure-function blocks (Tasks 1-5) green; ends with a `PASS` line (add `echo "PASS: test_fleet_gather.sh"` as the final line if not already present).

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb): detect_hosts drives off fleet.json (carries platform/identity/user)"
```

---

### Task 6: Rewrite `main` — platform-dispatch IO (cat/tar, bash-wrapped, pushed distiller)

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh` (`main`)

**Interfaces:**
- Consumes: `detect_hosts`, `roots_for_platform`, `local_host_id`, `remote_distill_script`, and `distill.py --merge-from` (existing).
- Produces: no new pure surface — this is the IO wrapper. CLI unchanged: `fleet-gather.sh --out DIR --state FILE --match SUBSTR [--match …]`.

This task has no unit test (it is network IO). Verification = `bash -n` (syntax), the full offline test suite still green, and structural greps proving the Global Constraints hold. No bare `ssh $h <cmd>`, no `rsync`, must survive `bash -n`.

- [ ] **Step 1: Rewrite `main`.** Replace the current `main` (old lines ~26-89) with:

```bash
# Usage: fleet-gather.sh --out DIR --state FILE --match SUBSTR [--match SUBSTR ...]
main() {
  command -v jq >/dev/null 2>&1 || { echo "fleet-gather: jq required" >&2; return 3; }

  local out="" state="" matches=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2;;
      --state) state="$2"; shift 2;;
      --match) matches+=("$2"); shift 2;;
      *) echo "unknown arg: $1" >&2; return 2;;
    esac
  done
  [ -n "$out" ] && [ -n "$state" ] && [ "${#matches[@]}" -gt 0 ] || {
    echo "required: --out --state --match" >&2; return 2; }

  local match_args=(); local m
  for m in "${matches[@]}"; do match_args+=(--match "$m"); done

  local self_id; self_id="$(local_host_id "$FLEET_JSON" "$(hostname)")"

  echo "[local] distilling as '$self_id'…" >&2
  python3 "$SKILL_DIR/distill.py" --projects-root "$HOME/.claude/projects" \
    --out "$out" --state "$state" --host "$self_id" "${match_args[@]}"

  local alias platform hostid user
  while IFS=$'\t' read -r alias platform hostid user; do
    # Self-exclusion: compare the remote's resolved identity to ours. The probe
    # MUST be bash-wrapped — a bare `ssh $h hostname` runs in PowerShell and
    # returns the native Windows name.
    local remote_live
    remote_live="$(ssh "$alias" bash -lc 'hostname' 2>/dev/null || true)"
    if [ -n "$remote_live" ] && \
       [ "$(local_host_id "$FLEET_JSON" "$remote_live")" = "$self_id" ]; then
      echo "[$alias] is this box, skipping self" >&2
      continue
    fi

    # Reachability + cache dir (bash-wrapped; PowerShell mkdir has no -p).
    if ! ssh "$alias" bash -lc 'mkdir -p ~/.cache/kb-digests' 2>/dev/null; then
      echo "[$alias] skipped (unreachable)" >&2
      continue
    fi

    # Push the distiller (drop the deployed-symlink dependency) + seed the
    # git-tracked watermark, both via cat (rsync fails on Windows).
    if ! ssh "$alias" bash -lc 'cat > ~/.cache/distill.py' < "$SKILL_DIR/distill.py"; then
      echo "[$alias] distiller push failed" >&2
      continue
    fi
    ssh "$alias" bash -lc 'cat > ~/.cache/kb-harvest-state.json' < "$state" \
      || echo "[$alias] state seed failed (remote falls back to its own cache)" >&2

    # Distill every root for this platform (Windows: profile + WSL; unix: home).
    local roots=(); mapfile -t roots < <(roots_for_platform "$platform" "$user")
    echo "[$alias] distilling in-place as '$hostid' (${#roots[@]} root(s))…" >&2
    if ! remote_distill_script | \
         ssh "$alias" bash -s -- "$hostid" "${#roots[@]}" "${roots[@]}" "${matches[@]}"; then
      echo "[$alias] remote distill failed" >&2
      continue
    fi

    # Merge the remote's advanced watermark back (only its `sessions`).
    local tmp_state; tmp_state="$(mktemp)"
    if ssh "$alias" bash -lc 'cat ~/.cache/kb-harvest-state.json' > "$tmp_state" 2>/dev/null; then
      python3 "$SKILL_DIR/distill.py" --merge-from "$tmp_state" --state "$state" >/dev/null \
        || echo "[$alias] state merge-back failed" >&2
    fi
    rm -f "$tmp_state"

    # Pull digests via tar (rsync fails on Windows). Exclude manifest.tsv — the
    # local manifest accumulates and a plain copy would clobber it.
    echo "[$alias] pulling digests…" >&2
    ssh "$alias" bash -lc 'cd ~/.cache/kb-digests 2>/dev/null && tar cf - --exclude=manifest.tsv . 2>/dev/null' \
      | tar xf - -C "$out" 2>/dev/null \
      || echo "[$alias] digest pull failed" >&2
  done < <(detect_hosts "$FLEET_JSON")
}
```

- [ ] **Step 2: Verify syntax.**

Run: `bash -n agents/plugin/skills/kb-refresh/fleet-gather.sh`
Expected: no output, rc 0.

- [ ] **Step 3: Verify the Global Constraints structurally.**

Run:
```bash
f=agents/plugin/skills/kb-refresh/fleet-gather.sh
grep -n 'rsync' "$f" && echo "BAD: rsync still present" || echo "OK: no rsync"
grep -nE 'ssh "\$alias" [^b]' "$f" && echo "BAD: bare ssh (not bash-wrapped)" || echo "OK: all remote cmds bash-wrapped"
grep -q 'exclude=manifest.tsv' "$f" && echo "OK: manifest excluded on pull" || echo "BAD: manifest not excluded"
```
Expected: `OK: no rsync`, `OK: all remote cmds bash-wrapped`, `OK: manifest excluded on pull`. (The `ssh "$alias"` grep excludes lines where the next token is not `bash`; every remote call in the rewrite is `ssh "$alias" bash …`, so it should print nothing before the OK.)

- [ ] **Step 4: Verify the offline test suite still passes.**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: PASS (sourcing with `KB_GATHER_NO_MAIN=1` never runs `main`, so no network is touched).

- [ ] **Step 5: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh
git commit -m "feat(kb): main — platform-dispatch harvest (cat/tar, bash-wrapped, pushed distiller)"
```

---

### Task 7: Update docs — project.md caveat + SKILL.md remote-path description

**Files:**
- Modify: `.claude/memory/project.md` (the kb-refresh "no Nix on Windows / can't reach Windows" caveat about fleet-gather)
- Modify: `agents/plugin/skills/kb-refresh/SKILL.md` (Step 1 description of the remote path)

No test. Verification = the claims match the shipped code.

- [ ] **Step 1: Update `SKILL.md` Step 1.** Find the paragraph describing `fleet-gather.sh`'s remote behavior (it currently says it `rsync`s the state file, runs `distill.py` from the deployed symlink path, uses the ssh alias as `--host`, and `rsync`s digests back). Replace the mechanism description with the shipped one:

```markdown
- `fleet-gather.sh` always distills this box locally first (invoking
  `distill.py --projects-root ~/.claude/projects --out <scratch> --state <state-file>
  --host <this box's fleet detect.hostname>`), then reads `fleet.json` (repo
  root) via `detect_hosts` for the workstation members (hub excluded) that also
  have a `Host` entry in `~/.ssh/config`. For each present, reachable, non-self
  box (self-exclusion by a bash-wrapped `hostname` probe compared to fleet
  identity) it: seeds that box's `~/.cache/kb-harvest-state.json` with the
  authoritative git-tracked watermark and pushes `distill.py` (both via `cat`
  over ssh — no deployed skill needed on the remote); runs `distill.py`
  **in place** against the seeded state, once per projects root for the box's
  platform (Windows: the Windows profile `/mnt/c/Users/<ssh.user>/.claude/projects`
  **and** WSL `~/.claude/projects`; unix: `~/.claude/projects`); pulls the
  remote state back and merges only its `sessions` map via
  `distill.py --merge-from`; then pulls the resulting digests via `tar`
  (excluding `manifest.tsv`). Every remote command is bash-wrapped, so the
  Windows members (whose ssh lands in PowerShell) dispatch correctly to WSL
  bash; raw transcripts never leave their machine. No fleet aliases configured
  → silently local-only.
```

- [ ] **Step 2: Update the `project.md` caveat.** Find the kb-refresh bullet stating fleet-gather can't reach the Windows boxes (near the "Windows fleet boxes have no Nix" material). Replace the "can't reach Windows" claim with:

```markdown
- `fleet-gather.sh` now harvests the **Windows** fleet members (desktop=g614jv,
  server=methe-server): it dispatches on `fleet.json` `platform`, bash-wraps
  every remote command (Windows ssh lands in PowerShell), pushes `distill.py`
  and transports state/digests over `cat`/`tar` (no rsync), distills both the
  Windows-profile and WSL projects roots, and stamps digests with the fleet
  `detect.hostname`. Design: `docs/superpowers/specs/2026-07-19-fleet-gather-windows-design.md`.
```

- [ ] **Step 3: Verify the docs match the code.**

Run:
```bash
grep -n 'rsync' agents/plugin/skills/kb-refresh/SKILL.md && echo "CHECK: SKILL.md still mentions rsync" || echo "OK: SKILL.md rsync-free"
```
Expected: `OK: SKILL.md rsync-free` (unless an unrelated rsync mention exists elsewhere in the file — inspect if so).

- [ ] **Step 4: Commit.**

```bash
git add agents/plugin/skills/kb-refresh/SKILL.md .claude/memory/project.md
git commit -m "docs(kb): fleet-gather now handles the Windows fleet"
```

---

## Notes for the executor

- **Test file source order:** the fixture `fleet.json` heredoc (`fixture_json=`) must be created before ANY test block that passes it (Tasks 1, 3, 5). If you place the fixture inside the Task 1 jq-guard but Task 5's `detect_hosts` block ends up earlier in the file, hoist the `fixture_json=` heredoc to just after the `trap …` line so it is unconditional and first. Keep the top-of-file scaffolding (`tmp="$(mktemp -d)"`, `trap`, `export HOME="$tmp"`, `KB_GATHER_NO_MAIN=1 source "$script"`) intact.
- **`grep -P`** (PCRE) is used in tests for `\t`; it is available in the GNU grep the fleet uses. If a box lacks `-P`, swap to `grep -qE $'…\t…'` with a literal tab.
- **Do NOT run `main` / the live harvest** as part of this plan — that is Job 2, downstream, run from the `~/machines` main checkout after this branch FF-merges. Implementation here is code + offline tests only.
```
