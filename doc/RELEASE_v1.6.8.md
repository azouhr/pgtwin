# pgtwin v1.6.8 Release Notes

**Release Date**: 2025-12-28
**Type**: Bug Fix and Enhancement Release
**Scope**: Critical fixes for production deployments

## Overview

This release consolidates all development work since v1.6.7, including three critical bug fixes and one defense-in-depth enhancement. All changes focus on reliability and correctness in multi-cluster environments and migration scenarios.

## What's Included

### pgtwin OCF Agent (v1.6.8)

**Critical Bug Fixes:**
1. **Cross-Cluster Replication Prevention** (formerly v1.6.13)
   - Fixed `parse_pgpass()` ignoring node_list parameter
   - Prevents standbys from replicating from wrong PostgreSQL cluster
   - Critical for deployments with multiple clusters on same nodes

2. **Basebackup Log File Ownership** (formerly v1.6.17)
   - Fixed log files created as root instead of postgres user
   - Prevents permission errors during subsequent operations
   - Ensures all state files have consistent ownership

**Enhancement:**
3. **Pre-Basebackup Version Check** (formerly v1.6.14)
   - Validates PostgreSQL major version before pg_basebackup starts
   - Defense-in-depth protection against version mismatches
   - Clear error messages with troubleshooting steps

### pgtwin-migrate OCF Agent (v1.6.8)

**Critical Bug Fix:**
1. **XML-Based Cluster Discovery** (formerly v1.6.15)
   - Replaced unreliable text parsing with structured XML/XPath
   - Eliminates race conditions during cluster state transitions
   - Ensures correct promoted node identification

### Documentation

**Critical Issue Identified:**
- **VIP Colocation Constraint** (v1.6.16)
  - Documented missing colocation constraint in deployments
  - All example configurations already include correct setup
  - Production checklist updated with verification steps

## Critical Bugs Fixed

### 1. Cross-Cluster Replication (pgtwin)

**Problem**: When multiple PostgreSQL clusters share infrastructure, standby nodes could replicate from wrong cluster due to `parse_pgpass()` ignoring node_list parameter.

**Impact**:
- **CRITICAL** for multi-cluster deployments
- Standby gets wrong data (e.g., PG18 node gets PG17 data)
- Silent failure until version mismatch detected

**Root Cause**: `parse_pgpass()` returned first non-local .pgpass entry without checking node_list.

**Fix**: Added node_list filtering (Lines 762-777)
```bash
# Only accept entries that are in node_list
if [ -n "${OCF_RESKEY_node_list}" ]; then
    for node in ${OCF_RESKEY_node_list}; do
        if [ "$entry_host" = "$node" ]; then
            in_node_list=true
            break
        fi
    done
    if [ "$in_node_list" = "false" ]; then
        continue  # Skip entries not in node_list
    fi
fi
```

**Testing**: Confirmed pgtwin12 (PG18) now correctly replicates from pgtwin02 (PG18) instead of pgtwin01 (PG17).

**Documentation**: BUGFIX_PARALLEL_CLUSTER_DISCOVERY_v1.6.13.md

---

### 2. Basebackup Log Ownership (pgtwin)

**Problem**: Log files created by background pg_basebackup subprocess owned by root instead of postgres user.

**Impact**:
- **MODERATE** severity
- Potential permission errors if postgres user tries to access logs
- Inconsistent file ownership in /var/lib/pgsql/

**Root Cause**: Shell redirection `> "${log_file}"` happens in root context before `run_as_pguser`.

**Fix**: Pre-create log files with correct ownership (Lines 2920-2936)
```bash
# Pre-create log file with correct ownership
cat > "${log_file}" <<EOF
========================================
pg_basebackup started: $(date '+%Y-%m-%d %H:%M:%S')
...
========================================

EOF
chown ${OCF_RESKEY_pguser}:${pidfile_group} "${log_file}"
```

**Testing**: Verified ownership on all cluster nodes before/after fix.

**Documentation**: BUGFIX_FILE_OWNERSHIP_v1.6.7.md

---

### 3. XML-Based Cluster Discovery (pgtwin-migrate)

**Problem**: Text-based parsing of `crm_mon` output unreliable during cluster state transitions, causing wrong promoted node discovery.

**Impact**:
- **HIGH** severity for migration operations
- Creates subscriptions on standby nodes (read-only) → failure
- Only manifests during cluster transitions

