---
name: update-balance
description: Use when the user wants to update, set, re-anchor, top-up, or correct the Anthropic API credit balance shown in the status line (🏦) — e.g. after buying credits, or when remaining/spent looks wrong or has gone negative.
---

# Update API Balance

## Overview

The status line tracks pay-as-you-go API spend against an **anchor**: a balance
recorded at a point in time. It shows `🏦 = anchor balance − spend since the
anchor's timestamp`. Spend accumulates, so the anchor drifts (remaining can
overrun to negative); re-anchor it to your current real balance to reset the
baseline.

There is **no synchronous balance API** to read this automatically — the number
must come from you. Get it from the Console: https://console.anthropic.com →
Plans & Billing / Credits.

The anchor location depends on how the status line is configured:

- **Single device** (default): anchor lives in `~/.claude/api-balance.json`.
- **Shared / multi-device**: if `$CLAUDE_BUDGET_DIR` is set, the anchor lives in
  `<budget>/anchor.json` in a cloud-synced folder, and re-anchoring also clears
  every device's `spend-*.json` so they all recompute against the new anchor.
  The 🔗 marker in the status line means the shared figure is in use.

The worker handles both automatically based on `$CLAUDE_BUDGET_DIR`.

## Steps

1. Get the current remaining credit in USD (ask the user, or point them at the
   Console link above). Pass the **remaining balance**, not spend.
2. Run the worker with that dollar amount, resolving a working interpreter
   (`python3` on macOS/Linux; on Windows `python3` is often a broken Store stub,
   so fall through to `python`):
   ```bash
   PY="$( for c in python3 python; do command -v "$c" >/dev/null 2>&1 && "$c" -c '' >/dev/null 2>&1 && { echo "$c"; break; }; done )"
   "$PY" ~/.claude/skills/update-balance/update-balance.py <dollars>
   ```
   Accepts `$`, commas, decimals (e.g. `50`, `$1,234.50`). Honors
   `$CLAUDE_CONFIG_DIR` and `$CLAUDE_BUDGET_DIR` if set.
3. Report the anchored value back. The next status-line render shows
   `🏦$<balance>` and recomputes `↘<spent>` from zero against the new anchor.

## What it does

- **Single device:** writes `api-balance.json` = `{"balance": <dollars>,
  "set_at": <now>}`, then deletes `api-balance.cache.json` and
  `api-balance.lock` so spend-since-anchor recomputes on the next refresh.
- **Shared (`$CLAUDE_BUDGET_DIR` set):** writes `<budget>/anchor.json` =
  `{"balance": <dollars>, "set_at": <now>}` (atomic), then deletes every
  `<budget>/spend-*.json` so all devices recompute against the new anchor.

## Common mistakes

- **Passing spend instead of remaining** — pass your current *remaining credit*.
- **Expecting auto-fetch** — there is no balance API; the number must be supplied.
- **Running `python3` blindly on Windows** — it may be the Microsoft Store stub
  that prints "Python was not found"; use the resolver in step 2.
