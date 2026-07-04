#!/usr/bin/env python3
"""Re-anchor the API credit balance the status line tracks spend against.

Usage: python3 update-balance.py <dollars>

Default (single device): writes <config>/api-balance.json =
{"balance": <dollars>, "set_at": <now>} and clears the local spend cache + lock
so spend-since-anchor recomputes from this new anchor. Honors $CLAUDE_CONFIG_DIR.

Shared (multi-device): if $CLAUDE_BUDGET_DIR is set, write the anchor to
<budget>/anchor.json instead and delete every <budget>/spend-*.json so each
device recomputes its spend against the new anchor. The status line sums those
per-device files into one shared remaining figure.
"""
import os
import sys
import glob
import json
import time


def atomic_write(path, obj):
    """Write JSON via tmp + rename so cloud-sync never uploads a partial file."""
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 2:
        print("usage: update-balance.py <dollars>", file=sys.stderr)
        return 1
    raw = sys.argv[1].strip().lstrip("$").replace(",", "")
    try:
        bal = float(raw)
    except ValueError:
        print(f"not a number: {sys.argv[1]!r}", file=sys.stderr)
        return 1

    now = time.time()
    budget = os.environ.get("CLAUDE_BUDGET_DIR")

    if budget:
        # Shared mode: anchor + per-device spend live in the cloud-synced folder.
        try:
            atomic_write(
                os.path.join(budget, "anchor.json"),
                {"balance": bal, "set_at": now},
            )
        except OSError as e:
            print(f"could not write shared anchor: {e}", file=sys.stderr)
            return 1
        # Drop every device's spend file so they recompute against this anchor.
        removed = 0
        for fp in glob.glob(os.path.join(budget, "spend-*.json")):
            try:
                os.remove(fp)
                removed += 1
            except OSError:
                pass
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        print(
            f"shared anchor = ${bal:.2f} at {stamp} "
            f"(cleared {removed} device spend file(s) in {budget})"
        )
        return 0

    # Single-device mode (unchanged behavior).
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    try:
        atomic_write(
            os.path.join(base, "api-balance.json"),
            {"balance": bal, "set_at": now},
        )
    except OSError as e:
        print(f"could not write anchor: {e}", file=sys.stderr)
        return 1

    # Drop stale spend cache + lock so spend recomputes against the new anchor.
    for name in ("api-balance.cache.json", "api-balance.lock"):
        try:
            os.remove(os.path.join(base, name))
        except OSError:
            pass

    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    print(f"anchored balance = ${bal:.2f} at {stamp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
