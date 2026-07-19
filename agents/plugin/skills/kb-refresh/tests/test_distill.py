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
