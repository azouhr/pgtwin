# Bug Fix: Parallel Cluster Replication Discovery (v1.6.13)

## Overview
**Fixed**: Cross-cluster replication when multiple PostgreSQL clusters run on the same nodes
**Severity**: CRITICAL - Causes data corruption and cluster confusion
**Affected Versions**: All versions prior to v1.6.13
**Release**: v1.6.13

## Problem Description

### Symptom
When running multiple PostgreSQL clusters on the same physical nodes (e.g., PG17 and PG18 clusters), nodes would replicate from the **wrong cluster** during automatic standby initialization via `pg_basebackup`.

### Example Scenario
Given two clusters sharing nodes:
- **PG17 Cluster**: pgtwin01 (primary), pgtwin11 (standby) - using `node_list="pgtwin01 pgtwin11"`
- **PG18 Cluster**: pgtwin02 (primary), pgtwin12 (standby) - using `node_list="pgtwin02 pgtwin12"`

All four nodes have entries in `.pgpass`:
```
pgtwin01:5432:replication:replicator:opensuse
pgtwin02:5432:replication:replicator:opensuse
pgtwin11:5432:replication:replicator:opensuse
pgtwin12:5432:replication:replicator:opensuse
```

**Bug**: pgtwin12 (PG18 standby) would connect to **pgtwin01** (PG17 primary) instead of pgtwin02 (PG18 primary), resulting in:
- PG17 data written to PG18 node
- Version validation failure (PG17 data, PG18 binary)
- Replication slot conflicts (both clusters use same slot name)
- Cluster confusion and startup failures

### Evidence from Logs
```
Dec 28 11:31:32 pgtwin12 pgtwin(postgres-db-18)[3611]: INFO: Parsed replication credentials from /var/lib/pgsql/.pgpass: user=replicator, host=pgtwin01
Dec 28 11:31:34 pgtwin12 pgtwin(postgres-db-18)[3918]: INFO: Replication slot 'ha_slot' already exists on primary (reusing it)
pg_basebackup: error: could not send replication command "START_REPLICATION": ERROR:  replication slot "ha_slot" is active for PID 3355
```

## Root Cause

### Code Location
Function: `parse_pgpass()` (Lines 724-783 in pgtwin)

### Bug Logic
The `parse_pgpass()` function:
1. Greps all `:replication:` entries from `.pgpass`
2. Skips the local node
3. **Returns the FIRST non-local entry** ← BUG!

When pgtwin12 runs:
- Skips pgtwin12 (local node)
- Returns **pgtwin01** (first non-local entry from other cluster!) ❌
- Should return **pgtwin02** (from same cluster's node_list) ✅

### Why `node_list` Parameter Was Ignored
The function **completely ignored** the `node_list` parameter, which defines which nodes belong to each cluster. This parameter exists specifically to prevent cross-cluster communication.

## Fix

### Changed Code
Added `node_list` filtering in `parse_pgpass()` (Lines 762-777):

```bash
# BUG FIX v1.6.13: Only accept entries that are in node_list
# This prevents cross-cluster replication when multiple PostgreSQL clusters run on same nodes
if [ -n "${OCF_RESKEY_node_list}" ]; then
    local in_node_list=false
    for node in ${OCF_RESKEY_node_list}; do
        if [ "$entry_host" = "$node" ]; then
            in_node_list=true
            break
        fi
    done

    if [ "$in_node_list" = "false" ]; then
        ocf_log debug "Skipping .pgpass entry not in node_list: $entry_host (node_list=${OCF_RESKEY_node_list})"
        continue
    fi
fi
```

## Testing

### Test Procedure
1. Put pgtwin12 in standby mode: `crm node standby pgtwin12`
2. Remove PGDATA to trigger auto-initialization: `rm -rf /var/lib/pgsql/data/*`
3. Bring pgtwin12 online: `crm node online pgtwin12`
4. Monitor logs for replication host

### Test Results

**Before Fix**:
```
INFO: Parsed replication credentials: user=replicator, host=pgtwin01  ❌
ERROR: replication slot "ha_slot" is active for PID 3355
PG_VERSION: 17  ❌ (wrong cluster data)
```

**After Fix**:
```
INFO: Parsed replication credentials: user=replicator, host=pgtwin02  ✅
INFO: Discovered promoted cluster node via Pacemaker CIB: pgtwin02  ✅
Basebackup completed successfully
PG_VERSION: 18  ✅ (correct cluster data)
```

## Impact

### Who Is Affected?
- **All users running multiple PostgreSQL clusters on shared nodes**
- Migration scenarios (PG17 → PG18 on same infrastructure)
- Multi-version testing environments
- Blue-green deployment setups

## Summary

### Before Fix
❌ `parse_pgpass()` ignored `node_list` parameter
❌ Returned first non-local entry from `.pgpass`
❌ Cross-cluster replication when multiple clusters on same nodes
❌ Data corruption and version mismatches

### After Fix
✅ `parse_pgpass()` respects `node_list` parameter
✅ Returns first entry that matches `node_list`
✅ Prevents cross-cluster replication
✅ Correct cluster isolation

### Recommended Action
**Upgrade to v1.6.13 immediately** if running multiple PostgreSQL clusters on shared infrastructure.

---

**Release**: pgtwin v1.6.13
**Date**: 2025-12-28
**Severity**: CRITICAL
**Type**: Bug Fix
**Code Changes**: Lines 762-777 in `parse_pgpass()` function
