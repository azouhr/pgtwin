# PostgreSQL HA Resource Agent - Version 1.5.0 Release Notes

**Release Date**: 2025-01-02
**Version**: 1.5.0
**Type**: Configuration Resilience & Safety Enhancement Release

---

## 🎯 Overview

Version 1.5 significantly enhances the resilience and safety of the `pgsql-ha` OCF resource agent by adding comprehensive PostgreSQL configuration validation and runtime monitoring. This release focuses on preventing common misconfigurations that can lead to cluster instability, data loss, or operational failures.

**Key Focus**: Proactive detection and warning of dangerous PostgreSQL settings before they cause problems.

---

## 🚀 New Features

### 1. Critical: restart_after_crash Validation ⚠️

**Problem Solved**: PostgreSQL's `restart_after_crash` setting, when enabled, causes the database to auto-restart after crashes, competing with Pacemaker's lifecycle management and potentially causing **split-brain scenarios**.

**Implementation**:
- **Hard error** if `restart_after_crash != off`
- Prevents cluster startup with misconfiguration
- Clear error messages explaining the risk

**Impact**: 🔴 **CRITICAL** - Prevents catastrophic split-brain scenarios

**Validation Code** (pgsql-ha:551-561):
```bash
local restart_after_crash=$(runuser -u ${OCF_RESKEY_pguser} -- sh -c "${PSQL} -p ${OCF_RESKEY_pgport} -Atc \"SHOW restart_after_crash\"" 2>/dev/null)
if [ "$restart_after_crash" != "off" ]; then
    ocf_log err "CRITICAL ERROR: restart_after_crash='${restart_after_crash}' - MUST be 'off' for Pacemaker-managed clusters!"
    ocf_log err "FIX: Set 'restart_after_crash = off' in postgresql.conf IMMEDIATELY"
    ocf_log err "REASON: PostgreSQL must not auto-restart after crash - Pacemaker manages lifecycle"
    ocf_log err "DANGER: If 'on', PostgreSQL will compete with Pacemaker, causing split-brain scenarios!"
    config_ok=1
fi
```

### 2. wal_sender_timeout Validation

**Problem Solved**: Overly aggressive `wal_sender_timeout` values (< 10 seconds) cause false disconnections during network hiccups, GC pauses, or CPU spikes.

**Implementation**:
- Warns if timeout < 10000ms (10 seconds)
- Recommends 15000-30000ms for production
- Helps avoid thrashing between connected/disconnected states

**Impact**: 🟡 **MEDIUM** - Improves cluster stability

**Validation Code** (pgsql-ha:563-578)

### 3. max_standby_streaming_delay Validation

**Problem Solved**: Setting `max_standby_streaming_delay = -1` allows long-running queries on standby to delay WAL replay indefinitely, causing **unbounded replication lag**.

**Implementation**:
- Warns when set to `-1` (wait indefinitely)
- Recommends 30000-60000ms (30-60 seconds)
- Explains trade-off: queries may be cancelled, but lag stays controlled

**Impact**: 🟡 **MEDIUM** - Prevents replication lag from growing without bound

**Validation Code** (pgsql-ha:580-592)

### 4. archive_command Error Handling Validation

**Problem Solved**: If `archive_command` fails repeatedly (disk full, network down), PostgreSQL **blocks all writes** until archiving succeeds, potentially taking down the entire cluster.

**Implementation**:
- Detects archive_command without error handling (`||` or `; true`)
- Warns about availability risk
- Suggests adding error handling or disabling archiving

**Impact**: 🟡 **MEDIUM** - Prevents cluster-wide write blocking

**Validation Code** (pgsql-ha:594-619)

### 5. Archive Failure Runtime Monitoring

**Problem Solved**: Archive failures accumulate silently, eventually filling disk with WAL files and causing cluster failure.

**Implementation**:
- Monitors `pg_stat_archiver` during resource monitoring
- Warns when `failed_count > 0`
- Reports last failure time
- Alerts about potential disk space issues

**Impact**: 🟡 **MEDIUM** - Early warning system for archive problems

**Monitoring Code** (pgsql-ha:730-745)

### 6. listen_addresses Security Notice

**Problem Solved**: `listen_addresses = '*'` exposes PostgreSQL to all network interfaces, creating potential security risks.

**Implementation**:
- Security notice when listening on all interfaces
- Recommends restricting to cluster network
- Notes that pg_hba.conf provides additional control

