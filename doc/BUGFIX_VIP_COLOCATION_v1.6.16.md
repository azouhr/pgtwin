# Bug Fix: VIP Colocation Constraint Missing (v1.6.16)

## Overview
**Fixed**: VIP lacks colocation constraint, can run on wrong node after failover  
**Severity**: CRITICAL - Production traffic can be sent to wrong database node  
**Affected Versions**: All versions prior to v1.6.16  
**Release**: v1.6.16  

## Problem Description

### Symptom
After cluster failover or restart, the VIP (Virtual IP) can start on a different node than the promoted PostgreSQL instance, causing connection failures.

### Example Scenario
**Before failover:**
- Node pgtwin01: Promoted PostgreSQL + VIP (192.168.60.100) ✅ Correct
- Node pgtwin11: Standby PostgreSQL

**After failover (pgtwin01 fails):**
- Node pgtwin11: Promoted PostgreSQL ✅
- Node pgtwin01: VIP (192.168.60.100) ❌ WRONG!

**Result:** Applications connect to VIP on pgtwin01, but database is on pgtwin11 → **Connection refused**

### Root Cause

pgtwin creates **ordering constraints** but **NOT colocation constraints**.

**Ordering constraints** (what pgtwin creates):
```bash
order promote-before-vip Mandatory: postgres-clone:promote postgres-vip:start
order vip-stop-before-demote Mandatory: postgres-vip:stop postgres-clone:demote
```
- Controls **WHEN** resources start/stop (sequence)
- Ensures VIP starts **after** database promotes
- Ensures VIP stops **before** database demotes

**But this does NOT guarantee the VIP runs on the SAME NODE as the promoted database!**

**Colocation constraint** (MISSING):
```bash
colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```
- Controls **WHERE** resources run (placement)
- Ensures VIP runs on **same node** as promoted database

### Why This Matters

Without colocation:
- Pacemaker can place VIP on any online node
- VIP placement independent of database location
- Applications connect to VIP → wrong node → connection failure
- **Especially problematic** after failover, cluster restart, or node maintenance

## The Fix

### Code Changes

**File**: `pgtwin`  
**Function**: Cluster configuration validation/setup  
**Impact**: Adds colocation constraint during initial setup

The fix ensures pgtwin creates BOTH constraints:

1. **Ordering**: VIP lifecycle tied to database promotion/demotion
2. **Colocation**: VIP runs on same node as promoted database

### Implementation

Add colocation constraint creation in cluster setup:

```bash
# For bare-metal mode
crm configure colocation vip-with-primary-${resource_name} inf: ${vip_resource} ${clone_resource}:Promoted

# Example output:
colocation vip-with-primary-postgres-db inf: postgres-vip postgres-clone:Promoted
```

This ensures:
- VIP **always** runs on same node as promoted PostgreSQL
- No connection failures after failover
- Correct behavior during cluster transitions

## Workaround (Manual Fix)

For existing clusters, add colocation constraint manually:

```bash
# Identify your VIP and clone resource names
crm configure show | grep "^primitive.*IPaddr2"
crm configure show | grep "^clone.*postgres"

# Add colocation constraint
crm configure colocation vip-with-primary inf: <vip-resource> <clone-resource>:Promoted

# Example:
crm configure colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```

### Verification

Check constraint exists:
```bash
crm configure show | grep "^colocation.*postgres-vip"
```

Expected output:
```
colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```

Test VIP follows promoted node:
```bash
# Check current state
crm status | grep -E "postgres-vip|Promoted"

# Trigger failover
crm resource move postgres-clone <target-node>
sleep 10

# Verify VIP moved with database
crm status | grep -E "postgres-vip|Promoted"

# Clean up move constraint
crm resource clear postgres-clone
```

## Impact

### Who Is Affected?

**ALL pgtwin deployments** are affected:
- Production clusters with VIPs
- Multi-node HA setups
- Any configuration using IPaddr2 for client connectivity

### Severity

**CRITICAL** because:
- Silent failure (cluster appears healthy)
- Only manifests during failover/restart
- Causes production connection failures
- No error messages (Pacemaker behavior is "correct" without colocation)

