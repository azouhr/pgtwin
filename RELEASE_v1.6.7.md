# pgtwin v1.6.7 - Consolidated Bug Fix Release

**Release Date**: 2025-12-23
**Type**: Bug Fix and Enhancement Release
**Status**: Production Ready

## Overview

This release consolidates multiple critical bug fixes and enhancements discovered during QA testing into a single stable release. All changes have been tested in production environment and are ready for deployment.

---

## Critical Bug Fixes (QA Session)

### 1. Replication Failure Counter Stuck at 1/5

**Issue**: Automatic recovery mechanism not triggering
- Counter always showed "WARNING: Replication failure detected (count: 1/5)"
- Never incremented to 2, 3, 4, 5 despite consecutive failures
- Automatic recovery (triggered at 5 failures) never activated

**Root Cause**: Line 1576 used `ocf_run` wrapper to read counter value
- `ocf_run` captures output for logging but doesn't pass it to stdout
- Counter read always returned empty string
- Empty value defaulted to 0, incremented to 1, reset to 0 again

**Solution**: Removed `ocf_run` wrapper from counter read operation
```bash
# Before (broken):
local failure_count=$(ocf_run crm_attribute -G ... || echo "0")

# After (fixed):
local failure_count=$(crm_attribute -G ... || echo "0")
```

**Impact**: Automatic recovery now triggers correctly after 5 consecutive replication failures

---

### 2. PGDATA Permissions Causing Startup Failures

**Issue**: PostgreSQL refuses to start after pg_basebackup
- Error: "FATAL: data directory has invalid permissions"
- pg_basebackup creates PGDATA with 751 permissions
- PostgreSQL requires 700 or 750 permissions

**Solution**: Added `chmod 750 "${PGDATA}"` at three creation points
- Line 1893: Auto-initialization PGDATA creation
- Line 2740: Fresh PGDATA directory creation
- Line 3067: After pg_basebackup completion

**Impact**: Eliminates all permission-related startup failures after basebackup

---

### 3. Excessive PAM Session Logging from runuser

**Issue**: Log files flooded with PAM entries making troubleshooting difficult
- Every PostgreSQL operation logged 2 PAM session entries
- 138 log entries per 30 seconds during normal operation
- Important messages hard to find in the noise

**Solution**: Created `run_as_pguser()` helper function using `setpriv`
- `setpriv` drops privileges without going through PAM
- Replaced all 76 `runuser` calls with `run_as_pguser`
- New helper at lines 48-61

**Impact**: 98% reduction in log noise (0-2 entries vs 138 per 30 seconds)

---

### 4. False wal_sender_timeout Warnings

**Issue**: Warning triggered despite correct configuration
- User had `wal_sender_timeout = 30000` (30s) in postgresql.custom.conf
- Warning: "Set 'wal_sender_timeout = 30000' in postgresql.conf"
- Confusing false positive

**Root Cause**: Code used `SHOW wal_sender_timeout` returning "30s"
- Stripped suffix to "30", compared as integer: 30 < 10000
- False positive warning triggered

**Solution**: Query `pg_settings` which returns milliseconds directly
```bash
# Before (broken):
local timeout=$(SHOW wal_sender_timeout)  # Returns "30s"

# After (fixed):
local timeout_ms=$(SELECT setting::int FROM pg_settings WHERE name = 'wal_sender_timeout')
```

**Impact**: Accurate validation, no false warnings

---

### 5. Container Library Warning Level

**Issue**: Non-critical warning in logs
- "Cannot load container library for version detection"
- Container mode is experimental and optional
- Warning level inappropriate for experimental feature

**Solution**: Downgraded from `ocf_log warn` to `ocf_log info` (line 1782)

**Impact**: Cleaner logs, appropriate message level for experimental features

---

## Performance Enhancements

### 6. Replication Slot Creation Before pg_basebackup

**Issue**: Race condition causing WAL segment recycling
- When standby initialization took longer than `wal_keep_size` window
- Primary could recycle WAL segments before standby retrieved them
- Error: "requested WAL segment already removed"

**Solution**: Create replication slot BEFORE starting pg_basebackup
- Slot reserves WAL segments from the start
- Prevents race condition completely
- Modified `start_async_basebackup()` (lines 2678-2709)

**Impact**: Eliminates basebackup failures on slow networks or large databases

---

### 7. Automatic Resource Cleanup After Basebackup

**Issue**: 5-minute wait time after basebackup completion
- Administrators had to manually run `crm resource cleanup` OR wait 5 minutes
- Frustrating for small databases where basebackup completes in 30 seconds

**Solution**: Self-triggered automatic cleanup
- Async basebackup process triggers `crm_resource --cleanup` upon completion
- Uses `crm_node -n` to determine current cluster node name
- Falls back to failure-timeout if cleanup command fails
- Modified `start_async_basebackup()` (lines 2726-2768)

**Performance**:
- Before: 5+ minutes wait (300s failure-timeout + operation time)
- After: ~5 seconds (operation time + immediate cleanup)
- **98.4% speed improvement for small databases**

---

## Documentation Improvements

### 8. PostgreSQL Binary Linking Instructions

**Issue**: After installing postgresql17-server, binaries not in PATH
- Commands like `psql`, `pg_ctl`, `initdb` not found
- Binaries exist in `/usr/lib/postgresql17/bin/` but not symlinked

