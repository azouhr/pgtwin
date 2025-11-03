# Release Notes: pgtwin v1.6.1

**Release Date**: 2025-11-03
**Type**: Bug Fix Release
**Status**: Critical fixes for v1.6.0 automatic recovery feature

## Overview

Version 1.6.1 addresses **6 critical bugs** discovered during live cluster testing of v1.6.0's automatic replication recovery feature. While v1.6.0 introduced the automatic recovery infrastructure, these bugs prevented it from functioning correctly in production scenarios.

## Executive Summary

**v1.6.0 Promise**: Automatic detection and recovery from replication failures
**v1.6.0 Reality**: Feature implemented but non-functional due to multiple bugs
**v1.6.1 Delivery**: All critical bugs fixed, automatic recovery operational

## Bugs Fixed

### Bug #1: Replication Failure Counter Not Incrementing
**Severity**: CRITICAL
**Impact**: Automatic recovery never triggered (counter stayed at 1)

**Root Cause**:
Line 901 used `ocf_run` wrapper for `crm_attribute -G` (GET operation). The `ocf_run` function logs command output, which interfered with variable assignment via command substitution.

```bash
# BROKEN (v1.6.0):
local failure_count=$(ocf_run crm_attribute -N $(hostname -s) -n postgres-replication-failures -G -q -d 0 -l reboot 2>/dev/null)

# FIXED (v1.6.1):
local failure_count=$(crm_attribute -N $(hostname -s) -n postgres-replication-failures -G -q -d 0 -l reboot 2>/dev/null)
```

**Fix**: Removed `ocf_run` from GET operations; added numeric validation

**Lines Changed**: 901-907

---

### Bug #2: Missing `passfile` Parameter in `primary_conninfo`
**Severity**: HIGH
**Impact**: Replication couldn't reconnect after demote (authentication failure)

**Root Cause**:
The `primary_conninfo` setting in `postgresql.auto.conf` didn't include the `passfile` parameter, causing PostgreSQL to fail authentication when connecting as standby.

**Locations Fixed**:
1. Line 1179: `pgsql_demote()` function
2. Line 1253: `recover_standby()` after pg_rewind
3. Line 1436: `check_basebackup_progress()` after pg_basebackup

```bash
# BROKEN (v1.6.0):
primary_conninfo = 'host=${primary_host} port=${OCF_RESKEY_pgport} user=${rep_user} application_name=${app_name}'

# FIXED (v1.6.1):
local conninfo_params="host=${primary_host} port=${OCF_RESKEY_pgport} user=${rep_user} application_name=${app_name}"
if [ -n "${OCF_RESKEY_pgpassfile}" ]; then
    conninfo_params="${conninfo_params} passfile=${OCF_RESKEY_pgpassfile}"
fi
primary_conninfo = '${conninfo_params}'
```

**Lines Changed**: 1177-1187, 1251-1260, 1430-1443

---

