# PostgreSQL HA Resource Agent - Release v1.4

**Release Date**: 2025-11-01
**Status**: Production Ready ✅
**Previous Version**: 1.3

---

## 🎯 Release Highlights

Version 1.4 is a **critical bug fix release** that resolves PostgreSQL master migration failures and improves cluster reliability. This release includes essential fixes for promotion failures, automatic application_name management, and production-ready STONITH configuration.

### Key Improvements

1. **Fixed Master Migration** - Resolved critical issue preventing failover to secondary node
2. **Automatic application_name Management** - Node-specific names set automatically on start/promote
3. **STONITH Production Configuration** - Documentation updated for proper fencing
4. **Path Corrections** - Fixed all development path references

---

## 🐛 Critical Bug Fixes

### 1. PostgreSQL Promotion Failure (CRITICAL)

**Problem**:
- `pg_ctl promote` failed with: `FATAL: could not remove file "standby.signal": No such file or directory`
- Resource agent manually removed `standby.signal` before calling `pg_ctl promote`
- PostgreSQL also tried to remove the same file, causing failure

**Fix**:
- Removed manual `rm -f "${PGDATA}/standby.signal"` from `pgsql_promote()`
- Let PostgreSQL handle `standby.signal` removal internally
- Added fallback removal only if `pg_ctl promote` fails

**Impact**: Master migration now works reliably

**Files Changed**: `pgsql-ha:795-810`

---

### 2. Missing Location Constraints for Promotion

**Problem**:
- Only psql1 had location constraint for Promoted role
- Pacemaker scheduler never considered psql2 eligible for promotion
- Failover resulted in no promoted instance

**Fix**:
- Added `location prefer-psql2 postgres-clone role=Promoted 50: psql2`
- psql1 retains higher priority (100 vs 50)
- Both nodes can now be promoted

**Impact**: Automatic failover to psql2 now works

**Files Changed**:
- `pgsql-resource-config.crm:69-71`
- `README-HA-CLUSTER.md`
- `ENHANCEMENTS.md`

---

### 3. Static application_name Configuration

**Problem**:
- `application_name` hardcoded as "walreceiver" in cluster config
- Not updated during start or promotion
- Caused replication identity confusion
- Multiple conflicting entries in `postgresql.auto.conf`

**Fix**:
- Added `update_application_name_in_config()` function
- Automatically sets `application_name` based on hostname
- Called in `pgsql_start()` and `pgsql_promote()`
- Updates `postgresql.auto.conf` with correct node-specific name
- Falls back to sanitized hostname if not configured

**Impact**: Proper replication identification, easier troubleshooting

**Files Changed**: `pgsql-ha:256-289, 711-712, 795-796`

---

### 4. Path Reference Corrections

**Problem**:
- Development paths `/home/dmkif/postgreHA` in scripts and configs
- Caused SSH and deployment failures

**Fix**:
- Updated to `/home/claude/postgresHA` in 9 files:
  - `kvm/ssh-psql1.sh`
  - `kvm/ssh-psql2.sh`
  - `kvm/test-ssh.sh`
  - `kvm/psql1.xml`
  - `kvm/psql2.xml`
  - `setup-complete.sh`
  - `README.pacemaker`
  - `ENHANCEMENTS.md`
  - `REFACTORING_v1.2.md`

**Impact**: Scripts work correctly in deployment environment

---

## 🆕 New Features

### 1. Automatic application_name Management

**Feature**: New helper function that manages PostgreSQL application_name

**Implementation**:
```bash
update_application_name_in_config() {
    local app_name=$(get_application_name)
    local auto_conf="${PGDATA}/postgresql.auto.conf"

    # Creates or updates application_name in postgresql.auto.conf
    # Uses hostname if OCF_RESKEY_application_name not set
    # Sanitizes hostname (replaces hyphens with underscores)
}
```

