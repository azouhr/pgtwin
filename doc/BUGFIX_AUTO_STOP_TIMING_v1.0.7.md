# Bug Fix: Auto-Stop Timing After Cutover (v1.0.7)

**Date:** 2026-01-05
**Component:** pgtwin-migrate
**Type:** Bug Fix
**Severity:** Medium - Causes restart loops if migration-state attribute deleted before monitor runs

---

## Summary

Fixed auto-stop timing issue where migration resource would get stuck in restart loops if the migration-state cluster attribute was deleted before the monitor function could execute the auto-stop command.

---

## Problem

### Restart Loop After Completed Migration

**Problem:**
- Migration completed successfully via `check_cutover_progress()`
- Function set `migration-state=CUTOVER_COMPLETE` cluster attribute
- Auto-stop logic existed but ran in `monitor` function (lines 3217-3231)
- If migration-state attribute was deleted before monitor ran, auto-stop never triggered
- Resource remained in `target-role=Started` state
- Pacemaker tried to restart the resource repeatedly
- Start function tried to recreate forward subscriptions (failed, migration already complete)

**Impact:**
- Failed Resource Actions accumulated in cluster status
- Resource stuck in Stopped state with infinite restart attempts
- Administrators had to manually stop the resource with `crm resource stop`
- Confusing post-migration state

**Root Cause:**
```bash
# In check_cutover_progress() - lines 2254-2263 (OLD)
crm_attribute -n migration-state -v "CUTOVER_COMPLETE"
rm -f "$cutover_state_file"
return 0  # ❌ No auto-stop here!

# In pgtwin_migrate_monitor() - lines 3217-3231 (OLD)
if [ "$current_state" = "CUTOVER_COMPLETE" ]; then
    # Auto-stop the migration resource
    crm_resource --meta --resource "$OCF_RESOURCE_INSTANCE" \
        --set-parameter target-role --parameter-value Stopped
    # ↑ This only runs IF migration-state attribute still exists
fi
```

**Race Condition:**
1. Cutover completes → Sets migration-state=CUTOVER_COMPLETE
2. Migration-state attribute gets deleted (manual cleanup or another process)
3. Next monitor cycle checks for CUTOVER_COMPLETE → Not found
4. Auto-stop never triggers
5. Resource stays in target-role=Started
6. Pacemaker keeps trying to restart the resource

---

## Solution Implemented

### Auto-Stop Immediately After Cutover Completion

**Location:** pgtwin-migrate lines 2263-2270

**Implementation:**
```bash
# In check_cutover_progress() - NEW behavior
# Clean up state file (resource-specific)
rm -f "$cutover_state_file"
ocf_log info "Cutover state file removed"

# Auto-stop the migration resource by setting target-role=Stopped
# This prevents the resource from restarting on cluster restarts
ocf_log info "Migration complete - setting target-role=Stopped to prevent restarts..."
crm_resource --meta --resource "$OCF_RESOURCE_INSTANCE" \
    --set-parameter target-role --parameter-value Stopped 2>&1 | \
    while IFS= read -r line; do ocf_log info "crm_resource: $line"; done

ocf_log info "Migration resource will stop on next monitor cycle (target-role=Stopped)"
ocf_log info "You can safely delete it later with: crm configure delete ${OCF_RESOURCE_INSTANCE}"

return 0
```

**Benefits:**
- ✅ Auto-stop executes **immediately** when cutover completes
- ✅ Runs **before** migration-state attribute can be deleted
- ✅ No dependency on cluster attribute persistence
- ✅ Eliminates race condition window

### Monitor Function as Safety Net

**Location:** pgtwin-migrate lines 3212-3239 (UPDATED)

**Implementation:**
```bash
# Check if cutover already completed (fast path)
local current_state=$(crm_attribute -G -n migration-state -q 2>/dev/null)
if [ "$current_state" = "CUTOVER_COMPLETE" ]; then
    ocf_log info "=========================================="
    ocf_log info "✓ MIGRATION COMPLETE (detected in monitor)"
    ocf_log info "=========================================="
    # ... status information ...

    ocf_log info "NOTE: This is a safety check - auto-stop should have triggered during cutover"

    # Auto-stop the migration resource by setting target-role=Stopped
    # This is a SAFETY NET in case check_cutover_progress() didn't run
    # (e.g., resource manually restarted after completion)
    ocf_log info "Safety: Setting migration resource target-role=Stopped..."
    crm_resource --meta --resource "$OCF_RESOURCE_INSTANCE" \
        --set-parameter target-role --parameter-value Stopped

    return $OCF_SUCCESS
fi
```

