# Release Notes: pgtwin v1.6.3

**Release Date**: 2025-11-05
**Type**: Bug Fix Release
**Status**: Fixed cluster node name handling and documentation improvements

## Overview

Version 1.6.3 addresses a critical bug where the resource agent used system hostname instead of Pacemaker cluster node name, causing errors in environments where these differ. Also includes important documentation fixes for the QUICKSTART guide.

## Executive Summary

**Issue**: Resource agent used `hostname -s` for Pacemaker operations
**Impact**: Errors when cluster node names differ from system hostnames
**Fix**: New helper function uses `crm_node -n` for correct cluster node name

## Bugs Fixed

### Bug #1: crm_attribute Uses Hostname Instead of Cluster Node Name
**Severity**: HIGH
**Impact**: crm_attribute failures when cluster node name ≠ hostname

**Root Cause**:
The resource agent used `$(hostname -s)` for `crm_attribute` calls and node list comparisons. In environments where the Pacemaker cluster node name differs from the system hostname (e.g., cluster node "psql1" on host "zkvmnode070"), this caused errors:

```
ERROR: crm_attribute: Could not map name=zkvmnode070 to a UUID
```

**Locations Affected**:
1. Line 901: `crm_attribute` - reset failure counter (healthy replication)
2. Line 905: `crm_attribute` - get current failure count
3. Line 907: `crm_attribute` - increment failure counter
4. Line 923: `crm_attribute` - reset before recovery
5. Line 408: `get_replication_host()` - node list comparison
6. Line 1148: `pgsql_demote()` - node list comparison

**Fix**:
Added `get_cluster_node_name()` helper function (lines 345-351) that uses `crm_node -n` to get the correct Pacemaker cluster node name:

```bash
# BROKEN (v1.6.0-1.6.2):
ocf_run crm_attribute -N $(hostname -s) -n postgres-replication-failures -v 0 -l reboot

# FIXED (v1.6.3):
ocf_run crm_attribute -N $(get_cluster_node_name) -n postgres-replication-failures -v 0 -l reboot
```

**Helper Function**:
```bash
get_cluster_node_name() {
    # Use crm_node to get the cluster node name (not hostname)
    # This is critical when cluster node names differ from system hostnames
    crm_node -n 2>/dev/null || hostname -s
}
```

**Lines Changed**: 345-351 (new function), 408, 901, 905, 907, 923, 1148

---

## Documentation Improvements

### QUICKSTART.md Fixes

**Issue #1**: PostgreSQL must be running to create replication user
- **Fixed**: Reordered steps to start PostgreSQL (1.5) before creating user (1.6)
- **Added**: Clear note explaining PostgreSQL must be running

**Issue #2**: Replication slot `ha_slot` doesn't exist during first `pg_basebackup`
- **Fixed**: Added new step 1.7 to create replication slot before basebackup
- **Added**: Verification command and explanation

**Issue #3**: `ocf-tester` command throws errors without proper setup
- **Fixed**: Removed problematic `ocf-tester` command
- **Replaced**: Simple verification using `ls -l` and `meta-data` command
- **Added**: Note explaining ocf-tester complexity

**Corrected Flow**:
1. Initialize and configure PostgreSQL
2. **Start PostgreSQL** (must be running!)
3. Create replication user
4. **Create replication slot `ha_slot`**
5. Create `.pgpass` file
6. Stop PostgreSQL (Pacemaker will manage it)
7. Run `pg_basebackup -S ha_slot` on standby

---

## What's Changed

**Code Changes**:
- ✅ New helper function `get_cluster_node_name()`
- ✅ All `crm_attribute` calls use cluster node name
- ✅ Node list comparisons use cluster node name
- ✅ Backward compatible (falls back to hostname if `crm_node` unavailable)

**Documentation Changes**:
- ✅ Fixed PostgreSQL startup sequence in QUICKSTART.md
- ✅ Added replication slot creation step
- ✅ Improved ocf-tester verification instructions

---

## Upgrade Instructions

### From v1.6.2 to v1.6.3

**Upgrade recommended** for all clusters, especially those where cluster node names differ from hostnames.

```bash
# On both nodes
sudo cp pgsql-ha /usr/lib/ocf/resource.d/heartbeat/pgsql-ha
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql-ha

# Verify version
sudo /usr/lib/ocf/resource.d/heartbeat/pgsql-ha meta-data | grep version

# Cleanup and restart
sudo crm resource cleanup postgres-clone
```

**No configuration changes required** - existing clusters work with v1.6.3.

---

## Testing Performed

### Cluster Node Name Handling

```bash
# Test crm_node functionality
crm_node -n
# Output: psql1 (cluster node name)

hostname -s
# Output: zkvmnode070 (system hostname)

# Verify crm_attribute works
crm_attribute -N $(crm_node -n) -n postgres-replication-failures -v 0 -l reboot
# Result: SUCCESS (no UUID mapping error)
```

### QUICKSTART Validation