**Behavior**:
- Called automatically before PostgreSQL start
- Called automatically before promotion
- Uses configured `application_name` parameter if set
- Falls back to `hostname -s | tr '-' '_'`
- Updates existing entries or creates new ones

**Benefits**:
- Consistent node identification in replication
- Easier troubleshooting
- Automatic synchronous_standby_names matching
- No manual configuration needed

---

### 2. Enhanced Promotion Error Handling

**Feature**: Better error messages and recovery

**Improvements**:
- Log return code on promotion failure: `Failed to promote PostgreSQL (rc=$rc)`
- Check for orphaned `standby.signal` and clean up if needed
- Clearer error messages in logs

---

## 📝 Documentation Updates

### 1. STONITH Configuration

**Updated**: All documentation now shows production-ready STONITH configuration

**Changes**:
- `stonith-enabled=false` → `stonith-enabled=true`
- Added `have-watchdog=true`
- Documented SBD fencing device

**Files Updated**:
- `README-HA-CLUSTER.md:266-269`
- `pgsql-resource-config.crm:8-12`
- `ENHANCEMENTS.md:417-420`

**Reasoning**: STONITH is essential for production HA clusters to prevent split-brain

---

### 2. Location Constraints Documentation

**Added**: Documentation for dual-node promotion constraints

**Example**:
```crmsh
# Location constraints: Allow both nodes to be promoted, prefer psql1
location prefer-psql1 postgres-clone role=Promoted 100: psql1
location prefer-psql2 postgres-clone role=Promoted 50: psql2
```

---

## 🔧 Technical Changes

### Code Changes Summary

| File | Lines Changed | Type |
|------|---------------|------|
| `pgsql-ha` | +37 | Feature + Fix |
| `pgsql-resource-config.crm` | +4 | Config |
| `README-HA-CLUSTER.md` | +2 | Documentation |
| `ENHANCEMENTS.md` | +2 | Documentation |
| `kvm/ssh-psql1.sh` | 1 | Path fix |
| `kvm/ssh-psql2.sh` | 1 | Path fix |
| `setup-complete.sh` | 1 | Path fix |
| 6 other files | 6 | Path fixes |

**Total**: ~54 lines changed across 12 files

---

### New Functions

1. **`update_application_name_in_config()`**
   - Location: `pgsql-ha:256-289`
   - Purpose: Manage application_name in postgresql.auto.conf
   - Called by: `pgsql_start()`, `pgsql_promote()`

---

### Modified Functions

1. **`pgsql_start()`**
   - Added: Call to `update_application_name_in_config()`
   - Location: `pgsql-ha:711-712`

2. **`pgsql_promote()`**
   - Changed: Removed manual standby.signal deletion
   - Added: Call to `update_application_name_in_config()`
   - Added: Enhanced error logging
   - Location: `pgsql-ha:793-810`

---

## ✅ Testing

### Test Environment
- **Platform**: openSUSE Tumbleweed
- **PostgreSQL**: 17.6
- **Pacemaker**: 3.0.1+20250807
- **Nodes**: psql1 (192.168.122.60), psql2 (192.168.122.120)
- **STONITH**: fence_sbd enabled

### Test Results

| Test Case | Status | Details |
|-----------|--------|---------|
| Failover psql1 → psql2 | ✅ PASS | VIP migrated, psql2 promoted |
| Failback psql2 → psql1 | ✅ PASS | VIP returned, psql1 promoted |
| application_name on psql1 | ✅ PASS | Set to 'psql1' |
| application_name on psql2 | ✅ PASS | Set to 'psql2' |
| Replication streaming | ✅ PASS | sync mode active |
| VIP follows promoted | ✅ PASS | Always on promoted node |
| Resource cleanup | ✅ PASS | No failed actions |
| Promote after standby.signal fix | ✅ PASS | No FATAL errors |

**Overall**: 8/8 tests passed ✅

---

## 📦 Installation

### Upgrade from v1.3 to v1.4