**Benefits:**
- ✅ Catches edge cases (manual restart, migration with older version)
- ✅ Updated log message clarifies this is a safety check
- ✅ Both locations now handle auto-stop reliably

---

## Testing

### Test 1: Normal Cutover Completion

```bash
# Trigger cutover
ssh root@pgtwin01 "crm_resource --meta --resource migration-forward \
    --set-parameter cutover_ready --parameter-value true"

# Monitor logs - should see auto-stop immediately after completion
ssh root@pgtwin01 "journalctl -u pacemaker -f | grep migration-forward"

# Expected:
# 1. Cutover completes
# 2. check_cutover_progress() detects completion
# 3. Immediately sets target-role=Stopped
# 4. Resource stops on next monitor cycle
# 5. NO restart attempts
```

### Test 2: Edge Case - Manual Restart After Completion

```bash
# Complete migration, then manually restart
ssh root@pgtwin01 "crm resource stop migration-forward"
ssh root@pgtwin01 "crm_attribute -n migration-state -v CUTOVER_COMPLETE"
ssh root@pgtwin01 "crm resource start migration-forward"

# Expected:
# 1. Start function detects CUTOVER_COMPLETE
# 2. Returns OCF_SUCCESS (doesn't re-run migration)
# 3. Monitor detects CUTOVER_COMPLETE
# 4. Safety net sets target-role=Stopped
# 5. Resource stops
```

### Test 3: Race Condition (Fixed)

```bash
# Simulate attribute deletion before monitor runs
# (This was the original bug scenario)

# After cutover completes:
ssh root@pgtwin01 "crm_attribute -D -n migration-state"

# Expected (with fix):
# 1. Cutover completed and ALREADY set target-role=Stopped
# 2. Attribute deletion doesn't matter
# 3. Resource stops cleanly
# 4. NO restart attempts

# Before fix would have:
# 1. Cutover completed, only set migration-state attribute
# 2. Attribute deletion prevents monitor auto-stop
# 3. Resource stays in Started state
# 4. Restart loop begins
```

---

## Deployment

```bash
# Deploy to all cluster nodes
for node in pgtwin01 pgtwin02 pgtwin11 pgtwin12; do
    scp pgtwin-migrate root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
    ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate"
done

# No resource refresh needed for future migrations
# For existing stuck resources, manually stop:
ssh root@pgtwin01 "crm resource stop migration-forward"
```

---

## Upgrade Notes

**From v1.0.6:**

1. **Deploy new version** to all nodes (see above)

2. **If migration already completed and stuck in restart loop:**
   - Manually stop the resource: `crm resource stop migration-forward`
   - Clear failed actions: `crm resource cleanup migration-forward`
   - Resource won't restart on next cluster boot (target-role=Stopped now set)

3. **No cluster reconfiguration needed** - changes are backward compatible

4. **Future migrations will auto-stop correctly** - no manual intervention needed

---

## Benefits

### For Administrators

- ✅ **No manual intervention** - Resource stops automatically when migration completes
- ✅ **No restart loops** - Resource won't try to restart after completion
- ✅ **Cleaner cluster status** - No failed actions after successful migration
- ✅ **Predictable behavior** - Auto-stop happens immediately, not on next monitor cycle

### For Operations

- ✅ **Reliable auto-stop** - Works even if cluster attributes deleted
- ✅ **No race conditions** - Auto-stop runs before attribute cleanup
- ✅ **Better diagnostics** - Clear log messages explain auto-stop execution
- ✅ **Safety net included** - Monitor function provides fallback auto-stop

### Technical

- ✅ **Immediate execution** - Auto-stop in check_cutover_progress(), not delayed to monitor
- ✅ **No external dependencies** - Doesn't rely on cluster attribute persistence
- ✅ **Defense in depth** - Two locations ensure auto-stop happens
- ✅ **Backward compatible** - Works with existing cluster configurations

---

## Related Issues

- **Original Issue:** Migration completed successfully, but resource kept trying to restart
- **Root Cause:** Auto-stop ran in monitor function, dependent on migration-state attribute
- **Solution:** Move auto-stop to check_cutover_progress(), execute immediately after completion

---

## Version History

- **v1.0.6:** Auto-stop in monitor function (timing issue)
- **v1.0.7:** Auto-stop immediately after cutover completion (this release)

---

## Code Locations

- **Primary auto-stop (NEW):** pgtwin-migrate lines 2263-2270 in `check_cutover_progress()`
- **Safety net auto-stop (UPDATED):** pgtwin-migrate lines 3224-3239 in `pgtwin_migrate_monitor()`
- **Log message clarification:** Added "Safety:" prefix to monitor auto-stop
