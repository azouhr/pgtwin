# Release Notes: pgtwin v1.6.5

**Release Date**: 2024-12-03
**Type**: Bug Fix Release
**Status**: Stable - Production Ready
**Severity**: High - Critical bug fix for synchronous replication

## Overview

Version 1.6.5 fixes a critical bug where synchronous replication would not activate even when properly configured with `rep_mode="sync"`. This bug caused clusters to silently operate in asynchronous mode, increasing the risk of data loss during failover.

**Upgrade Urgency**: **HIGH** for production clusters using `rep_mode="sync"`

## Critical Bug Fix

### Synchronous Replication Not Activating

**Problem**: When `rep_mode="sync"` was configured in Pacemaker, the cluster remained in asynchronous replication mode.

**Root Cause**: The `update_application_name_in_config()` function incorrectly set `synchronous_standby_names` to the **local node's hostname** instead of the standby node's name or a wildcard. This caused the primary to try synchronously replicating with itself (impossible), so PostgreSQL fell back to async mode.

**Affected Code**: `pgtwin` lines 337-352 (`update_application_name_in_config()`)

**Impact**:
- ✅ All v1.6.x users with `rep_mode="sync"` were affected
- ⚠️ Synchronous replication was silently disabled
- ⚠️ Increased data loss risk during failover
- ⚠️ Zero data loss guarantee was not being met

**Fix**:
- Changed `synchronous_standby_names` to use wildcard `'*'` (matches any standby)
- Simplified condition to only set when empty (respects user configuration)
- Prevents overriding explicit postgresql.conf/postgresql.custom.conf settings

**Verification**:
```bash
# After upgrade, verify synchronous replication is working:
sudo -u postgres psql -c "SHOW synchronous_standby_names;"
# Expected: *

sudo -u postgres psql -x -c "SELECT sync_state FROM pg_stat_replication;"
# Expected: sync_state | sync (NOT async)
```

## Documentation Improvements

### QUICKSTART.md Fixes

1. **Line 24**: Improved zypper command formatting
   - Before: `sudo zypper up (dup on Tumbleweed)`
   - After: `sudo zypper up   # or 'zypper dup' on Tumbleweed`

2. **Line 31**: Fixed grammar error
   - Before: "There seems an issue"
   - After: "There seems to be an issue"

### QUICKSTART_MANUAL_DEPLOYMENT.md Fixes

1. **Line 840**: Updated GitHub URL from placeholder
   - Before: `https://github.com/yourusername/pgtwin`
   - After: `https://github.com/azouhr/pgtwin`

2. **Line 847**: Fixed version number
   - Before: `**Version:** 1.0`
   - After: `**Version:** 1.6.5`

3. **Line 848**: Corrected release date
   - Before: `**Last Updated:** 2025-11-19` (future date)
   - After: `**Last Updated:** 2024-12-03`

## Upgrade Instructions

### For Clusters Using rep_mode="sync"

**CRITICAL**: Follow these steps immediately after upgrading to v1.6.5:

```bash
# 1. On both nodes, install new pgtwin agent
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# 2. On both nodes, clear incorrect postgresql.auto.conf setting
sudo -u postgres psql -c "ALTER SYSTEM RESET synchronous_standby_names;"
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# 3. On primary, verify synchronous_standby_names
sudo -u postgres psql -c "SHOW synchronous_standby_names;"
# Should show: *

# 4. On primary, verify replication mode
sudo -u postgres psql -x -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
# Should show: sync_state | sync

# 5. Test failover to ensure sync replication persists
crm resource move postgres-clone psql2
# Wait for failover
crm resource clear postgres-clone
# Verify sync_state is still 'sync' on new primary
```

### For Clusters Using rep_mode="async"

No immediate action required. The fix does not affect async clusters.

```bash
# Standard upgrade procedure:
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

## Compatibility

- ✅ **Backward Compatible**: No breaking changes
- ✅ **PostgreSQL**: All versions supported (tested with 17.x)
- ✅ **Pacemaker**: 2.x and 3.x compatible
- ✅ **Operating Systems**: openSUSE Tumbleweed, SUSE Linux Enterprise, RHEL, CentOS

## Files Changed

```
github/pgtwin                       # Lines 337-352 (bug fix)
github/QUICKSTART.md                # Lines 24, 31 (typo fixes)
QUICKSTART_MANUAL_DEPLOYMENT.md     # Lines 840, 847, 848 (documentation)
CHANGELOG.md                        # v1.6.5 entry added
```

## Testing

### Test Plan

1. **Synchronous Replication Activation**
   - ✅ Verified `synchronous_standby_names='*'` is set correctly
   - ✅ Verified `pg_stat_replication.sync_state='sync'`
   - ✅ Confirmed synchronous commit behavior (write blocks until standby confirms)

2. **Failover Testing**
   - ✅ Manual failover preserves sync replication mode
   - ✅ Automatic failover works correctly
   - ✅ VIP follows promoted node

3. **Configuration Persistence**
   - ✅ Setting persists across cluster restarts
   - ✅ User-configured values in postgresql.conf are respected
   - ✅ Only sets synchronous_standby_names when empty

4. **Regression Testing**
   - ✅ Async clusters unaffected
   - ✅ All existing features continue to work
   - ✅ No performance impact

## Known Issues

None.

## Next Steps

After upgrading to v1.6.5:

1. **Verify Synchronous Replication** - Confirm `sync_state='sync'` in `pg_stat_replication`
2. **Test Failover** - Ensure zero data loss during promotion
3. **Review Configuration** - Check that `postgresql.custom.conf` has `synchronous_standby_names='*'`
4. **Monitor Logs** - Watch for any configuration warnings in Pacemaker logs

## Support

For issues or questions:
- **GitHub Issues**: https://github.com/azouhr/pgtwin/issues
- **Documentation**: See README.md and QUICKSTART.md
- **Manual Recovery**: See MANUAL_RECOVERY_GUIDE.md

## Acknowledgments

Thanks to the community user who discovered and reported this critical synchronous replication bug during manual deployment testing.

---

**Version**: 1.6.5
**Previous Version**: 1.6.4
**Release Type**: Bug Fix
**Upgrade Priority**: HIGH (for sync clusters), LOW (for async clusters)
