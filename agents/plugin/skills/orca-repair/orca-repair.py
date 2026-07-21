#!/usr/bin/env python3
"""
orca-repair — prune ghost / stale workspace entries from Orca's local state.

Orca renders a per-environment "recent workspaces" list from cached view-state
in orca-data.json (workspaceSessionsByHostId). When a worktree is deleted, or an
environment is removed, its cache lingers and renders as a stale workspace that
the UI CANNOT remove — right-click Remove maps to a worktree removal by selector
and fails with `selector_not_found` because there is no worktree behind it.

This tool finds those ghosts and prunes them safely.

Two ghost classes, both detected automatically:
  * ORPHANED runtime block — a runtime:<envid> block whose environment is no
    longer in Orca's environment list (e.g. after `orca environment rm`).
    The whole block is dead; drop it.
  * STALE recent — a worktree id in a live environment's cache that the
    environment's live registry (`orca worktree list --environment`) no longer
    reports. Prune just that worktree id from the block.

Safety:
  * Refuses to WRITE while the Orca IDE is running (edits get clobbered on its
    next save). Detection is by orca-runtime.json + the orca-ide process — NOT
    $TERM_PROGRAM, which can read "Orca" even in a plain terminal launched from
    Orca. Scans are always safe with Orca open.
  * Timestamped backup before any write.
  * Default is a dry-run scan; --apply writes.

Usage:
  python3 orca-repair.py                 # scan (read-only; safe with Orca open)
  python3 orca-repair.py --offline       # scan without querying remotes
  python3 orca-repair.py --match log-watcher   # also target ids matching a substr
  # then FULLY QUIT the Orca IDE and, from a NON-Orca terminal:
  python3 orca-repair.py --apply         # prune (writes; backs up first)
"""
import argparse, glob, json, os, shutil, subprocess, sys, time

DEFAULT_DATA = os.path.expanduser("~/.config/orca/profiles/local-default/orca-data.json")
ENV_FILE = os.path.expanduser("~/.config/orca/orca-environments.json")
RUNTIME_FILE = os.path.expanduser("~/.config/orca/orca-runtime.json")


# ── Orca-IDE liveness (the gotcha: do NOT trust $TERM_PROGRAM) ────────────────
def _orca_kind(cmd):
    """Classify an Orca process by its (lowercased) cmdline.

    'daemon' — the headless background daemon (daemon-entry.js) that outlives the
               window; 'ide' — the desktop UI. None if not an Orca process at all.
    """
    if "orca-ide" not in cmd and "squashfs-root/orca" not in cmd:
        return None
    return "daemon" if "daemon-entry" in cmd else "ide"


def orca_running():
    """Return (pid, kind) for a live Orca process if one is up, else None.

    kind is 'ide' (the desktop UI — its presence is also signalled by
    orca-runtime.json) or 'daemon' (the headless daemon-entry.js). The UI wins
    when both are up. BOTH own orca-data.json, so --apply must not write while
    either runs — but the caller distinguishes them, because a lingering daemon
    with the window already gone is the common, confusing case.

    Liveness is by orca-runtime.json + /proc — NOT $TERM_PROGRAM, which can read
    'Orca' in a plain terminal launched from an Orca session.
    """
    self_pid = os.getpid()
    daemon = None  # remember a daemon but keep looking for the UI, which wins
    try:
        rt = json.load(open(RUNTIME_FILE))
        pid = rt.get("pid")
        if pid and os.path.exists(f"/proc/{pid}"):
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", "replace").lower()
            kind = _orca_kind(cmd)
            if kind == "ide":
                return (pid, "ide")
            if kind == "daemon":
                daemon = (pid, "daemon")
    except Exception:
        pass
    for p in glob.glob("/proc/[0-9]*/cmdline"):
        pid = int(p.split("/")[2])
        if pid == self_pid:
            continue
        try:
            cmd = open(p, "rb").read().decode("utf-8", "replace").lower()
        except OSError:
            continue
        if "orca-repair" in cmd:  # never match this script
            continue
        kind = _orca_kind(cmd)
        if kind == "ide":
            return (pid, "ide")
        if kind == "daemon" and daemon is None:
            daemon = (pid, "daemon")
    return daemon


