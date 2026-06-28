#!/usr/bin/env python3
"""Recompute API spend since the balance anchor and cache the result.

Run detached by the status line when its cache is stale. A lock file prevents
overlapping runs.

Three spend sources, selected in priority order:

1. ADMIN (global, authoritative): if $ANTHROPIC_ADMIN_KEY is set, query the
   org-wide Cost Report (GET /v1/organizations/cost_report). This is the SAME
   number on every device, because the cost comes from Anthropic's side, not
   local logs. Daily-bucketed and lags by hours, and it counts the WHOLE org's
   API usage. Cached to <config>/api-balance.cache.json with "source": "admin".

2. SHARED (multi-device, cloud-synced): else if $CLAUDE_BUDGET_DIR is set, read
   the shared anchor's set_at from <budget>/anchor.json, compute THIS device's
   spend since then with the SAME transcript scan as local mode, and publish it
   atomically to <budget>/spend-<device>.json. The status line sums every
   device's file to show one shared remaining figure. Individual-account users
   (no Admin API) use this to approximate a global balance across machines.

3. LOCAL (per-device estimate): else scan every session transcript under
   <config>/projects and sum the cost of assistant turns at/after the local
   anchor's set_at, caching to <config>/api-balance.cache.json ("source":
   "local"). Cost is an ESTIMATE: transcripts store token usage, not billed
   dollars (costUSD is null), so we price tokens with public per-1M rates plus
   the standard cache multipliers (5m write x1.25, 1h write x2, cache read
   x0.10). A non-null costUSD is trusted instead.
"""
import os
import sys
import json
import time
import glob
import re
import socket
from datetime import datetime, timezone

BASE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
    os.path.expanduser("~"), ".claude"
)
ANCHOR = os.path.join(BASE, "api-balance.json")
CACHE = os.path.join(BASE, "api-balance.cache.json")
LOCK = os.path.join(BASE, "api-balance.lock")
PROJECTS = os.path.join(BASE, "projects")

# Cloud-synced shared-ledger folder (OneDrive/Dropbox/Drive). Same path on every
# device points at the same synced folder; each device publishes its own spend.
BUDGET_DIR = os.environ.get("CLAUDE_BUDGET_DIR")

# per 1M tokens: (input, output)
RATES = {
    "opus": (5.0, 25.0),
    "sonnet": (3.0, 15.0),
    "haiku": (1.0, 5.0),
    "fable": (10.0, 50.0),
}


def rate(model):
    m = (model or "").lower()
    for k, v in RATES.items():
        if k in m:
            return v
    return RATES["opus"]


def iso_epoch(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def device_id():
    """Stable per-device id, sanitized to [A-Za-z0-9_-]."""
    name = os.environ.get("COMPUTERNAME") or socket.gethostname() or "device"
    name = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    return name or "device"


def atomic_write(path, obj):
    """Write JSON via tmp + rename so readers never see a half-written file."""
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)
    os.replace(tmp, path)


