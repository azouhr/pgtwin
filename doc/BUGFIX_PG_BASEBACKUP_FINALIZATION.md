# Bug Fix: pg_basebackup Configuration Finalization

**Date**: 2025-12-03
**Severity**: CRITICAL
**Affects**: v1.6.0 - v1.6.5
**Fixed in**: v1.6.6 (unreleased)

---

## Summary

Fixed a critical bug where `pg_basebackup` recovery would create **broken standby configuration** with empty `primary_conninfo` values, preventing replication from working after recovery.

This bug affected:
- ✗ Automatic recovery via monitor function (v1.6 feature)
- ✗ Manual recovery via `pgsql_demote()`
- ✗ Manual disk replacement following MAINTENANCE_GUIDE.md

## Root Cause Analysis

### The Bug (pgtwin:2126-2152 in v1.6.5)

In `check_basebackup_progress()`, the code attempted to read configuration values from a file **AFTER** deleting it:

```bash
# Line 2129: Delete pid_file here
rm -f "${pid_file}" "${rc_file}"

if [ "$bb_rc" -eq 0 ]; then
    # Line 2146-2147: BUG! Tries to read from deleted pid_file
    local primary_host=$(grep "^primary=" "${pid_file}" | cut -d= -f2)  # ← RETURNS EMPTY!
    local rep_user=$(grep "^user=" "${pid_file}" | cut -d= -f2)        # ← RETURNS EMPTY!

    # Line 2149-2152: Creates BROKEN config with empty values
    cat > "${PGDATA}/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${primary_host} port=${OCF_RESKEY_pgport} user=${rep_user} ...'
EOF
}
```

**Result**: The `postgresql.auto.conf` would be created with:
```
primary_conninfo = 'host= port=5432 user= application_name=psql2 ...'
```

The standby would fail to connect to the primary because `host=` and `user=` were empty!

### Why pg_basebackup -R Wasn't Enough

The `pg_basebackup -R` flag creates a basic `postgresql.auto.conf`, but:
1. It doesn't know about pgtwin's cluster-specific `application_name`
2. It doesn't know about the custom `.pgpass` file location
3. The buggy code **overwrote** the pg_basebackup config with empty values

### Comparison: pg_rewind vs pg_basebackup

**pg_rewind (Lines 1954-1965)** - ✅ **WORKED CORRECTLY**:
- Used `primary_host` and `rep_user` from function parameters
- Created correct configuration

**pg_basebackup (Lines 2126-2152)** - ❌ **BROKEN**:
- Tried to read from deleted `${pid_file}`
- Created broken configuration with empty values

---

## The Fix

### 1. New Function: `finalize_standby_config()`

Created a unified function (pgtwin:1838-1912) that properly finalizes standby configuration:

```bash
finalize_standby_config() {
    local primary_host="$1"
    local rep_user="$2"
    local app_name=$(get_application_name)
    local pgpass_file=$(ensure_pgpass)

    # Validates parameters
    # Checks if PostgreSQL is running

    if pgsql_is_running; then
        # USE ALTER SYSTEM (fallback, less preferred)
        runuser -u postgres -- psql -c "ALTER SYSTEM SET primary_conninfo = ..."
        runuser -u postgres -- psql -c "SELECT pg_reload_conf()"
    else
        # DIRECT FILE UPDATE (preferred, PostgreSQL stopped)
        cat > "${PGDATA}/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${primary_host} port=${port} user=${rep_user} application_name=${app_name} ...'
primary_slot_name = '${slot_name}'
EOF
    fi

    # Ensure standby.signal exists
    touch "${PGDATA}/standby.signal"
}
```

**Key Features**:
- ✅ Prefers direct file update when PostgreSQL is stopped
- ✅ Falls back to ALTER SYSTEM if PostgreSQL is running
- ✅ Always ensures correct application_name
- ✅ Always ensures correct passfile location
- ✅ Sanitizes pg_basebackup -R generated config

### 2. Fixed `check_basebackup_progress()`

**BEFORE (BROKEN)**:
```bash
rm -f "${pid_file}" "${rc_file}"  # Delete first
# ...
local primary_host=$(grep "^primary=" "${pid_file}" | cut -d= -f2)  # EMPTY!
```

**AFTER (FIXED)**:
```bash
# Read values BEFORE deleting
local primary_host=$(grep "^primary=" "${pid_file}" | cut -d= -f2)
local rep_user=$(grep "^user=" "${pid_file}" | cut -d= -f2)

# Now safe to delete
rm -f "${pid_file}" "${rc_file}"

# Use finalize_standby_config() instead of manual config
finalize_standby_config "${primary_host}" "${rep_user}"
```

### 3. Updated `recover_standby()`

Replaced manual config creation after `pg_rewind` with:

```bash
finalize_standby_config "${primary_host}" "${rep_user}"
```

### 4. Added Safety Check in `pgsql_start()`

Added pre-flight check (pgtwin:1507-1540) that detects and auto-fixes broken standby configurations:

```bash
if [ -f "${PGDATA}/standby.signal" ]; then
    # Check for common issues:
    # 1. Empty host= or user= (bug #2063-2071)
    # 2. Missing application_name
    # 3. Wrong passfile location

    if config_looks_broken; then
        ocf_log warn "Detected potentially incorrect standby configuration - attempting to fix"

        local discovered_primary=$(discover_promoted_node)
        finalize_standby_config "${discovered_primary}" "${rep_user}"
    fi
fi
```

**This catches**:
- Manual `pg_basebackup` with incomplete config
- Corrupted `postgresql.auto.conf` from the bug
- Missing `application_name` or `passfile`

