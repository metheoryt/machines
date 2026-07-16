# Project memory — kan-kan

<!--
Per-project durable facts, auto-loaded by the project-memory-check.sh SessionStart
hook (merged with global + per-host memory). One bullet per fact under a topical
heading. Keep curated. Do NOT put secrets here.
-->

## Tooling

- **Run dev tools via `uv` / `uvx`, not a bare binary or docker.** `pre-commit`
  is not a project dependency, so `uv run pre-commit` fails ("No such file") —
  use `uvx pre-commit run --files …`. (Its hooks only match Python/TOML, so
  docs-only commits skip all hooks anyway.)

## Product / domain

- **Qurly = Pure's India-regional app variant** (a second `application`/tenant
  alongside the main Pure app). It leans on the web payment providers
  (MOBI/Pay2Me). Multi-app concerns (e.g. `send_push(application=…)`, OneSignal
  multi-tenancy) apply per-application. (Sometimes typo'd "quilry"/"quirly".)

## Jira (CFT project)

- **`[MNT]` summary tag = the Monetization team** (a team identifier), NOT
  "maintenance". Don't infer work-type from the tag — that's the separate
  Classification field.
- **CFT requires the `Classification` field on every issue create**
  (`customfield_10162`) — omitting it 400s with "Classification is required."
  Option values seen: `Product Feature` (10188), `Tech Debt` (10189),
  `Product Debt` (10254). Pick by work-TYPE, independent of the team tag; match
  peer tickets when unsure.
- **Epic children use the `parent` field** (company-managed project,
  `simplified:false`): setting `parent: <EPIC-KEY>` on a Task parents it under
  the Epic correctly (verified). Not the legacy Epic-Link custom field.

## Realtime / Centrifugo

- **Two Centrifugo stacks coexist — v3 (legacy) and v6 (current).** v3 lives
  in-repo (`common/centrifugo/` — `get_v3_client` / `personal_event_v3`, plain
  HTTP `publish`; docker-compose pins `centrifugo/centrifugo:v3.2.3`). v6 is the
  one to build on; v3 is being phased out.
- **v6 outbound push lives in the external `pure-core` lib, NOT in-repo**
  (`pure_core.client_events`, pinned `v0.0.119`). Events subclass `ClientEvent`
  (pydantic) declared per-domain in `*/logic/centrifugo_events.py`; you call
  `.publish(user_id)` / `.broadcast(user_ids)` / `.batch_publish([...])`.
  Transport = HTTP POST to `{CENTRIFUGO_V6_HOST}/api/{publish|broadcast|batch}`
  (`Authorization: apikey …`), channel `personal:#{user_id}`. **Async variants
  (`publish_async` / `broadcast_async` / `batch_publish_async`) already exist**
  but the project currently calls only the sync ones.
- **v6 inbound (client→backend RPC) uses Centrifugo's RPC proxy.**
  `docker/centrifugo_config.json` `proxy_rpc_endpoint` → `POST
  /meta_api/centrifugo/rpc_answer/` → `CentrifugoRPCViewSet` (`meta_api/views/
  centrifugo.py`), which `importlib`-dispatches method `kankan:<module>.<name>`
  to `meta_api/centrifugo/module/<module>.py::method_<name>`, returning an
  `RPCAnswer(data, error)`. Handler modules: `base`, `random_chat`, `smart_feed`.
  Access gates in `meta_api/centrifugo/permissions.py`.
- **v6 is env-gated and inert locally.** Config comes from `CENTRIFUGO_V6_HOST` /
  `CENTRIFUGO_V6_API_KEY` / `_TIMEOUT_SECONDS` / `_READ_TIMEOUT_SECONDS` (pure-core
  `env_get`, overridable via a `CLIENT_EVENTS` Django setting). If
  `CENTRIFUGO_V6_HOST` is empty every publish is a **silent no-op** — and the
  local `docker/kankan.env` sets only the v3 vars, so v6 push does nothing in the
  default local stack.
- **Connection auth (shared by v3 & v6):** `POST /centrifugo/get_token/`
  (`GetTokenViewSet`, `api/api_centrifugo/`) → HS256 JWT signed with
  `settings.CENTRIFUGO_HMAC_KEY`, exp `CENTRIFUGO_WS_TOKEN_LIFETIME_SEC`
  (default 24h).
- **Migration bridge = `random_chat/logic/events.py`.** Each sender dual-writes:
  it fires the v3 `personal_event_v3(...)` AND the equivalent v6
  `ClientEvent(...).publish(...)` for the same module/action/data (both hit
  `personal:#{user_id}`). v6 runs in parallel with v3 pending cutover.