**Root Cause**: awk parsing ambiguous between "Promoting" vs "Promoted" states.

**Fix**: Replaced with XML/XPath parsing (Lines 715-753)
```bash
# Use structured XML parsing
target_node=$(crm_mon --as-xml 2>/dev/null | xmllint --xpath \
    "string(//clone[@id='${clone_resource}']/resource[@role='${role}']/node/@name)" - 2>/dev/null)
```

**Testing**: Migration cutover correctly identified pgtwin02 as Promoted during failover.

**Documentation**: BUGFIX_XML_CLUSTER_DISCOVERY_v1.6.15.md

## Enhancement

### Pre-Basebackup Version Check (pgtwin)

**Feature**: Validates PostgreSQL major version compatibility before pg_basebackup starts.

**Benefits**:
- Defense-in-depth protection (complements node_list filtering)
- Early detection of version mismatches
- Clear error messages with troubleshooting steps

**Implementation**: Version check in `start_async_basebackup()` (Lines 2834-2903)

**Error Example**:
```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ CRITICAL: PostgreSQL version mismatch detected!            ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

Local binary major version:  PostgreSQL 18
Primary server major version: PostgreSQL 17
Primary host: pgtwin01

Cannot replicate between different PostgreSQL major versions.
```

**Documentation**: ENHANCEMENT_VERSION_CHECK_v1.6.14.md

## Documentation Updates

### VIP Colocation Constraint (Configuration Issue)

**Discovery**: During migration testing, found that VIP can run on different node than promoted database without colocation constraint.

**Impact**: **CRITICAL** - All pgtwin deployments with VIPs potentially affected.

**Root Cause**: Ordering constraints control WHEN (timing), not WHERE (placement).

**Status**:
- ✅ QUICKSTART.md already includes colocation constraint
- ✅ pgsql-resource-config.crm already includes colocation constraint
- ✅ Documentation updated with prominent warnings

**Workaround**: Add colocation constraint manually if missing:
```bash
crm configure colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```

**Documentation**: BUGFIX_VIP_COLOCATION_v1.6.16.md

## Upgrade Path

### From v1.6.7 → v1.6.8

**Installation** (both pgtwin and pgtwin-migrate):
```bash
# 1. Deploy to all nodes
for node in node1 node2 node3 node4; do
    scp github/pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin
    scp github/pgtwin-migrate root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
    ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin*"
done

# 2. Install xmllint if not present (required for pgtwin-migrate)
for node in node1 node2 node3 node4; do
    ssh root@$node "zypper install -y libxml2-tools"
done

# 3. Verify VIP colocation constraint (CRITICAL!)
crm configure show | grep "^colocation.*vip.*Promoted"
```

**Expected output:**
```
colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```

**If missing, add immediately:**
```bash
crm configure colocation vip-with-primary inf: \
    <vip-resource> <clone-resource>:Promoted
```

**No cluster restart required** - Changes activate on next relevant operation.

### Verification

Test cross-cluster isolation (multi-cluster only):
```bash
# On standby node, check which primary it selects
grep "Parsed replication credentials" /var/log/pacemaker/pacemaker.log
# Should show primary from same cluster (in node_list)
```

Test VIP placement:
```bash
# Trigger failover
crm resource move postgres-clone <target-node>

# Verify VIP followed database
crm status | grep -E "vip|Promoted"

# Clean up
crm resource clear postgres-clone
```

## New Dependencies

**pgtwin-migrate only:**
- `xmllint` (from libxml2-tools package)
- Available in all supported distributions
- Added to QUICKSTART.md installation steps

## Compatibility

- **Backward compatible** with existing configurations
- **No breaking changes** in parameters or behavior
- Works with all PostgreSQL versions (tested with PG17 and PG18)
- Works in both bare-metal and container modes

## Performance Impact

**Negligible:**
- Version check: ~100ms (only during basebackup initialization)
- XML parsing: ~3-8ms overhead vs text parsing (migration operations)
- File ownership: Zero runtime impact

## Testing

**Test Environment:**
- 4-node cluster (2×PG17 + 2×PG18)
- Dual-cluster configuration on shared nodes
- Physical and logical replication
- Container mode (Podman)

