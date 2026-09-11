---
name: kb-refresh
description: Renamed 2026-09-11. Use cyphy:repo-harvest instead — this stub exists only so a scheduled job still pointing at the old name does not silently do nothing.
---

# kb-refresh was renamed to repo-harvest

**Invoke `cyphy:repo-harvest` now and follow it.** Do not try to do the work
from this file; it contains none of it.

`/repo-harvest` is not a pure rename: it runs over **every repo on this box**,
writes repo-local facts append-only, and only *proposes* changes to the shared
fleet memory. `/repo-harvest-apply` is what applies those proposals.

This stub is temporary. It stays until every Orca Automation has been repointed,
then it is deleted — say so in your report if you were reached through it, so
the automation gets fixed.