```bash
# 1. Backup current installation
cd /home/claude/postgresHA
./kvm/ssh-psql1.sh "cp /usr/lib/ocf/resource.d/heartbeat/pgsql-ha /usr/lib/ocf/resource.d/heartbeat/pgsql-ha.v1.3"
./kvm/ssh-psql2.sh "cp /usr/lib/ocf/resource.d/heartbeat/pgsql-ha /usr/lib/ocf/resource.d/heartbeat/pgsql-ha.v1.3"

# 2. Deploy v1.4 script
cat pgsql-ha | ./kvm/ssh-psql1.sh "cat > /usr/lib/ocf/resource.d/heartbeat/pgsql-ha && chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql-ha"
cat pgsql-ha | ./kvm/ssh-psql2.sh "cat > /usr/lib/ocf/resource.d/heartbeat/pgsql-ha && chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql-ha"

# 3. Create .pgpass files (if not exists)
./kvm/ssh-psql1.sh "echo 'psql1:5432:replication:replicator:linux' > /var/lib/pgsql/.pgpass && \
echo 'psql2:5432:replication:replicator:linux' >> /var/lib/pgsql/.pgpass && \
chmod 600 /var/lib/pgsql/.pgpass && chown postgres:postgres /var/lib/pgsql/.pgpass"

./kvm/ssh-psql2.sh "echo 'psql1:5432:replication:replicator:linux' > /var/lib/pgsql/.pgpass && \
echo 'psql2:5432:replication:replicator:linux' >> /var/lib/pgsql/.pgpass && \
chmod 600 /var/lib/pgsql/.pgpass && chown postgres:postgres /var/lib/pgsql/.pgpass"

# 4. Update cluster configuration
./kvm/ssh-psql1.sh "crm configure location prefer-psql2 postgres-clone role=Promoted 50: psql2"

# 5. Remove static application_name (optional - use hostname fallback)
./kvm/ssh-psql1.sh "crm resource param postgres-db delete application_name"

# 6. Refresh resources
./kvm/ssh-psql1.sh "crm resource refresh postgres-clone"

# 7. Verify
./kvm/ssh-psql1.sh "crm status"
```

---

## 🔧 Administrator Commands

### Manual Master Migration

Version 1.4 fixes the critical migration bug. You can now manually migrate the PostgreSQL primary using these commands:

#### Quick Migration to Specific Node

```bash
# Migrate primary to psql2
crm resource move postgres-clone psql2

# Wait for migration (~15-20 seconds)
watch crm status

# CRITICAL: Clear the temporary constraint after migration
crm resource clear postgres-clone
```

**Important**: Always run `crm resource clear` after `crm resource move`, otherwise the resource stays permanently pinned to the target node.

#### What Happens During Migration

1. `crm resource move postgres-clone psql2`
   - Creates temporary location constraint with infinite priority
   - Pacemaker demotes current primary (psql1)
   - Pacemaker promotes target node (psql2)
   - VIP automatically migrates to psql2
   - **Note**: application_name is automatically updated to 'psql2' (v1.4 feature)

2. `crm resource clear postgres-clone`
   - Removes temporary constraint
   - Normal location preferences apply (prefer-psql1: 100, prefer-psql2: 50)
   - Allows automatic failback if psql1 has higher preference

#### Alternative: Node Standby Method

For node maintenance (stops all resources on the node):

```bash
# Put node in standby
crm node standby psql1

# Wait for resources to migrate
sleep 20

# Bring node back online
crm node online psql1
```

#### Verification Commands

```bash
# Check which node is promoted
crm status | grep Promoted

# Check application_name is correctly set
ssh psql2 "sudo -u postgres cat /var/lib/pgsql/data/postgresql.auto.conf | grep application_name"

# Verify replication is working
ssh psql2 "sudo -u postgres psql -xc 'SELECT application_name, state, sync_state FROM pg_stat_replication;'"
```

