#!/usr/bin/env bash
# Unit test for orca-repair's pure detection/prune logic. No Orca, no network.
# Run: bash orca-repair.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$HERE/.." <<'PY'
import importlib.util, sys, os
skill_dir = sys.argv[1]
spec = importlib.util.spec_from_file_location("orca_repair", os.path.join(skill_dir, "orca-repair.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

fails = []
def check(name, cond):
    print(("  ok  " if cond else " FAIL ") + name)
    if not cond: fails.append(name)

# Fixture: two runtimes. LIVE has one valid recent, one stale recent, and one
# --match target. GONE's environment was removed (orphaned block).
LIVE = "runtime:env-live"
GONE = "runtime:env-gone"
VALID = "repoA::/home/me/proj/keep"      # present in live registry -> KEEP
STALE = "repoA::/home/me/proj/ghost"     # absent from live registry -> PRUNE
NAMED = "repoB::/home/me/proj/log-watcher"  # flagged only via --match
data = {
  "workspaceSessionsByHostId": {
    LIVE: {
      "lastVisitedAtByWorktreeId": {VALID: 1, STALE: 2, NAMED: 3},
      "tabsByWorktree": {VALID: ["t1"], STALE: ["t2"], NAMED: ["t3"]},
      "activeWorktreeIdsOnShutdown": [VALID, STALE],
      "sleepingAgentSessionsByPaneKey": {"pane1": {"worktreeId": STALE}, "pane2": {"worktreeId": VALID}},
      "activeWorktreeId": STALE,
    },
    GONE: {"lastVisitedAtByWorktreeId": {"repoZ::/x": 9}},
  }
}
env_ids = {"env-live"}                 # env-gone NOT present -> orphaned
live_by_env = {"env-live": {VALID}}    # only VALID is live

# Baseline (RED analog): the ghosts exist before repair.
check("baseline: stale recent present", STALE in data["workspaceSessionsByHostId"][LIVE]["lastVisitedAtByWorktreeId"])
check("baseline: orphaned block present", GONE in data["workspaceSessionsByHostId"])

plan = m.plan_repair(data, env_ids, live_by_env, match=("log-watcher",))
check("detect: orphaned block flagged", plan["orphaned_runtimes"] == [GONE])
flagged = set(plan["ghosts_by_runtime"].get(LIVE, []))
check("detect: STALE flagged (not in live registry)", STALE in flagged)
check("detect: NAMED flagged (via --match)", NAMED in flagged)
check("detect: VALID NOT flagged", VALID not in flagged)

counts = m.apply_plan(data, plan)
wsh = data["workspaceSessionsByHostId"]
check("apply: orphaned block dropped", GONE not in wsh)
lv = wsh[LIVE]["lastVisitedAtByWorktreeId"]
check("apply: STALE recent pruned", STALE not in lv)
check("apply: NAMED recent pruned", NAMED not in lv)
check("apply: VALID recent kept", VALID in lv)
check("apply: STALE removed from tabsByWorktree", STALE not in wsh[LIVE]["tabsByWorktree"])
check("apply: VALID kept in tabsByWorktree", VALID in wsh[LIVE]["tabsByWorktree"])
check("apply: STALE removed from shutdown list", STALE not in wsh[LIVE]["activeWorktreeIdsOnShutdown"])
check("apply: VALID kept in shutdown list", VALID in wsh[LIVE]["activeWorktreeIdsOnShutdown"])
check("apply: sleeping session on STALE removed", "pane1" not in wsh[LIVE]["sleepingAgentSessionsByPaneKey"])
check("apply: sleeping session on VALID kept", "pane2" in wsh[LIVE]["sleepingAgentSessionsByPaneKey"])
check("apply: scalar activeWorktreeId nulled", wsh[LIVE]["activeWorktreeId"] is None)

# Idempotence: re-planning finds nothing.
plan2 = m.plan_repair(data, env_ids, live_by_env, match=("log-watcher",))
check("idempotent: nothing left to prune", not plan2["orphaned_runtimes"] and not plan2["ghosts_by_runtime"])

# Guardrail: an unreachable env (absent from live_by_env) must NOT infer stale.
data2 = {"workspaceSessionsByHostId": {LIVE: {"lastVisitedAtByWorktreeId": {STALE: 1}}}}
plan3 = m.plan_repair(data2, {"env-live"}, {}, match=())  # env-live reachable? no -> unverifiable
check("safety: unreachable env infers no stale", not plan3["ghosts_by_runtime"])

# Guidance: a registered env that is unreachable (no live data) but HAS recents is
# "unverifiable" — surfaced so an empty result isn't mistaken for a clean bill.
data4 = {"workspaceSessionsByHostId": {
    LIVE: {"lastVisitedAtByWorktreeId": {STALE: 1}},        # registered, no live data -> unverifiable
    GONE: {"lastVisitedAtByWorktreeId": {"repoZ::/x": 9}},  # env removed -> orphaned, NOT unverifiable
}}
check("guidance: unverifiable lists the registered-but-unreachable runtime",
      m.unverifiable_runtimes(data4, {"env-live"}, {}) == [LIVE])
check("guidance: a reachable env is not unverifiable",
      m.unverifiable_runtimes(data4, {"env-live"}, {"env-live": {STALE}}) == [])
check("guidance: an env with no recents is not unverifiable",
      m.unverifiable_runtimes({"workspaceSessionsByHostId": {LIVE: {}}}, {"env-live"}, {}) == [])

# Liveness classifier: daemon vs desktop UI (the guard's daemon-vs-IDE message).
check("liveness: daemon-entry.js classifies as daemon",
      m._orca_kind("/nix/store/x/orca-ide /nix/store/x/out/main/daemon-entry.js --socket /y") == "daemon")
check("liveness: bare orca-ide classifies as ide",
      m._orca_kind("/nix/store/x/orca-ide --type=renderer") == "ide")
check("liveness: non-orca process classifies as none",
      m._orca_kind("/usr/bin/zsh -c something") is None)

# Write guard: only the IDE UI owns orca-data.json, so ONLY it blocks --apply.
# A daemon-only state is safe to write through (the daemon doesn't own the file;
# it also doesn't serve the live query — that's the UI — so use --match then).
check("guard: IDE UI up blocks --apply", m.apply_should_block((123, "ide")) is True)
check("guard: daemon-only does NOT block --apply", m.apply_should_block((123, "daemon")) is False)
check("guard: nothing running does NOT block --apply", m.apply_should_block(None) is False)

# ── macOS shapes. These are the reason the guard was BROKEN on macOS: no process
# was ever classified, so orca_running() returned None with the UI up and
# apply_should_block() then said it was safe to write orca-data.json under the live
# Electron main process. Real cmdlines, taken from the process table on air.
MAC_MAIN = "/applications/orca.app/contents/macos/orca"
MAC_HELPER = ("/applications/orca.app/contents/frameworks/orca helper.app/contents/"
              "macos/orca helper --type=renderer --user-data-dir=/users/me/library")
check("kind: macOS app bundle main process is the ide", m._orca_kind(MAC_MAIN) == "ide")
check("kind: macOS Electron helper is NOT classified", m._orca_kind(MAC_HELPER) is None)
check("kind: macOS bundle running daemon-entry is the daemon",
      m._orca_kind(MAC_MAIN + " /applications/orca.app/contents/resources/out/main/daemon-entry.js") == "daemon")

# Config dir resolution must prefer whichever candidate actually holds the data
# file — a stray empty ~/.config/orca must not win over the real macOS dir.
import tempfile, pathlib
with tempfile.TemporaryDirectory() as td:
    empty = os.path.join(td, "empty-linux"); real = os.path.join(td, "real-mac")
    os.makedirs(empty)
    pathlib.Path(real, "profiles", "local-default").mkdir(parents=True)
    pathlib.Path(real, "profiles", "local-default", "orca-data.json").write_text("{}")
    saved = m._CONFIG_DIR_CANDIDATES
    try:
        m._CONFIG_DIR_CANDIDATES = (empty, real)
        check("config dir: prefers the candidate holding orca-data.json",
              m.orca_config_dir() == real)
        m._CONFIG_DIR_CANDIDATES = (empty, os.path.join(td, "nope"))
        check("config dir: falls back to an existing dir when none has the file",
              m.orca_config_dir() == empty)
    finally:
        m._CONFIG_DIR_CANDIDATES = saved

# The process table must be readable on this box whichever way it is obtained
# (/proc on Linux, `ps` on macOS) — an empty table means the guard is blind.
check("process table is non-empty", sum(1 for _ in m._proc_cmdlines()) > 5)
check("_pid_alive says our own pid is alive", m._pid_alive(os.getpid()) is True)
check("_pid_alive rejects an impossible pid", m._pid_alive(999999) is False)

print()
if fails:
    print(f"FAILED ({len(fails)}): " + ", ".join(fails)); sys.exit(1)
print("all checks passed")
PY