def fetch_admin_spent(set_at):
    """Org-wide cost since the anchor day, in USD, via the Admin Cost Report.

    Returns dollars (float) on success, or None if no admin key is configured.
    Raises on network/HTTP/parse errors so the caller can fall back to local.
    """
    key = os.environ.get("ANTHROPIC_ADMIN_KEY")
    if not key:
        return None

    import urllib.request
    import urllib.parse

    # Cost Report buckets are whole UTC days, so start at the anchor day's
    # midnight. This counts a little spend from before set_at on the anchor day
    # (conservative: shows slightly less remaining) — acceptable for a daily,
    # already-lagging figure.
    start = datetime.fromtimestamp(set_at, tz=timezone.utc).strftime(
        "%Y-%m-%dT00:00:00Z"
    )
    url = "https://api.anthropic.com/v1/organizations/cost_report"
    total_cents = 0.0
    page = None
    for _ in range(100):  # pagination safety bound
        params = {"starting_at": start, "bucket_width": "1d", "limit": "31"}
        if page:
            params["page"] = page
        req = urllib.request.Request(
            url + "?" + urllib.parse.urlencode(params),
            headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.load(resp)
        for bucket in payload.get("data", []):
            for item in bucket.get("results", []):
                try:
                    # amount is a decimal string in CENTS ("123.45" => $1.23)
                    total_cents += float(item.get("amount"))
                except (TypeError, ValueError):
                    pass
        if payload.get("has_more") and payload.get("next_page"):
            page = payload["next_page"]
        else:
            break
    return total_cents / 100.0


def local_spent(set_at):
    """Per-device spend estimate from session transcripts since set_at (USD)."""
    spent = 0.0
    for fp in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(fp) < set_at:
                continue  # whole file predates the anchor
        except OSError:
            continue
        try:
            fh = open(fp, encoding="utf-8", errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                ts = iso_epoch(o.get("timestamp") or "")
                if ts is None or ts < set_at:
                    continue
                cusd = o.get("costUSD")
                if isinstance(cusd, (int, float)):
                    spent += float(cusd)
                    continue
                msg = o.get("message")
                u = msg.get("usage") if isinstance(msg, dict) else None
                if not isinstance(u, dict):
                    continue
                ir, orate = rate(msg.get("model"))
                inp = u.get("input_tokens") or 0
                out = u.get("output_tokens") or 0
                cr = u.get("cache_read_input_tokens") or 0
                cc = u.get("cache_creation") or {}
                c5 = cc.get("ephemeral_5m_input_tokens")
                c1 = cc.get("ephemeral_1h_input_tokens")
                if c5 is None and c1 is None:
                    c5 = u.get("cache_creation_input_tokens") or 0
                    c1 = 0
                else:
                    c5 = c5 or 0
                    c1 = c1 or 0
                spent += (
                    inp * ir
                    + c5 * ir * 1.25
                    + c1 * ir * 2.0
                    + cr * ir * 0.10
                    + out * orate
                ) / 1e6
    return spent


def shared_refresh():
    """Publish THIS device's spend since the shared anchor to the budget dir."""
    anchor_path = os.path.join(BUDGET_DIR, "anchor.json")
    try:
        a = json.load(open(anchor_path, encoding="utf-8"))
        set_at = float(a.get("set_at", 0))
    except Exception:
        return  # no shared anchor yet — nothing to compute against
    spent = local_spent(set_at)
    dev = device_id()
    try:
        atomic_write(
            os.path.join(BUDGET_DIR, f"spend-{dev}.json"),
            {
                "device": dev,
                "set_at": set_at,
                "spent": spent,
                "computed_at": time.time(),
            },
        )
    except OSError:
        pass


def anchor_refresh():
    """Admin/local single-device mode: cache spend against the local anchor."""
    try:
        anchor = json.load(open(ANCHOR, encoding="utf-8"))
        set_at = float(anchor.get("set_at", 0))
    except Exception:
        return

    spent = 0.0
    source = "local"
    admin = None
    try:
        admin = fetch_admin_spent(set_at)
    except Exception:
        admin = None  # network/HTTP/parse error → fall back to local
    if admin is not None:
        spent = admin
        source = "admin"
    else:
        spent = local_spent(set_at)
    try:
        atomic_write(
            CACHE,
            {
                "set_at": set_at,
                "computed_at": time.time(),
                "spent": spent,
                "source": source,
            },
        )
    except OSError:
        pass


def main():
    now = time.time()
    # bail if another refresh started recently (stale lock auto-expires)
    try:
        if now - os.path.getmtime(LOCK) < 120:
            return
    except OSError:
        pass
    try:
        with open(LOCK, "w") as fh:
            fh.write(str(now))
    except OSError:
        pass

    try:
        # Admin key wins (authoritative org-wide figure). Otherwise, if a shared
        # budget dir is configured, publish this device's spend there; else fall
        # back to the single-device local anchor.
        if BUDGET_DIR and not os.environ.get("ANTHROPIC_ADMIN_KEY"):
            shared_refresh()
        else:
            anchor_refresh()
    finally:
        try:
            os.remove(LOCK)
        except OSError:
            pass


if __name__ == "__main__":
    main()