- ✅ PostgreSQL starts before user creation
- ✅ Replication slot exists before pg_basebackup
- ✅ Agent installation verifies correctly

---

## Verification

```bash
# Verify version
head -5 pgsql-ha | grep Version
# Output: # Version: 1.6.3

head -5 pgtwin/pgtwin | grep Version
# Output: # Version: 1.6.3

cat pgtwin/VERSION
# Output: 1.6.3

# Test helper function
bash -c 'source pgsql-ha; get_cluster_node_name'
# Output: psql1 (cluster node name)

# Verify no hostname -s in critical paths
grep -n 'crm_attribute.*hostname' pgsql-ha
# Output: (empty - all fixed)
```

---

## Impact Assessment

### Environments Affected (v1.6.0-1.6.2)

**High Impact**:
- ❌ Clusters where node names ≠ hostnames
- ❌ KVM/VM environments with generic hostnames
- ❌ Cloud deployments with instance IDs as hostnames

**No Impact**:
- ✅ Clusters where node names = hostnames
- ✅ Traditional bare metal with matching names

### Symptoms Fixed

Before v1.6.3:
```
pgtwin(postgres-db)[2481]: ERROR: crm_attribute: Could not map name=zkvmnode070 to a UUID
```

After v1.6.3:
```
pgtwin(postgres-db)[2481]: INFO: Replication is healthy, reset failure counter
```

---

## Compatibility

**Backward Compatible**: Yes
- Falls back to `hostname -s` if `crm_node` unavailable
- No configuration changes required
- Existing clusters work without modification

**Forward Compatible**: Yes
- Code structure unchanged
- Parameter names unchanged
- OCF metadata unchanged

---

## Known Limitations (Unchanged from v1.6.2)

The following limitations remain:

1. **pg_basebackup Completion**: May exit with code 1 in some edge cases
2. **Replication Slot Recreation**: May need manual recreation after complex recoveries
3. **Manual Intervention**: Some edge cases may require DBA intervention

These will be addressed in future releases (v1.7.0+).

---

## Next Release (v1.7.0)

Planned improvements:

1. Enhanced recovery completion handling
2. Automatic replication slot recreation
3. Improved edge case handling
4. Additional PostgreSQL version support (15, 16)

---

## Files Modified

| File | Change Type | Description |
|------|-------------|-------------|
| pgsql-ha | Enhanced | Added `get_cluster_node_name()` helper function |
| pgsql-ha | Fixed | 6 locations using cluster node name instead of hostname |
| pgtwin/pgtwin | Enhanced | Added `get_cluster_node_name()` helper function |
| pgtwin/pgtwin | Fixed | 6 locations using cluster node name instead of hostname |
| pgtwin/QUICKSTART.md | Fixed | PostgreSQL startup sequence and slot creation |
| pgtwin/VERSION | Updated | 1.6.2 → 1.6.3 |

---

## Migration Notes

### For New Deployments

Follow the updated QUICKSTART.md which now includes:
- Correct PostgreSQL startup sequence
- Replication slot creation step
- Simplified agent verification

### For Existing v1.6.0-1.6.2 Deployments

**Upgrade if**:
- Cluster node names differ from hostnames
- Seeing crm_attribute UUID mapping errors
- Running in VM/cloud environments

**Safe to skip if**:
- Cluster node names = hostnames
- No crm_attribute errors in logs
- Prefer to wait for v1.7.0

---

## Changelog Summary

```
v1.6.3 (2025-11-05)
-------------------
[FIXED] crm_attribute using hostname instead of cluster node name (6 locations)
[ADDED] get_cluster_node_name() helper function using crm_node -n
[FIXED] QUICKSTART.md: PostgreSQL must be running for user creation
[FIXED] QUICKSTART.md: Create replication slot before pg_basebackup
[FIXED] QUICKSTART.md: Simplified ocf-tester verification
[UPDATED] VERSION: 1.6.2 → 1.6.3
[UPDATED] pgsql-ha header: Version and release date
[UPDATED] pgtwin/pgtwin header: Version and release date

v1.6.2 (2025-11-03)
-------------------
[DOCS] Documentation improvements and self-containment

v1.6.1 (2025-11-03)
-------------------
[FIXED] 6 critical bugs in automatic recovery feature
```

---

**Version Comparison**:

- v1.6.0: Introduced automatic replication recovery
- v1.6.1: Fixed 6 critical bugs in recovery feature
- v1.6.2: Documentation improvements
- **v1.6.3**: Fixed cluster node name handling (current release)
- v1.7.0: Planned recovery enhancements

**Recommended Version**: v1.6.3 for all deployments

---

## Support

- **Issues**: Report at project repository
- **Documentation**: README.md, QUICKSTART.md
- **Testing**: Validated with syntax check and cluster testing

---

**Release Type**: Bug Fix + Documentation
**Backward Compatible**: Yes
**Upgrade Recommended**: Yes (especially for VM/cloud environments)
**Configuration Changes**: None required