def apply_should_block(info):
    """Given orca_running()'s result, is it unsafe to WRITE orca-data.json?

    Only the IDE UI (the Electron main process) owns orca-data.json — verified by
    inspecting the app bundle: the view-state store (`workspaceSessionsByHostId`)
    is written solely by out/main/index.js, while the headless daemon
    (daemon-entry.js) is a PTY/terminal host that never touches it. So a
    daemon-only state is SAFE to write through — block only on the UI, not on a
    harmless lingering daemon. (Note: the daemon does NOT serve the live worktree
    query either — that also lives in the UI process — so a lingering daemon does
    not help detection; it just isn't a reason to refuse the write.)
    """
    return bool(info) and info[1] == "ide"


# ── Pure logic (unit-tested; no I/O) ──────────────────────────────────────────
def env_id_of(runtime_key):
    """'runtime:<envid>' -> '<envid>'."""
    return runtime_key.split("runtime:", 1)[-1]


def recent_ids(block):
    """The worktree ids a runtime block renders as recents."""
    return set((block.get("lastVisitedAtByWorktreeId") or {}).keys())


def plan_repair(data, env_ids, live_by_env, match=()):
    """Compute what to prune. Pure: no I/O, no live queries.

    env_ids: set of environment ids currently registered.
    live_by_env: {env_id: set(worktree_id)} for REACHABLE envs. An env id absent
                 from this dict is treated as unverifiable (stale not inferred).
    match: substrings; any recent id containing one is flagged regardless.
    """
    wsh = data.get("workspaceSessionsByHostId", {})
    orphaned, ghosts = [], {}
    for rt, block in wsh.items():
        eid = env_id_of(rt)
        if eid not in env_ids:
            orphaned.append(rt)
            continue
        flagged = set()
        rids = recent_ids(block)
        if eid in live_by_env:
            flagged |= {wt for wt in rids if wt not in live_by_env[eid]}
        if match:
            flagged |= {wt for wt in rids if any(m in wt for m in match)}
        if flagged:
            ghosts[rt] = sorted(flagged)
    return {"orphaned_runtimes": orphaned, "ghosts_by_runtime": ghosts}


def unverifiable_runtimes(data, env_ids, live_by_env):
    """Runtimes whose env IS registered (so the block is NOT orphaned) and has
    recents, but whose env was not reachable for a live query — so stale recents
    could not be checked. Pure: used only to WARN, never to prune. Without this,
    an empty result while the live registry is down reads as a false "all clean".
    """
    out = []
    wsh = data.get("workspaceSessionsByHostId", {})
    for rt, block in wsh.items():
        eid = env_id_of(rt)
        if eid in env_ids and eid not in live_by_env and recent_ids(block):
            out.append(rt)
    return out


def _scrub_ids(block, wtids):
    """Remove exact worktree-id references from one runtime block. Returns count."""
    removed = 0
    for sub, val in list(block.items()):
        if isinstance(val, dict):
            for k in list(val.keys()):
                v = val[k]
                if k in wtids or (isinstance(v, dict) and v.get("worktreeId") in wtids):
                    del val[k]; removed += 1
                elif isinstance(v, list):
                    kept = [x for x in v if not (isinstance(x, dict) and x.get("worktreeId") in wtids)]
                    if len(kept) != len(v):
                        val[k] = kept; removed += len(v) - len(kept)
        elif isinstance(val, list):
            kept = [x for x in val if not (isinstance(x, str) and x in wtids)]
            if len(kept) != len(val):
                block[sub] = kept; removed += len(val) - len(kept)
        elif isinstance(val, str) and val in wtids:
            block[sub] = None; removed += 1
    return removed


def apply_plan(data, plan):
    """Mutate data per plan. Returns {'blocks_dropped': n, 'ids_pruned': n}."""
    wsh = data.get("workspaceSessionsByHostId", {})
    dropped = 0
    for rt in plan["orphaned_runtimes"]:
        if rt in wsh:
            del wsh[rt]; dropped += 1
    pruned = 0
    for rt, ids in plan["ghosts_by_runtime"].items():
        if rt in wsh:
            pruned += _scrub_ids(wsh[rt], set(ids))
    return {"blocks_dropped": dropped, "ids_pruned": pruned}


# ── I/O (best-effort; degrades gracefully) ────────────────────────────────────
def gather_env_ids():
    try:
        e = json.load(open(ENV_FILE))
        return {x["id"] for x in e.get("environments", [])}
    except Exception:
        return set()


