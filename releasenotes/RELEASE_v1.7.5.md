# pgtwin v1.7.5 Release Notes

**Release Date:** 2026-04-29
**Type:** Bug Fix Release
**Status:** Production Ready

---

## Overview

This release fixes a regression introduced in v1.7.4 that caused new clusters (or clusters with manually-configured standbys) to permanently stay in async mode even with a healthy streaming standby.

---

## What's Fixed

### Regression: New clusters stuck in async mode (v1.7.4 → v1.7.5)

**Bug:** v1.7.4 changed `get_safe_synchronous_standby_names()` to return `''` (async) when no intersection was found between Pacemaker's Unpromoted node names and PostgreSQL's `pg_stat_replication.application_name`. This case arises when the `application_name` in `primary_conninfo` was not explicitly set to match the Pacemaker node name — common on new or manually-configured clusters where pgtwin has not yet written the standby's configuration.

**Impact:** Any cluster where the standby's `application_name` did not exactly match the Pacemaker node hostname would permanently remain in async mode. The monitor's sync detection would always return `''` and never enable sync, even with a healthy streaming standby.

**Root cause:** The intersection logic correctly identifies the "name mismatch" case (standbys ARE streaming, but with unexpected `application_name` values). v1.7.4 incorrectly returned `''` here, which conflated two different scenarios:
1. No standbys streaming at all → `''` is correct (prevents write blocking)
2. Standbys streaming but names don't match → `'*'` is correct (keep sync active, warn admin)

**Fix:** The name-mismatch case (case 2) now returns `'*'` with a clear log warning pointing the admin to fix `primary_conninfo`. Case 1 (truly no standbys connected) continues to return `''` as introduced in v1.7.4.

**The correct decision table after this fix:**

| Condition | Returns | Effect |
|-----------|---------|--------|
| Clone resource lookup fails | `''` | Async (safe fallback) |
| No Unpromoted nodes in cluster | `''` | Async (no standbys present) |
| Unpromoted nodes exist, none streaming | `''` | Async (prevents write blocking — v1.7.4 fix) |
| Unpromoted nodes exist, streaming but names mismatch | `'*'` | Sync with any standby (regression fix) |
| Unpromoted nodes exist, streaming, names match | `'nodename'` | Sync with specific standby (normal) |

---

## Upgrade

Deploy to all cluster nodes — no configuration changes required:

```bash
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

If your cluster is currently stuck in async due to this regression, the fix takes effect on the next monitor cycle without any restart.

To permanently resolve the name mismatch warning, ensure the standby's `primary_conninfo` includes `application_name=<pacemaker-node-name>`. pgtwin sets this automatically via auto-initialization; manual setups may need to add it.

---

## Files Changed

- `pgtwin` — version 1.7.5, regression fix in `get_safe_synchronous_standby_names()`