### Risk Scenarios

1. **Planned failover**: Admin moves primary → VIP stays on old node
2. **Unplanned failover**: Node crashes → VIP starts on wrong survivor
3. **Cluster restart**: Both nodes restart → VIP placement random
4. **Node maintenance**: Put node in standby → VIP might not follow database

## Testing

### Test 1: Manual Constraint Addition

**Setup**: Existing cluster without colocation constraint

**Steps**:
1. Check current VIP and promoted node location
2. Add colocation constraint
3. Wait for Pacemaker to reconcile (may trigger VIP migration)
4. Verify VIP on same node as promoted database

**Expected Result**:
```bash
crm status
  * postgres-vip    Started pgtwin01
  * postgres-clone  Promoted: pgtwin01  ✅ Same node
```

### Test 2: Failover with Colocation

**Setup**: Cluster with colocation constraint

**Steps**:
1. Note current promoted node (e.g., pgtwin01)
2. Trigger failover: `crm resource move postgres-clone pgtwin11`
3. Monitor VIP migration: `watch crm status`
4. Verify VIP followed database to pgtwin11
5. Clean up: `crm resource clear postgres-clone`

**Expected Result**: VIP migrates to pgtwin11 along with promoted database

### Test 3: Cluster Restart

**Setup**: Cluster with colocation constraint

**Steps**:
1. Restart cluster on both nodes
2. Wait for cluster to stabilize
3. Check VIP and promoted database locations

**Expected Result**: VIP on same node as promoted database

## Documentation Updates

### Updated Files

1. **README.postgres.md**: Add colocation to cluster setup section
2. **QUICKSTART.md**: Include colocation in deployment steps
3. **MANUAL_RECOVERY_GUIDE.md**: Add colocation verification to checklist
4. **PRODUCTION_CHECKLIST.md**: Add colocation constraint verification

### Cluster Setup Template

**Complete VIP configuration** (ordering + colocation):

```bash
# 1. Create VIP resource
crm configure primitive postgres-vip IPaddr2 \
    params ip=192.168.60.100 cidr_netmask=24 \
    op monitor interval=10s timeout=20s

# 2. Create ordering constraints
crm configure order promote-before-vip Mandatory: \
    postgres-clone:promote postgres-vip:start symmetrical=false
crm configure order vip-stop-before-demote Mandatory: \
    postgres-vip:stop postgres-clone:demote symmetrical=false

# 3. Create colocation constraint (NEW - CRITICAL!)
crm configure colocation vip-with-primary inf: \
    postgres-vip postgres-clone:Promoted
```

## Deployment

### Upgrade Path

**No code changes to deployed agents** - this is a configuration fix.

1. Add colocation constraint to existing clusters:
   ```bash
   crm configure colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
   ```

2. Verify constraint:
   ```bash
   crm configure show | grep vip-with-primary
   ```

3. Monitor VIP placement:
   ```bash
   crm status | grep -E "postgres-vip|Promoted"
   ```

**No cluster restart required** - Pacemaker applies immediately.

### New Deployments

Update deployment scripts and documentation to include colocation constraint from the start.

## Summary

### What This Fix Does
✅ Ensures VIP **always** runs on same node as promoted PostgreSQL  
✅ Prevents connection failures after failover  
✅ Eliminates VIP placement randomness  
✅ Matches expected HA behavior  

### What This Fix Does NOT Do
❌ Change existing pgtwin code (configuration fix only)  
❌ Require cluster restart  
❌ Affect non-VIP deployments  

### Recommended Action

**ALL pgtwin users should add colocation constraint immediately**:

```bash
crm configure colocation vip-with-primary inf: postgres-vip postgres-clone:Promoted
```

This is a **production-critical fix** for any deployment using VIPs.

---

**Release**: pgtwin v1.6.16  
**Date**: 2025-12-28  
**Type**: Critical Bug Fix  
**Scope**: Cluster Configuration  
**Deployment**: Configuration change (no code update required)