def gather_live_by_env(env_ids, orca_bin):
    live = {}
    for eid in env_ids:
        try:
            out = subprocess.run([orca_bin, "worktree", "list", "--environment", eid],
                                 capture_output=True, text=True, timeout=30)
            if out.returncode != 0:
                continue
            ids = {ln.split()[0] for ln in out.stdout.splitlines()
                   if "::" in ln.split(" ")[0]}
            live[eid] = ids
        except Exception:
            continue
    return live


def find_orca_bin():
    for c in (os.path.expanduser("~/.config/orca/linux-orca-cli-shim/orca"),
              shutil_which("orca")):
        if c and os.path.exists(c):
            return c
    return None


def shutil_which(name):
    return shutil.which(name)


def main():
    ap = argparse.ArgumentParser(description="Prune ghost Orca workspace entries.")
    ap.add_argument("--data", default=DEFAULT_DATA)
    ap.add_argument("--apply", action="store_true", help="write changes (requires Orca closed)")
    ap.add_argument("--offline", action="store_true", help="don't query remote registries")
    ap.add_argument("--match", action="append", default=[], help="also flag recents containing this substring")
    args = ap.parse_args()

    if not os.path.exists(args.data):
        print(f"✗ not found: {args.data}"); sys.exit(1)

    info = orca_running()
    if args.apply and apply_should_block(info):
        print(f"✗ Orca IDE is running (pid {info[0]}). Fully quit it (app Quit, not\n"
              f"  kill-a-child — Electron respawns children), then re-run --apply from a\n"
              f"  non-Orca terminal. (Scan without --apply is safe while it's open.)")
        sys.exit(1)
    if args.apply and info and info[1] == "daemon":
        # Daemon-only: the UI (sole writer of orca-data.json) is down, so writing
        # is safe — a lingering PTY/terminal daemon is NOT a reason to refuse.
        # It does not serve the live worktree query (that needs the UI), so with
        # the UI down stale recents can't be checked live — use --match for those.
        print(f"ℹ IDE UI is down; only Orca's background terminal daemon (pid {info[0]}) is\n"
              f"  up. It doesn't own orca-data.json, so it's safe to write past — not a\n"
              f"  blocker. (It does NOT serve the live stale-recent query — that needs the\n"
              f"  UI — so with the UI down, prune a known ghost id with --match.)\n")

    data = json.load(open(args.data))
    env_ids = gather_env_ids()
    live = {}
    if not args.offline:
        orca_bin = find_orca_bin()
        if orca_bin:
            live = gather_live_by_env(env_ids, orca_bin)
        else:
            print("! orca CLI not found — scanning offline (orphaned blocks + --match only)\n")

    plan = plan_repair(data, env_ids, live, match=tuple(args.match))
    # --match deliberately bypasses the live query, so don't nag about it then.
    unverifiable = [] if args.match else unverifiable_runtimes(data, env_ids, live)
    print("Ghost scan:")
    if plan["orphaned_runtimes"]:
        for rt in plan["orphaned_runtimes"]:
            print(f"  • orphaned runtime block (env removed): {rt}")
    for rt, ids in plan["ghosts_by_runtime"].items():
        for i in ids:
            print(f"  • stale recent in {rt}:\n      {i}")

    nothing = not plan["orphaned_runtimes"] and not plan["ghosts_by_runtime"]
    if nothing:
        print("  (nothing to prune)")

    # Live registry unreachable => stale recents could NOT be checked. Say so
    # loudly — otherwise an empty result reads as a false "all clean".
    if unverifiable:
        why = "--offline was passed" if args.offline else "the live registry was unreachable (Orca's UI not running?)"
        print(f"\n! stale-recent detection was SKIPPED for {len(unverifiable)} live environment(s): {why}.")
        print("  Orphaned-block detection is unaffected, but ghost recents can't be confirmed this way.")
        print("  Either re-scan with Orca's UI OPEN (only the running UI answers the live query),")
        print("  or, if you already know the ghost id, target it directly (no live query needed):")
        print("      --match <worktree-id-substring>")

    if nothing:
        return

    if not args.apply:
        print("\n(dry-run) nothing written. Re-run with --apply after quitting Orca.")
        return

    backup = f"{args.data}.bak.orca-repair.{int(time.time())}"
    shutil.copy2(args.data, backup)
    counts = apply_plan(data, plan)
    tmp = args.data + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, args.data)
    print(f"\n✓ dropped {counts['blocks_dropped']} block(s), pruned {counts['ids_pruned']} entry(ies).")
    print(f"  backup: {backup}\n  reopen Orca — the stale workspaces should be gone.")


if __name__ == "__main__":
    main()