### 5. Updated MAINTENANCE_GUIDE.md

Added notes explaining that configuration finalization is **automatic**:

```bash
# NOTE: The pgtwin resource agent will automatically finalize the standby
# configuration when the node comes back online. It will ensure:
# - Correct application_name (cluster-specific)
# - Correct replication user
# - Correct passfile location
# - Correct primary_conninfo settings
# No manual configuration fixes are needed after pg_basebackup.
```

---

## Testing Recommendations

### Test Case 1: Automatic Recovery
```bash
# 1. Break replication on standby (simulate data corruption)
ssh root@psql2 "sudo rm -rf /var/lib/pgsql/data/pg_wal/*"

# 2. Wait for automatic recovery to trigger (monitor function)
crm_mon

# 3. Verify replication works after recovery
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# 4. Check postgresql.auto.conf has correct values
ssh root@psql2 "grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf"
# Should show: host=psql1 user=replicator application_name=<correct_value>
```

### Test Case 2: Manual Disk Replacement
```bash
# 1. Follow MAINTENANCE_GUIDE.md steps 1-5 (disk replacement with pg_basebackup)

# 2. Bring node back online
crm node online psql2

# 3. Verify configuration was auto-finalized
ssh root@psql2 "grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf"

# 4. Verify replication is working
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
```

### Test Case 3: Safety Check on Start
```bash
# 1. Manually create broken config (simulate the bug)
ssh root@psql2
cat > /var/lib/pgsql/data/postgresql.auto.conf <<EOF
primary_conninfo = 'host= port=5432 user= application_name=psql2'
EOF

# 2. Start the resource
crm node online psql2

# 3. Check logs - should show auto-fix
sudo journalctl -u pacemaker | grep "Auto-fixing standby config"

# 4. Verify config was fixed
grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf
```

---

## Impact Assessment

### Before Fix (v1.6.0 - v1.6.5)

❌ **Broken Scenarios**:
- Automatic recovery via monitor → standby fails to replicate
- Manual `pgsql_demote()` → standby fails to replicate
- Disk replacement via MAINTENANCE_GUIDE.md → standby fails to replicate

**Workaround**: Manually fix `postgresql.auto.conf` after recovery:
```bash
ssh root@psql2
sudo -u postgres psql -c "ALTER SYSTEM SET primary_conninfo = 'host=psql1 port=5432 user=replicator application_name=psql2 passfile=/var/lib/pgsql/.pgpass'"
sudo -u postgres psql -c "SELECT pg_reload_conf()"
```

### After Fix (v1.6.6+)

✅ **All Scenarios Work Automatically**:
- pg_rewind finalization → uses `finalize_standby_config()`
- pg_basebackup finalization → uses `finalize_standby_config()` (bug fixed)
- Manual pg_basebackup → auto-detected and fixed on start
- Corrupted config → auto-detected and fixed on start

---

## Files Changed

### pgtwin (Main Resource Agent)
- **Added**: `finalize_standby_config()` function (lines 1838-1912)
- **Fixed**: `check_basebackup_progress()` (lines 2126-2158) - read before delete
- **Updated**: `recover_standby()` (lines 1954-1963) - use finalize function
- **Added**: Safety check in `pgsql_start()` (lines 1507-1540)

### github/MAINTENANCE_GUIDE.md
- **Updated**: Step 3 - pg_basebackup for disk replacement (lines 105-111)
- **Updated**: pg_upgrade section - pg_basebackup note (lines 374-376)

---

## Lessons Learned

1. **Read before delete**: Always read file contents before `rm -f`
2. **Centralize configuration logic**: One function (`finalize_standby_config()`) for all scenarios
3. **Trust but verify**: pg_basebackup -R is good, but sanitize for cluster-specific needs
4. **Defensive programming**: Safety checks in `pgsql_start()` catch edge cases
5. **Test all recovery paths**: pg_rewind, pg_basebackup (async), pg_basebackup (manual)

---

## Version History

- **v1.6.0**: Introduced automatic recovery (introduced bug)
- **v1.6.1-v1.6.5**: Bug present, affects all pg_basebackup recovery
- **v1.6.6**: Bug fixed, finalization unified, safety checks added

---

## Related Issues

- Initial bug report: User discovered broken config after manual disk replacement
- Affects: Automatic recovery (v1.6), manual recovery, disk maintenance
- Severity: CRITICAL - cluster replication fails after recovery

---

## Upgrade Notes

### Upgrading from v1.6.0 - v1.6.5

1. **Install new resource agent**:
   ```bash
   sudo cp github/pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
   sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
   ```

2. **No cluster configuration changes needed**

3. **Test automatic recovery** (optional but recommended):
   ```bash
   # On standby, temporarily break replication
   ssh root@psql2 "sudo -u postgres psql -c 'SELECT pg_wal_replay_pause()'"

   # Wait for automatic recovery to trigger
   # Should complete successfully with proper config
   ```

4. **Verify after any recovery**:
   ```bash
   # Check replication status
   sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

   # Verify standby config
   ssh root@psql2 "grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf"
   ```

---

## Conclusion

This fix ensures that **all recovery paths** (pg_rewind, pg_basebackup automatic, pg_basebackup manual) create correct standby configurations with proper:
- Primary host discovery
- Replication user
- Application name (cluster-specific)
- Passfile location
- Replication slot name

The bug would have caused **100% replication failure** after any pg_basebackup-based recovery in affected versions. The fix includes both the bug correction and defensive safety checks to prevent similar issues in the future.
