#!/usr/bin/env python3
"""List every compaction boundary in the local Claude transcript archive.

The measurement tool for the compact-note experiment (agents/plugin/hooks/
compact-note-{save,restore}.sh). Run it before the hooks are live to freeze a
baseline, and again afterwards: the `carried` column says which side of the
experiment each boundary sits on, so one corpus holds both.

It reports no quality score on purpose. A quantitative metric was tried and
abandoned — counting files re-read after a boundary measures the harness, not
the phenomenon, because this fleet's sessions read through `cat`/`sed` under
bypass-permissions and file_path inputs barely exist. With ~51 historical
boundaries and a handful of new ones per month, no number reaches significance
anyway. So this prints the raw material for a human read: what the session was
doing, and the turns that immediately followed the summary.

  scripts/compact-boundaries.py                  # one row per boundary
  scripts/compact-boundaries.py --after 8 -v     # rows + the turns after each
"""
import argparse, json, pathlib, sys

ROOT = pathlib.Path.home() / ".claude" / "projects"


def turns_after(rows, i, n):
    """The first n user/assistant text turns following a boundary row."""
    out = []
    for r in rows[i + 1:]:
        if len(out) >= n:
            break
        if r.get("isMeta") or r.get("isCompactSummary"):
            continue
        if r.get("type") not in ("user", "assistant"):
            continue
        c = (r.get("message") or {}).get("content")
        if isinstance(c, list):
            c = "\n".join(p.get("text", "") for p in c
                          if isinstance(p, dict) and p.get("type") == "text")
        if not isinstance(c, str) or not c.strip() or c.lstrip().startswith("<"):
            continue
        out.append((r["type"], " ".join(c.split())[:400]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--after", type=int, default=0,
                    help="print this many turns following each boundary")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args()

    found = []
    for p in sorted(pathlib.Path(a.root).glob("*/*.jsonl")):
        try:
            rows = [json.loads(l) for l in p.open(errors="ignore") if l.strip()]
        except Exception:
            continue
        meta = {}
        for r in rows:
            if r.get("compactMetadata"):
                meta[r.get("uuid") or len(meta)] = r["compactMetadata"]
        metas = [r["compactMetadata"] for r in rows if r.get("compactMetadata")]
        k = 0
        for i, r in enumerate(rows):
            if not r.get("isCompactSummary"):
                continue
            m = metas[k] if k < len(metas) else {}
            k += 1
            # A boundary is "carried" when the note the restore hook injects is
            # present in the turns just after it. That marker is the experiment's
            # only reliable group label: a timestamp cutoff would mislabel any
            # session that started before the hooks landed and compacted after.
            window = json.dumps(rows[i:i + 6], ensure_ascii=False)
            found.append(dict(
                file=str(p), project=p.parent.name, i=i,
                when=r.get("timestamp", "?")[:19],
                trigger=m.get("trigger", "?"),
                pre=m.get("preTokens"), post=m.get("postTokens"),
                carried="Carried across the compaction" in window,
                after=turns_after(rows, i, a.after) if a.after else [],
            ))

    found.sort(key=lambda d: d["when"])
    print(f"{'when':20}{'trigger':9}{'carried':9}{'pre':>8}{'post':>8}  project")
    for d in found:
        print(f"{d['when']:20}{d['trigger']:9}{str(d['carried']):9}"
              f"{d['pre'] or 0:8}{d['post'] or 0:8}  {d['project']}")
    n = len(found)
    c = sum(1 for d in found if d["carried"])
    auto = sum(1 for d in found if d["trigger"] == "auto")
    print(f"\n{n} boundaries — {c} with a carried note, {n - c} without; "
          f"{auto} auto, {n - auto} manual")

    if a.verbose and a.after:
        for d in found:
            print(f"\n--- {d['when']} {d['project']} "
                  f"(carried={d['carried']}, {d['pre']}->{d['post']})")
            for kind, text in d["after"]:
                print(f"  [{kind}] {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
