"""Mechanical jsonl-transcript distiller for the cyphy kb-refresh skill.

Stdlib only. Strips Claude Code session .jsonl into a compact per-session
digest (human turns, assistant prose, Bash commands, edited file paths).
Transcripts are treated as read-only, append-only logs.
"""
import argparse
import glob
import hashlib
import json
import os

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
        try:
            sid_probe = json.loads(lines[0]).get("sessionId")
        except (json.JSONDecodeError, AttributeError):
            sid_probe = None
        sid = sid_probe or os.path.splitext(os.path.basename(path))[0]
        start = resume_offset(sessions, sid, lines)
        new_lines = lines[start:]
        digest_body, meta = distill_lines(new_lines)
        prev = sessions.get(sid, {})
        # always advance the watermark, even if the new slice was pure noise
        sessions[sid] = {
            "last_line": len(lines),
            "id_hash": identity_hash(lines),
            "host": host,
            "cwd": meta.get("cwd") or prev.get("cwd"),
            "last_ts": meta.get("last_ts") or prev.get("last_ts"),
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