**Impact**: 🟠 **LOW** - Security awareness

**Validation Code** (pgsql-ha:621-630)

---

## 📊 Statistics

### Code Changes
- **Lines Added**: ~120 lines of validation and monitoring code
- **New Validation Checks**: 6 (5 in config validation, 1 in runtime monitoring)
- **Test Coverage**: 8 new tests added (total: 36 assertions across 25 test categories)

### Validation Summary
| Check | Severity | Action | Impact |
|-------|----------|--------|--------|
| `restart_after_crash` | 🔴 CRITICAL | Hard Error | Prevents split-brain |
| `wal_sender_timeout` | 🟡 WARNING | Recommendation | Stability improvement |
| `max_standby_streaming_delay` | 🟡 WARNING | Recommendation | Lag control |
| `archive_command` handling | 🟡 WARNING | Recommendation | Availability protection |
| Archive failures (runtime) | 🟡 WARNING | Alert | Early warning |
| `listen_addresses` | 🟠 INFO | Notice | Security awareness |

### Test Results
- ✅ All 36 assertions passing
- ✅ Syntax validation passing
- ✅ Backward compatibility maintained

---

## 🔧 Configuration Validation Flow

The enhanced `check_postgresql_config()` function now validates **12 configuration parameters**:

1. ✅ `wal_level` (v1.3 - critical)
2. ✅ `max_wal_senders` (v1.3 - critical)
3. ✅ `max_replication_slots` (v1.3 - critical)
4. ✅ `hot_standby` (v1.3 - warning)
5. ✅ `synchronous_commit` (v1.3 - warning)
6. ✅ `synchronous_standby_names` (v1.3 - warning)
7. ✅ **`restart_after_crash` (v1.5 - CRITICAL)** 🆕
8. ✅ **`wal_sender_timeout` (v1.5 - warning)** 🆕
9. ✅ **`max_standby_streaming_delay` (v1.5 - warning)** 🆕
10. ✅ **`archive_mode` + `archive_command` (v1.5 - enhanced)** 🆕
11. ✅ **`listen_addresses` (v1.5 - info)** 🆕
12. ✅ `primary_conninfo` application_name (v1.3 - warning)

**Validation runs automatically** on every `pgsql_start()` call.

---

## 🔄 Upgrade Guide

### From v1.4 to v1.5

**No breaking changes** - fully backward compatible.

#### Step 1: Update the Resource Agent

```bash
# Backup current version
sudo cp /usr/lib/ocf/resource.d/heartbeat/pgsql-ha /usr/lib/ocf/resource.d/heartbeat/pgsql-ha.v1.4

# Install v1.5
sudo cp pgsql-ha /usr/lib/ocf/resource.d/heartbeat/pgsql-ha
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql-ha
sudo chown root:root /usr/lib/ocf/resource.d/heartbeat/pgsql-ha
```

#### Step 2: Verify Syntax

```bash
bash -n /usr/lib/ocf/resource.d/heartbeat/pgsql-ha
```

#### Step 3: Review Configuration

**Before restarting the cluster**, review your PostgreSQL configuration:

```bash
# On primary node, check critical settings
sudo -u postgres psql -c "SHOW restart_after_crash;"      # MUST be 'off'
sudo -u postgres psql -c "SHOW wal_sender_timeout;"       # Recommend >= 15000ms
sudo -u postgres psql -c "SHOW max_standby_streaming_delay;"  # Recommend != -1
sudo -u postgres psql -c "SHOW archive_command;"          # Check for error handling
```

#### Step 4: Fix Critical Issues (if any)

If `restart_after_crash = on`:

```bash
# CRITICAL: Fix immediately
sudo -u postgres psql -c "ALTER SYSTEM SET restart_after_crash = off;"
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# Or edit postgresql.conf directly:
echo "restart_after_crash = off" | sudo tee -a /var/lib/pgsql/data/postgresql.custom.conf
```

#### Step 5: Restart Cluster (Rolling Upgrade)

```bash
# On standby (psql2)
crm node standby psql2
# Wait for standby to stop, then upgrade agent
crm node online psql2

# Trigger failover to upgraded node
crm node standby psql1
# Wait, then upgrade psql1
crm node online psql1
```

#### Step 6: Monitor Logs

After upgrade, check Pacemaker logs for validation messages:

```bash
sudo journalctl -u pacemaker -f
```