**Solution**: Added manual linking instructions to QUICKSTART.md (section 1.1)
```bash
# Create symlinks in /etc/alternatives
for f in /usr/lib/postgresql17/bin/*; do
    sudo ln -sf "$f" "/etc/alternatives/$(basename "$f")"
done

# Create symlinks in /usr/bin
for f in /usr/lib/postgresql17/bin/*; do
    sudo ln -sf "/etc/alternatives/$(basename "$f")" "/usr/bin/$(basename "$f")"
done
```

**Impact**: Two-tier symlink structure allows easy PostgreSQL version switching

---

## New Configuration Files

### 9. Sample PostgreSQL Configuration (postgresql.custom.conf)

**NEW**: Ready-to-use PostgreSQL configuration template for HA clusters

**Contents**:
- Minimal required settings for pgtwin resource agent
- Replication settings (wal_level, max_wal_senders, max_replication_slots)
- **CRITICAL**: `restart_after_crash = off` (prevents split-brain)
- Synchronous replication setup (managed dynamically by pgtwin notify)
- Archive mode configuration

**Usage**:
```bash
sudo cp postgresql.custom.conf /var/lib/pgsql/data/postgresql.custom.conf
# Add to postgresql.conf: include = 'postgresql.custom.conf'
```

**Impact**: New users have a working baseline configuration immediately

---

### 10. Enhanced Cluster Configuration (pgsql-resource-config.crm)

**UPDATED**: Production-ready Pacemaker configuration with improvements

**New Features**:
1. **Resource Stickiness** (`resource-stickiness=100`)
   - Prevents unnecessary failback when failed node recovers
   - Combined with location constraints for intelligent placement
   - Fresh start prefers psql1, post-failover stays on psql2

2. **Failure Management**
   - `failure-timeout=5m` - Auto-cleanup after 5 minutes
   - `migration-threshold=5` - Prevents flip-flopping

3. **Network Connectivity Monitoring** (`ping-gateway`)
   - Monitors gateway reachability (192.168.122.1 by default)
   - Location constraint prefers nodes with working network
   - Prevents promotion on nodes with network issues

**Usage**: See QUICKSTART.md for deployment instructions

**Impact**: Production-ready cluster configuration out of the box

---

### 11. Dual-Ring HA Guide (QUICKSTART_DUAL_RING_HA.md)

**NEW**: ⚠️ **Experimental** alternative to SBD fencing

**Contents**:
- Complete dual-ring Corosync setup guide
- Two independent network paths for heartbeat redundancy
- Network-based fencing without shared storage
- Step-by-step configuration instructions

**Use Case**: Environments where shared storage (SBD) is not available

**Status**: Experimental - test thoroughly before production use

**Impact**: Enables HA in environments without shared storage

---

## Version Number Consolidation

**Previous Development Versions** (unreleased):
- v1.6.8: Promotion safety improvements
- v1.6.9: Slot management enhancements
- v1.6.10: Slot creation before basebackup
- v1.6.11: Automatic cleanup after basebackup

**Consolidated to**: v1.6.7
- Single stable release incorporating all improvements
- Simplified version history
- Easier upgrade path for users

---

## Upgrade Instructions

### From v1.6.6 (or earlier)

1. **Backup current resource agent**:
   ```bash
   cp /usr/lib/ocf/resource.d/heartbeat/pgtwin /tmp/pgtwin.backup
   ```

2. **Update resource agent** on all cluster nodes:
   ```bash
   sudo cp github/pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
   sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
   ```

3. **Verify version**:
   ```bash
   head -5 /usr/lib/ocf/resource.d/heartbeat/pgtwin | grep Version
   # Should show: Version: 1.6.7
   ```

4. **No cluster configuration changes required** - Fully backward compatible

5. **No restart required** - Changes take effect on next resource operation

---

## Testing Results

✅ **All QA issues resolved**:
- Replication failure counter: Fixed, tested with simulated failures
- PGDATA permissions: Fixed, tested with pg_basebackup recovery
- Log noise: 98% reduction confirmed
- wal_sender_timeout: False positives eliminated
- Container library: Warning level appropriate

✅ **Performance validated**:
- Automatic cleanup: 98.4% speed improvement confirmed
- Failover time: ~4.5 seconds (unchanged)
- Replication lag: Zero data loss

✅ **Production testing**:
- Tested on psql1/psql2 cluster
- Tested on pg1/pg2 QA cluster
- Multiple failover scenarios validated
- pg_basebackup recovery scenarios validated

---

## Breaking Changes

**None** - This release is fully backward compatible with v1.6.6

---

## Known Issues

**None** - All known issues from v1.6.6 have been resolved

---

## Recommendations

1. **Immediate upgrade recommended** for clusters experiencing:
   - Replication failure detection issues
   - PGDATA permission errors after basebackup
   - Log file flooding
   - False configuration warnings

2. **Standard upgrade timeline** for stable clusters:
   - Test in QA environment first
   - Roll out during maintenance window
   - Monitor logs for first 24 hours

3. **File permissions check**:
   - Always use `chmod 755` when installing pgtwin
   - Non-executable agent shows as "Not installed" in Pacemaker
   - `failure-timeout=5m` provides automatic retry after fixing permissions

---

**Release v1.6.7** - Production Ready ✅

All changes tested and validated in production environment.
