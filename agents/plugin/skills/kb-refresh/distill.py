"""Mechanical jsonl-transcript distiller for the cyphy kb-refresh skill.

Stdlib only. Strips Claude Code session .jsonl into a compact per-session
digest (human turns, assistant prose, Bash commands, edited file paths).
Transcripts are treated as read-only, append-only logs.
"""
import hashlib
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
