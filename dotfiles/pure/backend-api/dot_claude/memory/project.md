# Project memory: backend-api (Pure API)

<!--
Auto-loaded by the project-memory-check.sh SessionStart hook from
<repo>/.claude/memory/project.md.

NOT tracked in backend-api — its .gitignore is allowlist-style (`*` plus
`!/.claude/*.md`), so this path is ignored there and a file written here would
be machine-local. It is instead tracked in the `machines` repo under
`dotfiles/pure/backend-api/dot_claude/memory/project.md` and materialised by
chezmoi (`chezmoi apply --source machines/dotfiles`, run by the `dotfiles`
provision role). Edit it THERE, not here — `chezmoi apply` overwrites this copy.

Caveat: the dotfiles role skips NixOS (home-manager owns that box), so this
file does not currently reach latitude.

One bullet per fact under a topical heading. Curate — edit or delete stale
entries rather than letting them pile up. No secrets.
-->

## Purchase crediting — two choke points

- **Any feature reacting to "a purchase was credited" (events, analytics,
  notifications) hooks two shared choke points — per-provider instrumentation is
  not needed.**
  - *Consumables:* every provider converges on `add_items_from_bundle`
    (`inapp/logic/consumable.py:85`) — Stripe `stripe/hook.py::handle_consumable_payment`,
    CardPay `cardpay/postback.py::process_consumable`, OurBilling
    `our_billing/common.py:364 add_consumable_purchase`. **Bypass:**
    `apple_appstore.py::add_welcome_inapp` calls `add_item` directly.
  - *Subscriptions:* every provider writes Renewal/Purchase then calls
    `calculate_membership` (`inapp/logic/membership.py:300`) to recompute
    entitlement — OurBilling `_handle_subscription_success`
    (`our_billing/common.py:296`), Stripe `stripe/hook.py:165`, CardPay
    `cardpay/postback.py:384`, PayPal `paypal/webhook_event_handlers.py:118`,
    Google/Huawei `android.py::check_receipt:367`, plus refund/chargeback
    (`android.py:519`, `apple_appstore.py:370`, `chargeback.py:104`,
    `postback.py:113`).
  - *Admin/promo/manual grants bypass BOTH:* `AppUserAdmin.add_item` /
    `add_membership`, `add_custom_membership`.
  - **Caveat:** `calculate_membership` is a recompute also called on non-credit
    paths (read-repair, cancellation) — gate on `is_process_subscription` or the
    caller's reason if you only want actual credit events. Correlation like
    `(store_id, order_id)` is NOT in scope at `calculate_membership`; it lives in
    the per-provider handler.
  - Verified 2026-07-15 via `get_callers` during CFT-4838 research
    (`docs/specs/CFT-4838`).

## Apple retention messages

- **Cap-lock TOCTOU: the inner `save()` lock releases before the outer txn
  commits.** `AppleRetentionMessage` / `AppleRetentionMessageImage` `save()` use
  `caches["default"].lock(...)` + `transaction.atomic()` to close the
  `MAX_MESSAGES` / `MAX_IMAGES` TOCTOU gap — but only for a bare `model.save()`.
  Wrapped in an OUTER `transaction.atomic()` (`apple/sync.py`
  `upload_message_with_record` / `upload_image_with_record`), the inner lock is
  released as soon as `save()` returns, before the outer transaction and its
  Apple API call commit, so concurrent creators still race past the caps.
  General anti-pattern: **the lock must span the outermost commit, not just the
  innermost save().** Flagged by Cursor on PR #4163 (CFT-2670).
- **One effective `AppleDefaultRetentionMessage` per (locale, bundle).**
  `unique_together=("locale","bundle")`, so at most one message — of exactly one
  type (`TEXT_BASED` / `PLAN_SWITCH` / `PROMOTIONAL_OFFER`) — is the effective
  override for a given (locale, productId) at a time. `select_plan_switch` /
  `select_promo_offer` / `select_default_message_identifier` all query that same
  row filtered by type. By design, not a bug — but easy to misread as
  fallthrough logic when reading `AppleRetentionMessageView._resolve_payload`.
  (CFT-2670)