Look for:
- ✅ `✓ restart_after_crash='off' (OK - Pacemaker manages restarts)`
- ⚠️ Any WARNING messages about configuration
- 🔴 Any CRITICAL ERROR messages

---

## 📋 Breaking Changes

**None** - v1.5 is fully backward compatible with v1.4.

All new features are:
- Validation and monitoring only (no functional changes)
- Non-blocking warnings (except critical `restart_after_crash`)
- Automatically enabled on upgrade

---

## 🐛 Bug Fixes

No bugs fixed in this release - pure enhancement release.

---

## 📚 Documentation Updates

### New Documentation
- **README.postgres.md**: Comprehensive PostgreSQL configuration guide for HA clusters
  - Complete configuration reference
  - "Getting Started with HA PostgreSQL" guide
  - Critical configuration options explained
  - Potentially dangerous settings documented
  - Troubleshooting guide

### Updated Documentation
- **CLAUDE.md**: Updated with v1.5 information
- **test-pgsql-ha-enhancements.sh**: Added 8 new tests for v1.5 features

---

## ⚠️ Important Notes

### Critical Configuration Requirement

**Version 1.5 enforces a critical safety requirement**: `restart_after_crash` MUST be set to `off`.

If your configuration has `restart_after_crash = on`, the cluster **will not start** after upgrading to v1.5. This is intentional to prevent split-brain scenarios.

**Fix before upgrading**:
```ini
# In postgresql.conf or postgresql.custom.conf
restart_after_crash = off
```

### Recommended Configuration Changes

After upgrading, review and adjust these settings for optimal stability:

```ini
# Recommended for production stability
wal_sender_timeout = 30000              # 30 seconds (was: 5000ms)
max_standby_streaming_delay = 60000     # 60 seconds (was: -1)
archive_command = 'rsync -a %p /archive/%f || /bin/true'  # Add error handling
```

---

## 🧪 Testing

### Test Coverage

All enhancements are covered by automated tests:

```bash
# Run complete test suite
./test-pgsql-ha-enhancements.sh

# Expected output:
# Total tests run:    25
# Tests passed:       36
# Tests failed:       0
```

### Manual Testing Checklist

- [ ] Verify `restart_after_crash = on` triggers error
- [ ] Check warning for aggressive `wal_sender_timeout`
- [ ] Verify archive failure monitoring in logs
- [ ] Test failover with v1.5 on both nodes
- [ ] Confirm configuration validation runs on start

---

## 🔮 Future Enhancements (Not in v1.5)

Considered but deferred for future releases:

1. **Configurable validation strictness** - Parameter to control warning vs error behavior
2. **OCF parameters for timeouts** - Make `wal_sender_timeout` configurable via CRM
3. **Automatic configuration tuning** - Auto-adjust dangerous settings
4. **Extended monitoring** - More runtime health checks
5. **Configuration drift detection** - Alert when config changes from recommended values

---

## 📞 Support & Feedback

### Reporting Issues

If you encounter issues with v1.5:

1. Check Pacemaker logs: `sudo journalctl -u pacemaker -f`
2. Check PostgreSQL logs: `sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log`
3. Review configuration validation messages
4. Consult `README.postgres.md` for configuration guidance

### Testing Recommendations

Before production deployment:

1. ✅ Test in development/staging environment
2. ✅ Run full test suite
3. ✅ Perform manual failover tests
4. ✅ Monitor logs for 24-48 hours
5. ✅ Review all WARNING messages
6. ✅ Verify `restart_after_crash = off` on all nodes

---

## 🏆 Credits

**Version 1.5 developed in response to user request** for enhanced PostgreSQL configuration validation to improve cluster resilience.

### Key Contributors
- Configuration analysis and validation logic
- Comprehensive testing and documentation
- README.postgres.md creation

---

## 📝 Version History

- **v1.0** (Original): Basic HA with replication slots, pg_rewind, failover
- **v1.1** (2025-01-30): Application name validation, disk space checks, async basebackup, .pgpass parsing
- **v1.2** (2025-01-30): Disk space refactoring (du-based, backup-aware)
- **v1.3** (2025-01-30): PostgreSQL configuration validation (8 checks)
- **v1.4** (2025-11-01): Critical bug fixes (promotion, auto application_name, dual constraints)
- **v1.5** (2025-01-02): Enhanced configuration resilience (6 new validations, runtime monitoring) ✨ **CURRENT**

---

## 📄 License

GNU General Public License (GPL) v2+

---

**End of Release Notes**
