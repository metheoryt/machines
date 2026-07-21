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
def orca_running():
    """Return a live Orca IDE pid if the desktop app is up, else None."""
    self_pid = os.getpid()
    try:
        rt = json.load(open(RUNTIME_FILE))
        pid = rt.get("pid")
        if pid and os.path.exists(f"/proc/{pid}"):
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", "replace").lower()
            if "orca-ide" in cmd or "squashfs-root/orca" in cmd:
                return pid
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
        if "orca-ide" in cmd or "squashfs-root/orca" in cmd:
            return pid
    return None


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

    pid = orca_running()
    if args.apply and pid:
        print(f"✗ Orca IDE is running (pid {pid}). Fully quit it, then re-run --apply\n"
              f"  from a non-Orca terminal. (Scan without --apply is safe while it's open.)")
        sys.exit(1)

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
    print("Ghost scan:")
    if plan["orphaned_runtimes"]:
        for rt in plan["orphaned_runtimes"]:
            print(f"  • orphaned runtime block (env removed): {rt}")
    for rt, ids in plan["ghosts_by_runtime"].items():
        for i in ids:
            print(f"  • stale recent in {rt}:\n      {i}")
    if not plan["orphaned_runtimes"] and not plan["ghosts_by_runtime"]:
        print("  (nothing to prune)")
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