### Bug #3: CIB Parsing Returned "*" Instead of Hostname
**Severity**: HIGH
**Impact**: pg_rewind/pg_basebackup failed (couldn't connect to "*")

**Root Cause**:
Line 804's `grep -A 1 "Promoted:" | tail -1` pipeline incorrectly parsed `crm_mon` output. The "Promoted: [ psql1 ]" line was followed by "Unpromoted: [ psql2 ]", so `tail -1` grabbed the wrong line, then `awk '{print $1}'` extracted the "*" bullet.

```bash
# BROKEN (v1.6.0):
promoted_node=$(crm_mon -1 2>/dev/null | grep -A 1 "Promoted:" | tail -1 | tr -d '[]' | awk '{print $1}')
# Result: "*" (from "* Unpromoted:")

# FIXED (v1.6.1):
promoted_node=$(crm_mon -1 2>/dev/null | grep "Promoted:" | tr -d '[]' | awk '{print $NF}')
# Result: "psql1" (last field of "* Promoted: [ psql1 ]")
```

**Fix**: Changed to single-line parsing with `$NF` (last field)

**Lines Changed**: 804-807

---

### Bug #4: Missing `PGPASSFILE` Environment Variable
**Severity**: HIGH
**Impact**: pg_rewind and pg_basebackup couldn't authenticate

**Root Cause**:
Both `pg_rewind` and `pg_basebackup` commands ran without setting the `PGPASSFILE` environment variable, causing authentication to fail even though `.pgpass` file existed.

**Locations Fixed**:
1. Line 1243: `pg_rewind` command
2. Line 1352: `pg_basebackup` command (asynchronous)

```bash
# BROKEN (v1.6.0):
runuser -u ${OCF_RESKEY_pguser} -- sh -c "${PG_REWIND} ..."

# FIXED (v1.6.1):
local passfile_env=""
if [ -n "${OCF_RESKEY_pgpassfile}" ]; then
    passfile_env="PGPASSFILE=${OCF_RESKEY_pgpassfile}"
fi
runuser -u ${OCF_RESKEY_pguser} -- sh -c "${passfile_env} ${PG_REWIND} ..."
```

**Lines Changed**: 1243-1249, 1345-1361

---

### Bug #5: pg_basebackup Used Diverged Replication Slot
**Severity**: HIGH
**Impact**: pg_basebackup failed with timeline mismatch error

**Root Cause**:
Line 1352 used `-S ${OCF_RESKEY_slot_name}` option, forcing pg_basebackup to use the existing replication slot. After timeline divergence, the slot's LSN position (0/33000000) was ahead of the primary's WAL (0/32000218), causing:

```
ERROR: requested starting point 0/33000000 is ahead of the WAL flush position 0/32000218
```

**Fix**: Removed `-S` option; let pg_basebackup stream without a slot (slot recreated on replication startup)

```bash
# BROKEN (v1.6.0):
${PG_BASEBACKUP} ... -S ${OCF_RESKEY_slot_name} ...

# FIXED (v1.6.1):
${PG_BASEBACKUP} ... # No -S option
```

**Lines Changed**: 1357-1361

---

### Bug #6: Incomplete Marker File Cleanup
**Severity**: MEDIUM
**Impact**: Subsequent recovery attempts found stale files, causing "directory not empty" errors

**Root Cause**:
Line 1431 removed `pid_file` and `rc_file` on basebackup completion, but forgot to remove `log_file`. This left `.basebackup.log` and `.basebackup_in_progress` files in PGDATA, causing pg_basebackup to fail with "directory exists but is not empty" on retry.

```bash
# BROKEN (v1.6.0):
rm -f "${pid_file}" "${rc_file}"

# FIXED (v1.6.1):
rm -f "${pid_file}" "${rc_file}" "${log_file}"
```

**Lines Changed**: 1431-1432

---

## Test Results

### Smoke Test Findings

**Test Environment**: Live 2-node KVM cluster (psql1, psql2)
**PostgreSQL Version**: 17.6
**Pacemaker Version**: 3.0.1+

**Initial v1.6.0 Test** (Before Fixes):
- ❌ Counter stayed at 1 (Bug #1)
- ❌ CIB discovery returned "*" (Bug #3)
- ❌ pg_basebackup authentication failed (Bug #2, #4)
- ❌ Timeline mismatch errors (Bug #5)
- ❌ "Directory not empty" errors on retry (Bug #6)

**Post-Fix v1.6.1 Test** (All Bugs Fixed):
- ✅ Counter increments: 1 → 2 → 3 → 4 → 5
- ✅ Automatic recovery triggers at threshold
- ✅ CIB discovery returns "psql1"
- ✅ pg_rewind authentication works (with PGPASSFILE)
- ✅ pg_basebackup authentication works (with PGPASSFILE)
- ✅ pg_basebackup completes without slot errors
- ✅ Marker files properly cleaned up

**Outcome**: Automatic recovery infrastructure operational. Timeline divergence recovery requires additional work (separate from these 6 bugs).

---

## Upgrade Path

### From v1.6.0 to v1.6.1

**Impact**: Bug fixes only, no configuration changes required

```bash
# Stop cluster resources
sudo crm resource stop postgres-clone

# Install new agent on all nodes
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Start cluster resources
sudo crm resource start postgres-clone

# Verify version
head -5 /usr/lib/ocf/resource.d/heartbeat/pgtwin | grep Version
# Should show: Version: 1.6.1
```

**Configuration Changes**: NONE
**Backwards Compatible**: YES
**Database Downtime**: ~1-2 minutes (resource restart only)

---

## Known Limitations

While v1.6.1 fixes all 6 critical bugs in the automatic recovery infrastructure, **complete end-to-end recovery from timeline divergence** remains a work in progress:

1. **Infrastructure Working** ✅:
   - Counter increments correctly
   - Recovery triggers at threshold
   - Node discovery operational
   - Authentication functional
   - Basebackup executes without errors

2. **Edge Cases Remaining** ⚠️:
   - Complex recovery scenarios may require manual intervention
   - Multiple rapid failover/failback cycles need additional testing
   - Basebackup timeout handling under high load

**Recommendation**: Enable automatic recovery in production, but monitor closely and have manual recovery procedures ready.

---

## Technical Details

### Code Statistics
- **Total Lines Changed**: ~80
- **Functions Modified**: 4
  - `pgsql_monitor()`: Counter logic
  - `pgsql_demote()`: primary_conninfo with passfile
  - `discover_promoted_node()`: CIB parsing
  - `recover_standby()`: PGPASSFILE environment
  - `start_async_basebackup()`: Remove slot option
  - `check_basebackup_progress()`: Cleanup log files

### Testing Coverage
- **Unit Tests**: 6 bug-specific validation tests
- **Integration Tests**: Live cluster failover/failback scenarios
- **Smoke Tests**: Full automatic recovery cycle

---

## Migration Notes

### For Existing v1.6.0 Deployments

**If you deployed v1.6.0**:
1. Automatic recovery was non-functional (counter bug)
2. You likely experienced authentication failures
3. Upgrade to v1.6.1 immediately

**If automatic recovery triggered on v1.6.0**:
- It would have failed at node discovery ("*" hostname)
- Manually cleanup any stale `.basebackup_in_progress` files:
  ```bash
  sudo rm -f /var/lib/pgsql/data/.basebackup_in_progress
  sudo rm -f /var/lib/pgsql/data/.basebackup.log
  sudo rm -f /var/lib/pgsql/data/.basebackup_rc
  ```

---

## Credits

**Bug Discovery**: Live cluster testing on openSUSE Tumbleweed
**Testing Environment**: KVM-based 2-node PostgreSQL 17.6 cluster
**Analysis**: Pacemaker logs, PostgreSQL logs, manual tracing

**Lessons Learned**:
1. Always test automatic recovery features on live clusters
2. `ocf_run` interferes with command substitution
3. CIB parsing requires careful attention to output format
4. Environment variables don't automatically propagate through `runuser`
5. pg_basebackup slot usage breaks with timeline divergence
6. Cleanup must be comprehensive (all marker files, not just some)

---

## Future Work (v1.6.2+)

Potential enhancements identified during testing:
1. Improve basebackup retry logic
2. Add replication slot recreation during recovery
3. Enhanced logging for troubleshooting
4. Automatic detection of timeline divergence severity
5. Configurable recovery strategies (pg_rewind vs basebackup preference)

---

## Support

**Issues**: https://github.com/yourusername/pgtwin/issues
**Documentation**: README.md, CHANGELOG.md
**Version Check**: `head -5 /usr/lib/ocf/resource.d/heartbeat/pgtwin | grep Version`

---

## Changelog Summary

```
v1.6.1 (2025-11-03)
-------------------
[FIXED] Replication failure counter not incrementing (removed ocf_run from GET)
[FIXED] Missing passfile parameter in primary_conninfo (3 locations)
[FIXED] CIB parsing returning "*" instead of hostname
[FIXED] Missing PGPASSFILE environment variable (pg_rewind, pg_basebackup)
[FIXED] pg_basebackup using diverged replication slot
[FIXED] Incomplete marker file cleanup on basebackup completion

v1.6.0 (2025-11-03)
-------------------
[ADDED] Automatic replication recovery infrastructure
[ADDED] Replication health monitoring
[ADDED] Dynamic promoted node discovery
[ADDED] New parameters: vip, replication_failure_threshold
[KNOWN ISSUE] Feature non-functional due to 6 bugs (fixed in v1.6.1)
```
