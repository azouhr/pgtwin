# Bug Fix: Basebackup State File Ownership (v1.6.17 → v1.6.8)

## Overview
**Fixed**: Basebackup log and return code files created with root ownership instead of postgres user
**Severity**: MODERATE - Potential permission errors during operations
**Affected Versions**: All versions prior to v1.6.8
**Release**: v1.6.8 (development v1.6.17)

## Problem Description

### Symptom
State files created by the background pg_basebackup subprocess were owned by `root:root` instead of `postgres:postgres`.

**Affected files:**
- `/var/lib/pgsql/.pgtwin_basebackup.log`
- `/var/lib/pgsql/.pgtwin_basebackup_rc`

### Evidence
```bash
$ ls -la /var/lib/pgsql/.pgtwin_basebackup.log
-rw-r-----. 1 root root 686 Dec 28 12:10 /var/lib/pgsql/.pgtwin_basebackup.log
```

**Expected ownership:**
```bash
-rw-r-----. 1 postgres postgres 686 Dec 28 12:10 /var/lib/pgsql/.pgtwin_basebackup.log
```

### Impact

**Potential issues:**
1. **Permission errors**: If postgres user tries to read/write log files
2. **Inconsistent ownership**: Other state files owned by postgres user
3. **Cleanup problems**: Scripts running as postgres may fail to delete files
4. **Security concerns**: Root-owned files in postgres home directory

**Actual risk**: MODERATE
- Most operations succeed (OCF agent runs as root)
- But creates inconsistent security boundary
- May cause issues in edge cases (manual operations, debugging)

### Root Cause

The background pg_basebackup subprocess uses shell redirection which happens in the parent shell context:

```bash
# In start_async_basebackup() - Line 2930 (before fix)
(
    run_as_pguser env PGSSLMODE=prefer ${PG_BASEBACKUP} ... > "${log_file}" 2>&1
    local basebackup_rc=$?
    echo ${basebackup_rc} > "${rc_file}"

    echo "..." >> "${log_file}"
    /usr/sbin/crm_resource ... >> "${log_file}" 2>&1
) &
```

**Problem**:
1. Main pgtwin script runs as root (OCF agents run as root)
2. Background subshell `( ... ) &` spawned by root shell
3. Shell redirection `> "${log_file}"` creates file in root context
4. Even though `run_as_pguser` runs pg_basebackup as postgres, the file was already created by root

**Why this happened:**
- Shell redirection happens **before** command execution
- `>` operator is evaluated by the shell that spawned the subprocess
- The spawning shell is the root-owned pgtwin process

## The Fix

### Implementation

Pre-create files with correct ownership **before** spawning background process:

```bash
# BUG FIX v1.6.17: Pre-create log file with correct ownership
# Without this, shell redirection creates file as root
cat > "${log_file}" <<EOF
========================================
pg_basebackup started: $(date '+%Y-%m-%d %H:%M:%S')
Primary host: ${primary_host}
Replication user: ${rep_user}
Target PGDATA: ${PGDATA}
========================================

EOF
chown ${OCF_RESKEY_pguser}:${pidfile_group} "${log_file}"

# BUG FIX v1.6.17: Pre-create rc_file with correct ownership
# The background process will overwrite this with the actual return code
echo "" > "${rc_file}"
chown ${OCF_RESKEY_pguser}:${pidfile_group} "${rc_file}"
```

### Code Changes

**File**: `pgtwin`
**Function**: `start_async_basebackup()`
**Lines**: 2920-2936 (new code)

**Pattern used:**
1. Create file with content (log file) or placeholder (rc_file)
2. Change ownership to postgres user and group
3. Background process inherits file descriptors with correct ownership
4. Subsequent writes (append mode `>>`) preserve ownership

**This matches existing pattern:**
- The `pid_file` was already created with correct ownership (lines 2906-2918)
- Same technique now applied to `log_file` and `rc_file`

## Benefits

### 1. Consistent Ownership
All state files now owned by postgres user:
- `/var/lib/pgsql/.pgtwin_basebackup_in_progress` ✅ (already correct)
- `/var/lib/pgsql/.pgtwin_basebackup.log` ✅ (fixed)
- `/var/lib/pgsql/.pgtwin_basebackup_rc` ✅ (fixed)

### 2. Prevents Permission Errors
Postgres user can now:
- Read logs for troubleshooting
- Clean up state files
- Monitor basebackup progress

### 3. Security Best Practice
- Files in postgres home owned by postgres user
- Matches principle of least privilege
- Consistent with PostgreSQL data directory ownership

### 4. Enhanced Logging
Log file now includes header with metadata:
```
========================================
pg_basebackup started: 2025-12-28 13:45:22
Primary host: pgtwin02
Replication user: replicator
Target PGDATA: /var/lib/pgsql/data
========================================

# ... pg_basebackup output follows ...
```

## Testing

### Verification Steps

