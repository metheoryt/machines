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