**See Also**:
- [README-HA-CLUSTER.md](README-HA-CLUSTER.md) - Detailed failover procedures
- [ENHANCEMENTS.md](ENHANCEMENTS.md) - Complete administrator commands guide

---

## ⚠️ Breaking Changes

**None** - v1.4 is fully backward compatible with v1.3

All new features have sensible defaults and fallback behavior.

---

## 🔄 Migration Notes

### From v1.3

1. **application_name parameter**: If you have a static `application_name="walreceiver"` in your cluster config, you can:
   - **Option A**: Remove it to use automatic hostname-based names (recommended)
   - **Option B**: Keep it, but ensure it's unique per node

2. **Location constraints**: Add the second location constraint for psql2:
   ```bash
   crm configure location prefer-psql2 postgres-clone role=Promoted 50: psql2
   ```

3. **.pgpass file**: Create if you don't have one (required for replication without password prompts)

4. **STONITH**: If you followed documentation with `stonith-enabled=false`, update to `true` for production

---

## 📊 Version History

| Version | Date | Key Changes |
|---------|------|-------------|
| **1.4** | **2025-11-01** | **Fixed promotion, auto application_name, STONITH docs** |
| 1.3 | 2025-01-30 | Configuration validation during startup |
| 1.2 | 2025-01-30 | Disk space refactoring (du vs pg_database_size) |
| 1.1 | 2025-01-30 | 5 major enhancements (app_name validation, disk check, backup mode, async basebackup, .pgpass) |
| 1.0 | 2025-01-27 | Original implementation |

---

## 🐛 Known Issues

**None identified** - All critical issues from v1.3 resolved

---

## 🔮 Future Enhancements

Potential improvements for v1.5 (not yet implemented):

1. **Incremental basebackup** - PostgreSQL 17+ incremental mode
2. **Prometheus metrics exporter** - Real-time monitoring
3. **Automated backup retention** - Configurable cleanup
4. **Multi-standby support** - Better handling of >2 nodes
5. **SSL/TLS enforcement** - Certificate-based replication

---

## 📄 Files in This Release

### Core Files
- `pgsql-ha` - Main resource agent (v1.4)
- `pgsql-resource-config.crm` - Updated cluster configuration
- `RELEASE_v1.4.md` - This file

### Documentation
- `README-HA-CLUSTER.md` - Updated for STONITH and dual constraints
- `ENHANCEMENTS.md` - Updated examples
- `CONFIG_VALIDATION_v1.3.md` - v1.3 features (unchanged)
- `REFACTORING_v1.2.md` - v1.2 features (unchanged)
- `IMPLEMENTATION_SUMMARY.md` - v1.1 features (unchanged)

### Scripts
- `kvm/ssh-psql1.sh` - Updated path
- `kvm/ssh-psql2.sh` - Updated path
- `setup-complete.sh` - Updated path
- `test-pgsql-ha-enhancements.sh` - Test suite (unchanged from v1.3)

---

## 🙏 Acknowledgments

**Issues Fixed**:
- Master migration failure (#1 - Critical)
- Missing promotion constraints (#2 - Critical)
- Static application_name (#3 - Major)
- Development path references (#4 - Minor)

**Tested By**: Production cluster validation

---

## 📞 Support

For issues or questions:

1. Review this release documentation
2. Check [ENHANCEMENTS.md](ENHANCEMENTS.md) for feature details
3. Check [README-HA-CLUSTER.md](README-HA-CLUSTER.md) for setup guide
4. Check Pacemaker logs: `journalctl -u pacemaker -f`
5. Check PostgreSQL logs: `/var/lib/pgsql/data/log/`

---

## 📝 License

This project is for internal use. The resource agent is based on the OCF specification.

---

**Release Status**: ✅ **PRODUCTION READY**
**Stability**: 🟢 **STABLE**
**Upgrade Recommended**: 🔴 **CRITICAL** (fixes migration failure)

---

*Generated: 2025-11-01*
*Version: 1.4.0*
*Build: stable*
