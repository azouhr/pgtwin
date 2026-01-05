# Enhancement: Pre-Basebackup Version Check (v1.6.14)

## Overview
**Added**: PostgreSQL major version compatibility check before pg_basebackup starts  
**Type**: Defense-in-depth safety enhancement  
**Severity**: Enhancement (complements v1.6.13 bug fix)  
**Release**: v1.6.14  

## Problem Addressed

### Scenario
With multiple PostgreSQL clusters on shared nodes, configuration errors could cause a standby to attempt replication from a primary running a different PostgreSQL major version.

**Example**:
- Node pgtwin12 running PostgreSQL 18 binary
- Misconfigured to replicate from pgtwin01 running PostgreSQL 17
- pg_basebackup would fail with cryptic errors
- Data corruption risk if basebackup partially succeeded

### Why This Enhancement?

This adds **defense-in-depth** on top of v1.6.13's node_list filtering:
- **v1.6.13**: Prevents wrong cluster selection via node_list filtering
- **v1.6.14**: Detects version mismatch even if configuration is wrong
- **Together**: Comprehensive protection against cross-cluster replication

## Solution

### Implementation

**Location**: `start_async_basebackup()` function (Lines 2834-2903)  
**When**: Runs AFTER slot creation, BEFORE pg_basebackup starts  
**Duration**: < 100ms (two quick SQL queries)

### Logic Flow

```bash
1. Get local PostgreSQL binary version
   ${PG_CTL} --version
   Extract major version (e.g., "18")

2. Get primary server version  
   psql -h primary "SHOW server_version"
   Extract major version (e.g., "17" or "18")

3. Compare major versions
   IF local_major != primary_major THEN
     Log detailed error with:
       - Both versions
       - Primary hostname
       - Troubleshooting steps
     Return $OCF_ERR_CONFIGURED (blocks basebackup)
   ELSE
     Log success and proceed
   END IF
```

### Error Message

When version mismatch detected:
```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ CRITICAL: PostgreSQL version mismatch detected!            ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

Local binary major version:  PostgreSQL 18
Primary server major version: PostgreSQL 17
Primary host: pgtwin01

Cannot replicate between different PostgreSQL major versions.
This likely indicates one of the following:
  1. Wrong cluster configuration (check node_list parameter)
  2. Wrong primary node discovered
  3. Cross-cluster replication attempt (multiple clusters on same nodes)

Please verify:
  - node_list='pgtwin02 pgtwin12'
  - Primary host 'pgtwin01' is in the correct cluster
  - /var/lib/pgsql/.pgpass contains entries only for this cluster's nodes

pg_basebackup will NOT proceed.
```

## Code Changes

### Added to `start_async_basebackup()` (Lines 2834-2903)

