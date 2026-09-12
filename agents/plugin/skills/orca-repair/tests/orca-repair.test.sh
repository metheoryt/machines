#!/usr/bin/env bash
# Unit test for orca-repair's pure detection/prune logic. No Orca, no network.
# Run: bash orca-repair.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$HERE/.." <<'PY'
import importlib.util, json, sys, os
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

# Real recents are keyed `runtime:<envId>|<repoId>::<path>`; the live registry
# prints the bare `<repoId>::<path>`. The fixture above uses bare ids on both
# sides and so never exercised the mismatch — on desktop-wsl 2026-09-12 every one
# of a reachable environment's recents was flagged stale while every one was live.
PFX = "runtime:env-live|"
data5 = {"workspaceSessionsByHostId": {LIVE: {
    "lastVisitedAtByWorktreeId": {PFX + VALID: 1, PFX + STALE: 2}}}}
plan5 = m.plan_repair(data5, {"env-live"}, {"env-live": {VALID}}, match=())
check("prefix: registry_id strips the runtime:<env>| prefix", m.registry_id(PFX + VALID) == VALID)
check("prefix: a bare id is left alone", m.registry_id(VALID) == VALID)
check("prefix: prefixed LIVE recent is NOT flagged",
      PFX + VALID not in set(plan5["ghosts_by_runtime"].get(LIVE, [])))
check("prefix: prefixed STALE recent IS flagged",
      set(plan5["ghosts_by_runtime"].get(LIVE, [])) == {PFX + STALE})

# --data selects a STORE. This is the 2026-09-12 desktop-wsl bug: --data moved the
# data path while ENV_FILE/RUNTIME_FILE stayed on a retired second store whose
# orca-environments.json did not exist, so gather_env_ids() returned {} and every
# LIVE environment was reported as an orphaned block — one --apply from deleting
# two working environments' state. A guard that reported success while doing the
# wrong thing gets pinned.
with tempfile.TemporaryDirectory() as td:
    stale = os.path.join(td, "stale-store"); real = os.path.join(td, "real-store")
    for d in (stale, real):
        pathlib.Path(d, "profiles", "local-default").mkdir(parents=True)
        pathlib.Path(d, "profiles", "local-default", "orca-data.json").write_text("{}")
    pathlib.Path(real, "orca-environments.json").write_text(
        json.dumps({"environments": [{"id": "env-live"}]}))
    real_data = os.path.join(real, "profiles", "local-default", "orca-data.json")
    check("config dir: --data's store is derived from the data path",
          m.config_dir_for_data(real_data) == real)
    saved_cfg, saved_env, saved_rt = m.CONFIG_DIR, m.ENV_FILE, m.RUNTIME_FILE
    try:
        m.set_config_dir(stale)
        m.set_config_dir(m.config_dir_for_data(real_data))
        check("config dir: set_config_dir moves ENV_FILE with it",
              m.ENV_FILE == os.path.join(real, "orca-environments.json"))
        check("config dir: set_config_dir moves RUNTIME_FILE with it",
              m.RUNTIME_FILE == os.path.join(real, "orca-runtime.json"))
        check("config dir: env ids come from the selected store, not the other one",
              m.gather_env_ids() == {"env-live"})
        # The failure itself: the stale store's (absent) registry orphans a live env.
        m.set_config_dir(stale)
        check("regression: wrong store reports a LIVE env as orphaned",
              m.plan_repair({"workspaceSessionsByHostId": {"runtime:env-live": {
                  "lastVisitedAtByWorktreeId": {"repoA::/x": 1}}}},
                  m.gather_env_ids(), {}, match=())["orphaned_runtimes"] == ["runtime:env-live"])
    finally:
        m.CONFIG_DIR, m.ENV_FILE, m.RUNTIME_FILE = saved_cfg, saved_env, saved_rt

# A cross-OS store (Windows profile reached from WSL over /mnt/c) carries a pid
# this box's /proc cannot judge — and a coincidental match would "confirm" it
# either way. Liveness there is the runtime file's existence, failing CLOSED.
if os.path.isdir("/proc"):
    check("foreign: a /mnt/<drive> store is foreign",
          m.store_is_foreign("/mnt/c/Users/x/AppData/Roaming/orca") is True)
    check("foreign: a native store is not foreign",
          m.store_is_foreign(os.path.expanduser("~/.config/orca")) is False)
    with tempfile.TemporaryDirectory() as td:
        saved_cfg, saved_env, saved_rt = m.CONFIG_DIR, m.ENV_FILE, m.RUNTIME_FILE
        saved_foreign = m.store_is_foreign
        try:
            m.set_config_dir(td)
            m.store_is_foreign = lambda config_dir=None: True
            check("foreign: no runtime file => not running", m.orca_running() is None)
            pathlib.Path(td, "orca-runtime.json").write_text(json.dumps({"pid": 999999}))
            check("foreign: runtime file present => treated as the live UI (fails closed)",
                  m.orca_running() == (999999, "ide"))
            check("foreign: and that blocks --apply", m.apply_should_block(m.orca_running()) is True)
        finally:
            m.store_is_foreign = saved_foreign
            m.CONFIG_DIR, m.ENV_FILE, m.RUNTIME_FILE = saved_cfg, saved_env, saved_rt

# The CLI is orca-ide / orca-cli, NEVER the bare name: `orca` is also the GNOME
# screen reader. Put a bare `orca` on PATH beside a working one and assert it is
# never chosen — same assertion provision/tests/orca-skills-tier.test.sh makes.
with tempfile.TemporaryDirectory() as td:
    for n in ("orca", "orca-ide"):
        f = pathlib.Path(td, n); f.write_text("#!/bin/sh\nexit 0\n"); f.chmod(0o755)
    saved_path, saved_cfg = os.environ["PATH"], m.CONFIG_DIR
    try:
        os.environ["PATH"] = td
        m.CONFIG_DIR = td  # a shim named `orca` sits here too — still must lose
        pathlib.Path(td, "linux-orca-cli-shim").mkdir()
        shim = pathlib.Path(td, "linux-orca-cli-shim", "orca")
        shim.write_text("#!/bin/sh\nexit 0\n"); shim.chmod(0o755)
        picked = m.find_orca_bin()
        check("cli: picks orca-ide", os.path.basename(picked) == "orca-ide")
        check("cli: never the bare `orca` on PATH", picked != os.path.join(td, "orca"))
    finally:
        os.environ["PATH"] = saved_path; m.CONFIG_DIR = saved_cfg

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
