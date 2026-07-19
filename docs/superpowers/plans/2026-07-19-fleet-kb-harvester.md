# Fleet KB Harvester Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repo-agnostic `/cyphy:kb-refresh` capability that harvests knowledge from scattered per-machine Claude transcripts (append-only, read-once) and reconciles docs against code (git-diff since last refresh), merging results into the KB tiers behind a mandatory human review gate.

**Architecture:** A mechanical Python distiller (`distill.py`, stdlib-only) strips transcript `.jsonl` into compact per-session digests using a git-tracked line-offset watermark so each turn is read exactly once. A shell helper (`fleet-gather.sh`) runs the distiller in-place on fleet boxes over the tailnet and rsyncs only the small digests back. A `SKILL.md` orchestrates the LLM stages (subagent map → dedup reduce → review gate → tier write → provenance stamp). Ships inside the `cyphy` plugin so it's present in every repo/profile/machine.

**Tech Stack:** Python 3.13 (stdlib only — `json`, `argparse`, `hashlib`, `pathlib`, `glob`), Bash, `ssh`/`rsync` over the fleet tailnet, `uv` for running tests. Design doc: `docs/superpowers/specs/2026-07-19-fleet-kb-harvester-design.md`.

## Global Constraints

- **Zero third-party deps in `distill.py`** — stdlib only, so it runs on any fleet box with `python3`.
- **Transcripts are read-only** — never write/edit/rename/delete anything under `~/.claude/projects/**`.
- **Only git-tracked files are written by the KB write stage** — memory tiers, `CLAUDE.md`, repo docs, the state file. Digests are ephemeral scratch, never committed.
- **Read-once invariant** — a transcript line, once distilled, is never distilled again (line-offset watermark in the git-tracked state file).
- **Plugin location** — everything ships under `agents/plugin/skills/kb-refresh/`. Namespace is `cyphy` (from `agents/plugin/.claude-plugin/plugin.json`).
- **Run tests with:** `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/`
- **State file schema** (target repo's `.claude/kb-harvest-state.json`): `distill.py` owns the `sessions` key only; the SKILL's write stage owns the `last_refresh` key only. Both do merge-preserving read-modify-write.
- **Transcript schema** (verified): each `.jsonl` line is one event with a top-level `type`. Human turns = `type=="user"` with `.message.content` of type **string**. Assistant prose = `type=="assistant"`, `.message.content[]` blocks where `.type=="text"` → keep `.text`. From `.type=="tool_use"` blocks keep: `name=="Bash"` → `.input.command`; `name in {Edit,Write,MultiEdit,NotebookEdit}` → `.input.file_path`. Drop everything else (`thinking`, `tool_result`, array-type user events, attachments, `ai-title`, `mode`, `system`, etc.). Event metadata: `.sessionId`, `.cwd`, `.gitBranch`, `.timestamp`.

---

### Task 1: `distill.py` — single-session jsonl → digest (full read)

**Files:**
- Create: `agents/plugin/skills/kb-refresh/distill.py`
- Test: `agents/plugin/skills/kb-refresh/tests/test_distill.py`

**Interfaces:**
- Produces: `distill_lines(lines: list[str]) -> tuple[str, dict]` — takes raw jsonl lines, returns `(digest_text, meta)` where `meta = {"session_id", "cwd", "branch", "first_ts", "last_ts", "n_lines"}`. `digest_text` is the compact markdown stream (no header; header added by the CLI in Task 3).

- [ ] **Step 1: Write the failing test**

```python
# agents/plugin/skills/kb-refresh/tests/test_distill.py
import json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import distill

def _ev(**kw):
    return json.dumps(kw)

def test_distill_lines_extracts_signal_and_drops_noise():
    lines = [
        _ev(type="user", sessionId="S1", cwd="/home/me/machines", gitBranch="main",
            timestamp="2026-07-17T10:00:00Z", message={"role": "user", "content": "add a swap module"}),
        _ev(type="assistant", sessionId="S1", timestamp="2026-07-17T10:01:00Z",
            message={"role": "assistant", "content": [{"type": "thinking", "thinking": "secret"}]}),
        _ev(type="assistant", sessionId="S1", timestamp="2026-07-17T10:01:30Z",
            message={"role": "assistant", "content": [{"type": "text", "text": "I'll add ZRAM swap."}]}),
        _ev(type="assistant", sessionId="S1", timestamp="2026-07-17T10:02:00Z",
            message={"role": "assistant", "content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": "just check"}}]}),
        _ev(type="assistant", sessionId="S1", timestamp="2026-07-17T10:03:00Z",
            message={"role": "assistant", "content": [
                {"type": "tool_use", "name": "Edit", "input": {"file_path": "modules/system/base.nix"}}]}),
        _ev(type="user", sessionId="S1", timestamp="2026-07-17T10:04:00Z",
            message={"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}),
    ]
    digest, meta = distill.distill_lines(lines)
    assert "[USER] add a swap module" in digest
    assert "[ASSISTANT] I'll add ZRAM swap." in digest
    assert "[BASH] just check" in digest
    assert "[EDIT] modules/system/base.nix" in digest
    assert "secret" not in digest          # thinking dropped
    assert "tool_result" not in digest     # array-user dropped
    assert meta["session_id"] == "S1"
    assert meta["cwd"] == "/home/me/machines"
    assert meta["branch"] == "main"
    assert meta["first_ts"] == "2026-07-17T10:00:00Z"
    assert meta["n_lines"] == 6
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/test_distill.py::test_distill_lines_extracts_signal_and_drops_noise`
Expected: FAIL — `ModuleNotFoundError: No module named 'distill'` (or `AttributeError: module 'distill' has no attribute 'distill_lines'`).

- [ ] **Step 3: Write minimal implementation**

```python
# agents/plugin/skills/kb-refresh/distill.py
"""Mechanical jsonl-transcript distiller for the cyphy kb-refresh skill.

Stdlib only. Strips Claude Code session .jsonl into a compact per-session
digest (human turns, assistant prose, Bash commands, edited file paths).
Transcripts are treated as read-only, append-only logs.
"""
import json

_EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}


def distill_lines(lines):
    """Return (digest_text, meta) for a list of raw jsonl lines."""
    out = []
    session_id = cwd = branch = first_ts = last_ts = None
    n = 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        n += 1
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        ts = ev.get("timestamp")
        if ts:
            first_ts = first_ts or ts
            last_ts = ts
        session_id = session_id or ev.get("sessionId")
        if ev.get("cwd"):
            cwd = ev["cwd"]
        if ev.get("gitBranch"):
            branch = ev["gitBranch"]
        etype = ev.get("type")
        msg = ev.get("message") or {}
        content = msg.get("content")
        if etype == "user" and isinstance(content, str):
            text = content.strip()
            if text:
                out.append(f"[USER] {text}")
        elif etype == "assistant" and isinstance(content, list):
            for block in content:
                bt = block.get("type")
                if bt == "text":
                    text = (block.get("text") or "").strip()
                    if text:
                        out.append(f"[ASSISTANT] {text}")
                elif bt == "tool_use":
                    name = block.get("name")
                    inp = block.get("input") or {}
                    if name == "Bash" and inp.get("command"):
                        out.append(f"[BASH] {inp['command']}")
                    elif name in _EDIT_TOOLS and inp.get("file_path"):
                        out.append(f"[EDIT] {inp['file_path']}")
    meta = {
        "session_id": session_id,
        "cwd": cwd,
        "branch": branch,
        "first_ts": first_ts,
        "last_ts": last_ts,
        "n_lines": n,
    }
    return "\n".join(out), meta
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/test_distill.py::test_distill_lines_extracts_signal_and_drops_noise`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/kb-refresh/distill.py agents/plugin/skills/kb-refresh/tests/test_distill.py
git commit -m "feat(kb-refresh): jsonl transcript distiller core

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `distill.py` — read-once watermark (incremental resume)

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/distill.py`
- Test: `agents/plugin/skills/kb-refresh/tests/test_distill.py`

**Interfaces:**
- Produces: `resume_offset(state_sessions: dict, session_id: str, lines: list[str]) -> int` — returns the line index to start distilling from. `0` if the session is new, unknown, was truncated (stored `last_line` > current length), or its identity hash changed; otherwise the stored `last_line`.
- Produces: `identity_hash(lines: list[str]) -> str` — sha1 of the first non-empty line (which carries `sessionId` + first timestamp), hex digest. `""` for empty input.

- [ ] **Step 1: Write the failing test**

```python
def test_identity_hash_stable_and_first_line_based():
    a = ['{"sessionId":"S1","x":1}', '{"y":2}']
    b = ['{"sessionId":"S1","x":1}', '{"y":9}']   # differs after line 0
    c = ['{"sessionId":"S2","x":1}', '{"y":2}']   # differs at line 0
    assert distill.identity_hash(a) == distill.identity_hash(b)
    assert distill.identity_hash(a) != distill.identity_hash(c)
    assert distill.identity_hash([]) == ""

def test_resume_offset_rules():
    lines = ['{"sessionId":"S1"}'] + ['{"n":%d}' % i for i in range(1, 10)]  # 10 lines
    h = distill.identity_hash(lines)
    # new session -> 0
    assert distill.resume_offset({}, "S1", lines) == 0
    # known session, same identity, resume from stored last_line
    st = {"S1": {"last_line": 6, "id_hash": h}}
    assert distill.resume_offset(st, "S1", lines) == 6
    # identity changed (file rewritten) -> reprocess from 0
    st_bad = {"S1": {"last_line": 6, "id_hash": "deadbeef"}}
    assert distill.resume_offset(st_bad, "S1", lines) == 0
    # truncated (stored beyond current length) -> 0
    st_trunc = {"S1": {"last_line": 99, "id_hash": h}}
    assert distill.resume_offset(st_trunc, "S1", lines) == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/test_distill.py -k "identity_hash or resume_offset"`
Expected: FAIL — `AttributeError: module 'distill' has no attribute 'identity_hash'`.

- [ ] **Step 3: Write minimal implementation**

Add to `distill.py` (after the imports add `import hashlib`):

```python
def identity_hash(lines):
    for raw in lines:
        raw = raw.strip()
        if raw:
            return hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()
    return ""


def resume_offset(state_sessions, session_id, lines):
    entry = state_sessions.get(session_id)
    if not entry:
        return 0
    last_line = entry.get("last_line", 0)
    if last_line > len(lines):            # truncated / rewritten shorter
        return 0
    if entry.get("id_hash") != identity_hash(lines):  # identity changed
        return 0
    return last_line
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/test_distill.py -k "identity_hash or resume_offset"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/kb-refresh/distill.py agents/plugin/skills/kb-refresh/tests/test_distill.py
git commit -m "feat(kb-refresh): read-once watermark (resume offset + identity hash)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `distill.py` — CLI (discover, distill, write digests + manifest + state merge)

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/distill.py`
- Test: `agents/plugin/skills/kb-refresh/tests/test_distill.py`

**Interfaces:**
- Produces: `run(projects_root, matches, out_dir, state_path, host) -> dict` — discovers `projects_root/*<m>*/*.jsonl` for each `m` in `matches`, distills each session from its resume offset, writes one `<session_id>.md` digest per session that produced new content (with a header), appends a manifest row, and merge-writes the `sessions` key of the state JSON (preserving any `last_refresh`). Returns a summary dict `{"sessions_seen", "sessions_with_new", "digests_written"}`. Digest header format: lines starting `# session:`, `# host:`, `# cwd:`, `# branch:`, `# range:`.
- Produces: CLI `python3 distill.py --projects-root DIR --match SUBSTR [--match SUBSTR ...] --out DIR --state FILE [--host NAME]`.

- [ ] **Step 1: Write the failing test**

```python
def test_run_writes_digests_manifest_and_merges_state(tmp_path):
    # fake ~/.claude/projects layout
    proj = tmp_path / "projects" / "-home-me-machines"
    proj.mkdir(parents=True)
    sess = proj / "S1.jsonl"
    sess.write_text("\n".join([
        json.dumps({"type": "user", "sessionId": "S1", "cwd": "/home/me/machines",
                    "gitBranch": "main", "timestamp": "2026-07-17T10:00:00Z",
                    "message": {"role": "user", "content": "hello"}}),
        json.dumps({"type": "assistant", "sessionId": "S1", "timestamp": "2026-07-17T10:01:00Z",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "hi"}]}}),
    ]) + "\n")
    out = tmp_path / "digests"
    state = tmp_path / "state.json"
    # pre-seed an unrelated last_refresh to prove merge-preservation
    state.write_text(json.dumps({"last_refresh": {"commit": "abc123"}}))

    summary = distill.run(str(tmp_path / "projects"), ["machines"], str(out), str(state), host="testbox")
    assert summary["digests_written"] == 1
    digest = (out / "S1.md").read_text()
    assert "# session: S1" in digest
    assert "# host: testbox" in digest
    assert "[USER] hello" in digest and "[ASSISTANT] hi" in digest

    st = json.loads(state.read_text())
    assert st["last_refresh"] == {"commit": "abc123"}          # preserved
    assert st["sessions"]["S1"]["last_line"] == 2
    assert st["sessions"]["S1"]["host"] == "testbox"
    assert "id_hash" in st["sessions"]["S1"]
    assert (out / "manifest.tsv").exists()

    # second run over the SAME unchanged file -> nothing new (read-once)
    summary2 = distill.run(str(tmp_path / "projects"), ["machines"], str(out), str(state), host="testbox")
    assert summary2["digests_written"] == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/test_distill.py::test_run_writes_digests_manifest_and_merges_state`
Expected: FAIL — `AttributeError: module 'distill' has no attribute 'run'`.

- [ ] **Step 3: Write minimal implementation**

Add to `distill.py` (add `import argparse, glob, os` to imports):

```python
def _load_state(state_path):
    if os.path.exists(state_path):
        try:
            with open(state_path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def run(projects_root, matches, out_dir, state_path, host=None):
    os.makedirs(out_dir, exist_ok=True)
    state = _load_state(state_path)
    sessions = state.setdefault("sessions", {})
    manifest = []
    seen = with_new = written = 0

    paths = []
    for m in matches:
        paths += glob.glob(os.path.join(projects_root, f"*{m}*", "*.jsonl"))
    for path in sorted(set(paths)):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        if not lines:
            continue
        seen += 1
        sid_probe = json.loads(lines[0]).get("sessionId") if lines else None
        sid = sid_probe or os.path.splitext(os.path.basename(path))[0]
        start = resume_offset(sessions, sid, lines)
        new_lines = lines[start:]
        digest_body, meta = distill_lines(new_lines)
        # always advance the watermark, even if the new slice was pure noise
        sessions[sid] = {
            "last_line": len(lines),
            "id_hash": identity_hash(lines),
            "host": host,
            "cwd": meta.get("cwd"),
            "last_ts": meta.get("last_ts"),
        }
        if digest_body.strip():
            with_new += 1
            header = (
                f"# session: {sid}\n"
                f"# host: {host}\n"
                f"# cwd: {meta.get('cwd')}\n"
                f"# branch: {meta.get('branch')}\n"
                f"# range: lines {start}..{len(lines)} "
                f"({meta.get('first_ts')} .. {meta.get('last_ts')})\n\n"
            )
            with open(os.path.join(out_dir, f"{sid}.md"), "w") as f:
                f.write(header + digest_body + "\n")
            written += 1
            manifest.append(f"{sid}\t{host}\t{meta.get('cwd')}\t{start}\t{len(lines)}\t{meta.get('last_ts')}")

    with open(os.path.join(out_dir, "manifest.tsv"), "a") as f:
        for row in manifest:
            f.write(row + "\n")
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    return {"sessions_seen": seen, "sessions_with_new": with_new, "digests_written": written}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Distill Claude transcripts into KB digests.")
    ap.add_argument("--projects-root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--match", action="append", required=True,
                    help="substring of the project slug to include (repeatable)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--host", default=None)
    args = ap.parse_args(argv)
    summary = run(args.projects_root, args.match, args.out, args.state, args.host)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the full test file**

Run: `uv run --with pytest pytest -q agents/plugin/skills/kb-refresh/tests/`
Expected: PASS (all tests from Tasks 1–3).

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/kb-refresh/distill.py agents/plugin/skills/kb-refresh/tests/test_distill.py
git commit -m "feat(kb-refresh): distill CLI — discover, digest, manifest, state merge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `fleet-gather.sh` — fleet detection + in-place remote distill + rsync digests back

**Files:**
- Create: `agents/plugin/skills/kb-refresh/fleet-gather.sh`
- Test: `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`

**Interfaces:**
- Consumes: `distill.py` (Task 3) — invoked locally and on each remote host.
- Produces: a shell script with a `detect_hosts` function (echoes fleet SSH aliases that resolve in `~/.ssh/config`, one per line, excluding the current host) and a `main` that: (1) runs `distill.py` locally, (2) for each detected host, `ssh <host>` runs `distill.py` in-place against that box's `~/.claude/projects`, then `rsync` pulls only the resulting digests into the local out dir. Fleet steps are skipped cleanly when no hosts resolve.

**Notes for the implementer:**
- The fleet aliases are `latitude`, `desktop`, `server` (workstations; `hub` is the VPS — exclude it). Detection = alias present in `~/.ssh/config` **and** not equal to the current hostname.
- The remote login shell is **fish**, which mishandles POSIX `$(...)`/`test` in `ssh host '<script>'`. Force bash: `ssh <host> bash -lc '<cmd>'`. This is a known fleet gotcha (see `global.md`).
- Keep the script thin: all parsing/logic that deserves a test lives in `distill.py`; the shell only orchestrates ssh/rsync. Test only the pure, side-effect-free `detect_hosts`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../fleet-gather.sh"

# fake HOME with an ssh config that lists two of three fleet aliases
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.ssh"
cat > "$tmp/.ssh/config" <<EOF
Host latitude
  HostName 100.64.0.2
Host server
  HostName 100.64.0.3
EOF

# source the script's functions without running main
KB_GATHER_NO_MAIN=1 HOME="$tmp" source "$script"
got="$(detect_hosts | sort | tr '\n' ' ')"
# 'desktop' absent from config -> excluded; 'hub' never included
[ "$got" = "latitude server " ] || { echo "FAIL: got '$got'"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: FAIL — script does not exist yet (`No such file or directory`).

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are rsynced back.
set -euo pipefail

FLEET_WORKSTATIONS=(latitude desktop server)   # 'hub' is the VPS, excluded
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_hosts() {
  local cfg="${HOME}/.ssh/config"
  [ -f "$cfg" ] || return 0
  local self; self="$(hostname 2>/dev/null || echo)"
  local h
  for h in "${FLEET_WORKSTATIONS[@]}"; do
    [ "$h" = "$self" ] && continue
    if grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b${h}\b" "$cfg"; then
      echo "$h"
    fi
  done
}

# Usage: fleet-gather.sh --out DIR --state FILE --match SUBSTR [--match SUBSTR ...]
main() {
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

  echo "[local] distilling…" >&2
  python3 "$SKILL_DIR/distill.py" --out "$out" --state "$state" \
    --host "$(hostname)" "${match_args[@]}"

  local h
  for h in $(detect_hosts); do
    echo "[$h] distilling in-place…" >&2
    # Run the (synced) distiller on the remote box; force bash — remote shell is fish.
    ssh "$h" bash -lc "'python3 ~/.claude/plugins/cache/*/cyphy/*/skills/kb-refresh/distill.py \
      --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json --host $h ${match_args[*]}'" \
      || { echo "[$h] skipped (unreachable)" >&2; continue; }
    echo "[$h] pulling digests…" >&2
    rsync -az "$h:.cache/kb-digests/" "$out/" || echo "[$h] rsync failed" >&2
  done
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
chmod +x agents/plugin/skills/kb-refresh/fleet-gather.sh
git add agents/plugin/skills/kb-refresh/fleet-gather.sh agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
git commit -m "feat(kb-refresh): fleet-gather — in-place remote distill + rsync digests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `SKILL.md` — orchestration (gather → map → reduce → review → write → stamp)

**Files:**
- Create: `agents/plugin/skills/kb-refresh/SKILL.md`

**Interfaces:**
- Consumes: `distill.py`, `fleet-gather.sh`, the target repo's `.claude/kb-harvest-state.json`.
- Produces: the human-facing workflow the invoking agent follows. No unit test — verified by a manual checklist (Step 3).

- [ ] **Step 1: Write `SKILL.md`**

Write the file with this exact frontmatter and section skeleton (fill each section with the operational detail from the spec — do not leave any bullet as a placeholder):

````markdown
---
name: kb-refresh
description: Use when the user wants to refresh a repo's knowledge base (CLAUDE.md, memory tiers, docs) from scattered per-machine Claude transcripts and/or reconcile the docs against the current code. Harvests append-only transcripts read-once, dedups against existing memory, and merges behind a mandatory review gate. Works in any repo; auto-detects the fleet for cross-machine gather.
---

# Refresh a repo's knowledge base

## What this does
Two source tracks → one review gate → tier writes, stamped with the commit
they were generated against. Target repo = the current repo (cwd).

## Invariants (never violate)
- Transcripts under `~/.claude/projects/**` are READ-ONLY, append-only.
- Read-once: never re-distill a line already recorded in the watermark.
- Only git-tracked files are written by the write stage. Digests are scratch.
- Nothing lands in memory without passing the review gate.

## Step 0 — Resolve target & derive slugs
- `repo="$(git rev-parse --show-toplevel)"`; provenance base = `git -C "$repo" rev-parse HEAD`.
- Slug matches = the repo's basename + any known worktree path fragments
  (e.g. repo dir name, and `orca/workspaces/<name>` segments). Pass each as `--match`.
- State file: `"$repo/.claude/kb-harvest-state.json"`. Digests out dir: a scratchpad path.

## Step 1 — Gather + distill (mechanical, read-once)
- Run `fleet-gather.sh --out <scratch/digests> --state <repo>/.claude/kb-harvest-state.json --match <m> [...]`.
- It distills locally, and — if fleet hosts resolve — in-place on each box, pulling back only digests.
- Report the summary (sessions seen / with-new / digests written). If zero new digests, say so and skip to Track B.

## Step 2 — Track A map (subagent fan-out)
- Batch the digests (~15 per batch). Dispatch one subagent per batch.
- Each subagent returns candidate facts as rows: `{tier, topic, fact, source-session, confidence}`.
- Tier ∈ {global, host:<name>, project, claude-md, docs}.

## Step 3 — Track B (code/git reconciliation)
- Baseline = state file's `last_refresh.commit`; if absent, full pass.
- Diff `git -C "$repo" log/diff <base>..HEAD` over code/config vs the docs.
- Emit the same row shape with `action ∈ {add, edit, delete}`.

## Step 4 — Reduce / dedup
- Read the CURRENT tier files in full (they're the baseline + write target).
- Drop candidates already covered; keep new or now-wrong; cluster by topic.

## Step 5 — Review gate (MANDATORY)
- Present ONE proposal: rows grouped by tier, each `add|edit|delete + target file + source + confidence`.
- User approves / trims. Do not write until approved.

## Step 6 — Write + stamp + commit
- Apply approved rows to the tier files (universal: global.md, host-memory.md;
  per-repo: project.md, CLAUDE.md, docs/). Offer to create project.md if absent.
- Update the state file `last_refresh` = {commit, date, tiers_touched, sessions_processed}
  (merge-preserving — leave `sessions` intact).
- Stamp `project.md` with `<!-- KB refreshed against <short-sha> on <date> -->` (single location).
- Commit the changed git-tracked files.

## Tier reference
[Copy the tier table from the spec: which facts go to global vs host vs project vs CLAUDE.md vs docs.]
````

- [ ] **Step 2: Verify the skill is discoverable**

Run: `grep -l "name: kb-refresh" agents/plugin/skills/kb-refresh/SKILL.md`
Expected: prints the path (frontmatter present).

- [ ] **Step 3: Manual self-review checklist**

Confirm each is true, fix inline if not:
- [ ] Every step names a real script/path that exists from Tasks 1–4.
- [ ] The three invariants appear verbatim near the top.
- [ ] The tier reference table is filled (not a `[Copy…]` placeholder) from the spec.
- [ ] The review gate is described as mandatory and pre-write.
- [ ] No `TODO`/`TBD`/placeholder bullets remain.

- [ ] **Step 4: Commit**

```bash
git add agents/plugin/skills/kb-refresh/SKILL.md
git commit -m "feat(kb-refresh): SKILL.md orchestration (gather→map→reduce→review→write)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Catch-up run against `machines` (human-in-the-loop; produces the actual KB refresh)

**Files:**
- Modify (via the skill, after approval): `.claude/memory/project.md`, `CLAUDE.md`, `agents/memory/global.md`, `agents/hosts/<host>.md`, `agents/docs/*.md` as approved.
- Create: `.claude/kb-harvest-state.json` (seeded by the run).

**Interfaces:**
- Consumes: the completed `kb-refresh` skill (Tasks 1–5).

**This task has no unit test** — its acceptance is a reviewed, committed refresh with a provenance stamp. Do NOT auto-approve; the review gate is the gate.

- [ ] **Step 1: Invoke the skill against this repo**

Invoke `/cyphy:kb-refresh`. Target repo = `machines`. Slug matches include `machines` and the orca-worktree fragments. First run: no `last_refresh`, so Track B does a full-history pass and the watermark seeds from empty.

- [ ] **Step 2: Run gather across the fleet**

Follow the skill Step 1. Expect ~200 sessions fleet-wide (55 local + latitude/desktop/server). Confirm the summary is non-trivial and digests landed in the scratch dir.

- [ ] **Step 3: Map + Track B + reduce**

Follow skill Steps 2–4. Fan out ~13 map subagents; run Track B against full history (first run). Produce the clustered proposal.

- [ ] **Step 4: STOP at the review gate**

Present the proposal to the user. Wait for approval/trims. Do not write anything.

- [ ] **Step 5: Write, stamp, commit (after approval)**

Follow skill Step 6. Apply approved rows, write `last_refresh`, stamp `project.md`, commit on `refresh-kb`.

Run: `git -C . log --oneline -1` and `grep -c "KB refreshed against" .claude/memory/project.md`
Expected: a commit landed; the stamp line exists (count ≥ 1).

---

## Self-Review

**Spec coverage:**
- Repo-agnostic skill in cyphy plugin → Tasks 1–5 (all under `agents/plugin/skills/kb-refresh/`). ✓
- Mechanical jsonl→digest distiller, stdlib only → Task 1. ✓
- Read-once watermark (offset + identity hash), fleet-wide via git-tracked state → Tasks 2–3. ✓
- CLI + manifest + merge-preserving state → Task 3. ✓
- Fleet-gather in-place, digests-only travel, auto-detect, fish gotcha → Task 4. ✓
- Read model (transcripts once / code git-diff / KB files full) → encoded in SKILL Steps 3–4 + state `last_refresh` baseline. ✓
- Tier mapping (universal vs per-repo) → SKILL tier reference + Task 6 files. ✓
- Mandatory review gate + provenance stamp → SKILL Steps 5–6, Task 6 acceptance. ✓
- Catch-up run now → Task 6. ✓

**Placeholder scan:** The only intentional fill-in is the SKILL tier table (Task 5, Step 1 marks it `[Copy…]`) and its removal is a checklist item (Task 5, Step 3). No code steps contain placeholders.

**Type consistency:** `distill_lines` / `identity_hash` / `resume_offset` / `run` / `main` signatures are consistent across Tasks 1–4. State keys (`sessions`, `last_line`, `id_hash`, `host`, `cwd`, `last_ts`; `last_refresh`) are consistent between `distill.py` (owns `sessions`) and SKILL Step 6 (owns `last_refresh`).