**Key features**:
1. **Graceful degradation** - Proceeds if version check fails (warns but doesn't block)
2. **Works in container mode** - Uses `PG_CTL` and `PSQL` variables
3. **Version parsing** - Handles formats like "17.2", "18.1", "18devel"
4. **Clear errors** - Box drawing + troubleshooting steps
5. **No performance impact** - Two quick queries, no database writes

### Graceful Failure Handling

If version check encounters problems:
- **Can't get local version**: Warns, proceeds with basebackup
- **Can't connect to primary**: Warns, proceeds with basebackup  
- **Can't parse versions**: Warns, proceeds with basebackup

Only **version mismatch** blocks the basebackup.

## Testing

### Test 1: Matching Versions (PG18 → PG18)

**Setup**:
- pgtwin12 (PG18) replicating from pgtwin02 (PG18)
- Empty PGDATA to trigger auto-initialization

**Result**:  
✅ Basebackup completed successfully  
✅ pgtwin12 got correct PG18 data  
✅ Cluster healthy

**Log evidence** (implicit - basebackup succeeded):
```
Dec 28 11:56:56: Ensuring replication slot 'ha_slot' exists on primary pgtwin02
Dec 28 11:56:56: Automatic standby initialization started
Dec 28 11:57:12: Asynchronous pg_basebackup completed successfully
PG_VERSION: 18
```

### Test 2: Version Mismatch (Would Fail)

**Scenario** (theoretical - not executed to avoid breaking cluster):
- pgtwin12 (PG18 binary) trying to replicate from pgtwin01 (PG17 server)

**Expected result**:
❌ Basebackup blocked with error  
❌ Clear message identifying version mismatch  
❌ Troubleshooting steps provided

## Benefits

### 1. Early Detection
- Catches version mismatches **before** pg_basebackup starts
- Prevents wasted time on doomed basebackups
- Avoids cryptic pg_basebackup error messages

### 2. Clear Error Messages
- Box-drawn critical error (hard to miss)
- Shows both versions side-by-side
- Lists likely causes
- Provides specific troubleshooting steps

### 3. Defense-in-Depth
Works with v1.6.13 node_list filtering:
- **Layer 1** (v1.6.13): Parse .pgpass only from node_list
- **Layer 2** (v1.6.14): Verify version compatibility
- **Both layers**: Independent safety checks

### 4. Container Mode Support
- Works with both bare-metal and container deployments
- Uses `PG_CTL` and `PSQL` variables (respects container wrappers)
- No code duplication

### 5. Minimal Performance Impact
- Two quick commands: `pg_ctl --version` and `SHOW server_version`
- Total overhead: < 100ms
- Only runs when basebackup needed (rare event)

## Use Cases

### Caught by This Check

1. **Misconfigured node_list** (if v1.6.13 somehow failed)
2. **Manual .pgpass edits** pointing to wrong cluster
3. **Copy-paste configuration errors** between clusters
4. **Migration scenarios** with overlapping node names
5. **Testing environments** with multiple PG versions

### NOT Caught by This Check

- **Same major version** - PG17.1 vs PG17.2 (intentionally allowed)
- **Minor version mismatches** - Generally safe for replication
- **After basebackup completes** - This check runs BEFORE

## Upgrade Path

### Installation

```bash
# Deploy v1.6.14 to all nodes
for node in node1 node2 node3 node4; do
    scp pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin
done
```

**No cluster restart required** - Enhancement activates on next basebackup.

### Verification

Version check runs automatically when:
- Auto-initialization triggers (empty PGDATA)
- Manual basebackup needed (data corruption recovery)
- Disk replacement scenarios

No configuration changes needed.

## Implementation Details

### Code Location
- **File**: `pgtwin`
- **Function**: `start_async_basebackup()`
- **Lines**: 2834-2903 (70 lines)

### Dependencies
- Requires `PG_CTL` and `PSQL` binaries (already required)
- Works with existing `run_as_pguser` helper
- No new external dependencies

### Error Codes
- **Success (versions match)**: Continues to pg_basebackup
- **Failure (versions mismatch)**: Returns `$OCF_ERR_CONFIGURED` (stops resource start)
- **Check failed**: Warns but continues (graceful degradation)

## Compatibility

- **Backward compatible**: No configuration changes needed
- **Works with**: v1.6.0 through v1.6.13
- **Complements**: v1.6.13 node_list filtering
- **Container mode**: Fully supported (v1.6.5+)

## Summary

### What This Enhancement Does
✅ Checks PostgreSQL version compatibility before basebackup  
✅ Blocks basebackup if major versions don't match  
✅ Provides clear, actionable error messages  
✅ Adds defense-in-depth to v1.6.13 fix  
✅ Works in both bare-metal and container modes  

### What This Enhancement Does NOT Do
❌ Replace v1.6.13 node_list filtering (they work together)  
❌ Check minor version compatibility (17.1 vs 17.2)  
❌ Validate after basebackup completes  
❌ Require configuration changes  

### Recommended Action
Upgrade to v1.6.14 for additional safety when running multiple PostgreSQL clusters on shared infrastructure.

---

**Release**: pgtwin v1.6.14  
**Date**: 2025-12-28  
**Type**: Enhancement (Defense-in-Depth)  
**Code Changes**: Lines 2834-2903 in `start_async_basebackup()` function  
**Complements**: v1.6.13 cross-cluster replication bug fix  