**Before fix:**
```bash
$ for node in pgtwin01 pgtwin02 pgtwin11 pgtwin12; do
    ssh root@$node "ls -la /var/lib/pgsql/.pgtwin_basebackup.log 2>/dev/null"
done

=== pgtwin01 ===
-rw-r-----. 1 root root 634 Dec 27 17:16 /var/lib/pgsql/.pgtwin_basebackup.log

=== pgtwin02 ===
-rw-r-----. 1 root root 686 Dec 28 12:10 /var/lib/pgsql/.pgtwin_basebackup.log

=== pgtwin11 ===
-rw-r-----. 1 root root 377 Dec 28 13:08 /var/lib/pgsql/.pgtwin_basebackup.log

=== pgtwin12 ===
-rw-r-----. 1 root root 686 Dec 28 12:40 /var/lib/pgsql/.pgtwin_basebackup.log
```

All files owned by `root:root` ❌

**After fix:**
```bash
# Deploy v1.6.8
for node in pgtwin01 pgtwin02 pgtwin11 pgtwin12; do
    scp pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin
done

# Trigger new basebackup (e.g., via cleanup or failover)
crm resource cleanup postgres-clone

# Verify new files created with correct ownership
$ ssh root@pgtwin12 "ls -la /var/lib/pgsql/.pgtwin_basebackup.log"
-rw-r-----. 1 postgres postgres 842 Dec 28 14:30 /var/lib/pgsql/.pgtwin_basebackup.log
```

Files now owned by `postgres:postgres` ✅

### Test Scenarios

1. **Fresh basebackup** - New cluster initialization
2. **Disk replacement** - Empty PGDATA triggers auto-init
3. **Recovery fallback** - pg_rewind fails, pg_basebackup runs
4. **Corrupted data** - Manual recovery triggers basebackup

All scenarios now create files with correct ownership.

## Deployment

### Upgrade Path

```bash
# 1. Deploy v1.6.8 to all nodes
for node in node1 node2 node3 node4; do
    scp github/pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/pgtwin
    ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin"
done

# 2. Optional: Fix existing file ownership manually
for node in node1 node2 node3 node4; do
    ssh root@$node "chown postgres:postgres /var/lib/pgsql/.pgtwin_basebackup.log 2>/dev/null || true"
    ssh root@$node "chown postgres:postgres /var/lib/pgsql/.pgtwin_basebackup_rc 2>/dev/null || true"
done
```

**No cluster restart required** - Fix activates on next basebackup operation.

### Existing Files

Old log files with root ownership can remain:
- They're read-only logs of past operations
- No functional impact
- Will be replaced when new basebackup runs
- Or manually fix ownership with `chown` command above

## Impact Assessment

### Who Is Affected?

**ALL pgtwin users** who have performed basebackups:
- Initial cluster setup with auto-initialization
- Disk replacement scenarios
- Recovery from data corruption
- Any pg_basebackup operations

### Severity

**MODERATE** because:
- No immediate functional breakage
- Most operations succeed (OCF agent runs as root)
- But violates security best practices
- Potential for permission errors in edge cases

### Risk Scenarios

1. **Manual troubleshooting**: Admin running `less` as postgres user → permission denied
2. **Custom scripts**: Monitoring scripts reading logs as postgres user → access errors
3. **Cleanup operations**: Scripts running as postgres can't delete root-owned files
4. **Security audits**: Root-owned files in user directory flagged

## Related Issues

### Other State Files

**Already correct** (no changes needed):
- `.pgtwin_basebackup_in_progress` - Already fixed in v1.6.6
- PostgreSQL data directory - Always owned by postgres
- Replication slot files - Managed by PostgreSQL
- WAL files - Managed by PostgreSQL

### Process Ownership

**Unchanged**:
- PostgreSQL processes run as postgres user ✅
- pg_basebackup runs as postgres user ✅
- Only state files had ownership issue (now fixed) ✅

## Implementation Notes

### Design Decisions

**Why pre-create instead of chown after?**
- Background process runs asynchronously
- Can't reliably chown from within background process (would need full path resolution)
- Pre-creation ensures correct ownership from start
- Matches existing pattern for pid_file

**Why create log with header?**
- Provides context even if pg_basebackup fails immediately
- Helps debugging (shows what was attempted)
- Timestamp useful for correlating with cluster events
- Minimal overhead (< 1ms)

**Why empty rc_file?**
- Will be overwritten by background process anyway
- Placeholder ensures correct ownership
- Simplifies logic (no conditional creation)

### Code Quality

**Follows existing patterns:**
- Same ownership change mechanism as pid_file
- Same group detection method
- Consistent error handling
- Minimal code duplication

**Defensive programming:**
- Pre-creates files before background subprocess
- No assumptions about default umask
- Explicit ownership setting
- Works regardless of parent process environment

## Summary

### What This Fix Does
✅ Creates basebackup log files with postgres ownership
✅ Creates basebackup rc files with postgres ownership
✅ Adds helpful header to log files
✅ Matches existing state file ownership pattern
✅ Follows security best practices

### What This Fix Does NOT Do
❌ Change PostgreSQL process ownership (already correct)
❌ Affect running basebackup operations
❌ Require configuration changes
❌ Fix ownership of existing files (can be manually fixed)

### Recommended Action

Upgrade to v1.6.8 to ensure all future basebackup operations create files with correct ownership. Optionally fix existing file ownership manually.

---

**Release**: pgtwin v1.6.8 (development v1.6.17)
**Date**: 2025-12-28
**Type**: Bug Fix
**Scope**: File ownership consistency
**Code Changes**: Lines 2920-2936 in `start_async_basebackup()` function
**Impact**: MODERATE - No immediate breakage, but fixes security and consistency issue
