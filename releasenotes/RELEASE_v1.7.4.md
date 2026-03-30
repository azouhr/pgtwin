# pgtwin v1.7.4 Release Notes

**Release Date:** 2026-03-30
**Type:** Bug Fix Release
**Status:** Production Ready

---

## Overview

This release fixes a critical bug in synchronous replication management that caused **write blocking** when a standby node became unavailable. All users running pgtwin in `rep_mode=sync` should upgrade.

---

## What's Fixed

### pgtwin v1.7.4 — Critical Sync Replication Bug Fix

**Bug:** `get_safe_synchronous_standby_names()` incorrectly returned `'*'` in all "no standby available" scenarios, causing PostgreSQL to block all writes while waiting for a sync replica that wasn't connected.

**Impact:** When a standby node went down (crash, maintenance, network partition), the primary would become unwritable instead of automatically switching to async mode. This negated a core HA guarantee.

**Root cause:** The function comments stated that returning `'*'` "prevents write blocking" or "allows connections" — the opposite of actual PostgreSQL behaviour. `synchronous_standby_names = '*'` with no standbys connected causes PostgreSQL to block all `COMMIT` operations indefinitely.

**Fix:** All four return paths in `get_safe_synchronous_standby_names()` that represented "no standby available" states now return `''` (empty string = async mode) instead of `'*'`:

| Condition | Before (broken) | After (fixed) |
|-----------|-----------------|---------------|
| Clone resource lookup fails | `*` → blocks writes | `''` → async |
| No Unpromoted nodes in cluster | `*` → blocks writes | `''` → async |
| No standbys streaming to PostgreSQL | `*` → blocks writes | `''` → async |
| Unpromoted nodes exist but none streaming yet | `*` → blocks writes | `''` → async |

**Verified behaviour after fix:**
1. Standby goes down → `synchronous_standby_names` set to `''` → writes proceed normally in async mode
2. Standby reconnects and starts streaming → monitor detects it → `synchronous_standby_names` updated to standby name → sync mode resumes automatically

---

## Upgrade

No configuration changes required. Deploy the updated `pgtwin` agent to all cluster nodes:

```bash
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

No cluster restart needed — the fix takes effect on the next monitor cycle.

---

## Files Changed

- `pgtwin` — version 1.7.4, bug fix in `get_safe_synchronous_standby_names()`