**Test Coverage:**
1. ✅ Cross-cluster replication isolation (v1.6.13 fix)
2. ✅ Version mismatch detection (v1.6.14 enhancement)
3. ✅ File ownership verification (v1.6.17 fix)
4. ✅ Migration cutover during failover (v1.6.15 fix)
5. ✅ VIP colocation during failover (v1.6.16 verification)
6. ✅ Automatic rollback with sanity checks

**All tests passed** - See SESSION_SUMMARY_2025-12-28_FINAL.md for complete results.

## Known Limitations

1. **VIP Colocation**: Not automatically created by pgtwin (must be manually configured)
   - Workaround: Follow QUICKSTART.md or pgsql-resource-config.crm examples
   - Future: May be added to pgtwin setup automation

2. **Version Check**: Only checks major version (e.g., 17 vs 18)
   - Minor version differences (17.1 vs 17.2) are allowed
   - This is intentional - minor versions are generally compatible

## Production Recommendations

### Immediate Actions (ALL deployments)

1. **Verify VIP colocation constraint exists:**
   ```bash
   crm configure show | grep "^colocation.*vip.*Promoted"
   ```

2. **If missing, add immediately:**
   ```bash
   crm configure colocation vip-with-primary inf: \
       <vip-resource> <clone-resource>:Promoted
   ```

3. **Test VIP migration:**
   ```bash
   crm status | grep -E "vip|Promoted"  # Before
   crm resource move <clone-resource> <target-node>
   crm status | grep -E "vip|Promoted"  # After (VIP should follow)
   crm resource clear <clone-resource>
   ```

### Multi-Cluster Deployments

4. **Verify node_list parameter** in cluster configuration
5. **Test basebackup** from correct cluster after upgrade
6. **Review .pgpass files** - ensure entries match node_list

### Migration Deployments

7. **Install xmllint** on all migration nodes
8. **Test migration discovery** during cluster transitions
9. **Verify automatic rollback** functionality

## File Changes

### pgtwin (OCF Resource Agent)
- **Version**: 1.6.8
- **Lines Changed**: ~120 lines across 3 bug fixes
- **Functions Modified**:
  - `parse_pgpass()` - node_list filtering
  - `start_async_basebackup()` - version check + file ownership
- **Code Locations**:
  - Lines 762-777: Cross-cluster replication fix
  - Lines 2834-2903: Version check
  - Lines 2920-2936: File ownership fix

### pgtwin-migrate (OCF Resource Agent)
- **Version**: 1.6.8
- **Lines Changed**: ~40 lines
- **Functions Modified**:
  - `discover_cluster_node()` - XML/XPath parsing
- **Code Locations**:
  - Lines 715-753: XML-based discovery

### Documentation
- BUGFIX_PARALLEL_CLUSTER_DISCOVERY_v1.6.13.md (4.8K)
- ENHANCEMENT_VERSION_CHECK_v1.6.14.md (8.0K)
- BUGFIX_XML_CLUSTER_DISCOVERY_v1.6.15.md (12K)
- BUGFIX_VIP_COLOCATION_v1.6.16.md (7.9K)
- BUGFIX_FILE_OWNERSHIP_v1.6.7.md (new)
- SESSION_SUMMARY_2025-12-28_FINAL.md (complete testing report)

## Summary

### What This Release Fixes
✅ Cross-cluster replication isolation (CRITICAL)
✅ XML-based cluster discovery (HIGH)
✅ Basebackup log file ownership (MODERATE)
✅ Version mismatch prevention (Defense-in-depth)
✅ VIP colocation documentation (CRITICAL awareness)

### What This Release Does NOT Change
❌ No configuration parameter changes
❌ No breaking changes to existing behavior
❌ No cluster restart required
❌ No database downtime needed

### Recommended Action

**ALL users should upgrade to v1.6.8 immediately** for critical bug fixes and reliability improvements.

**Priority:**
1. **CRITICAL**: Verify VIP colocation constraint (all deployments)
2. **HIGH**: Upgrade multi-cluster deployments (v1.6.13 fix)
3. **MEDIUM**: Upgrade migration deployments (v1.6.15 fix)
4. **LOW**: Upgrade single-cluster bare-metal deployments

---

**Release**: pgtwin v1.6.8
**Date**: 2025-12-28
**Previous Release**: v1.6.7 (2025-12-xx)
**Type**: Bug Fix and Enhancement
**Status**: Production Ready ✅
