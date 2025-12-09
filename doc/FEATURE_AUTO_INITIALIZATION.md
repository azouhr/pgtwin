# Feature: Automatic Standby Initialization

**Version**: v1.6.6 (unreleased)
**Date**: 2025-12-03
**Type**: New Feature

---

## Overview

The pgtwin resource agent now **automatically initializes standby nodes** with empty or missing PGDATA directories. This dramatically simplifies cluster deployment, node recovery, and disk replacement operations.

**Before**: Manual `pg_basebackup` required
**After**: Just empty the directory and bring the node online

---

## How It Works

When pgtwin starts on a node with empty/missing/invalid PGDATA:

1. **Detects** empty PGDATA (missing directory, empty directory, or missing `PG_VERSION`)
2. **Discovers** the primary node automatically from Pacemaker cluster state
3. **Retrieves** replication credentials from `.pgpass` file
4. **Validates** sufficient disk space for full basebackup
5. **Executes** `pg_basebackup` asynchronously in background
6. **Monitors** progress via monitor function
7. **Finalizes** standby configuration with correct `application_name` and settings
8. **Starts** PostgreSQL when basebackup completes

All of this happens **automatically** with no manual intervention required.

---

## Prerequisites

### Required

✅ **`.pgpass` file configured** with replication credentials:
```bash
# /var/lib/pgsql/.pgpass (mode 0600, owned by postgres)
psql1:5432:replication:replicator:SecurePassword123
psql2:5432:replication:replicator:SecurePassword123
```

✅ **Primary node running** and discoverable via Pacemaker

✅ **Sufficient disk space** (at least 2× current primary data size if backup mode enabled)

### Optional

- Cluster configuration with proper replication slot name
- Network connectivity between nodes
- Firewall rules allowing PostgreSQL replication

---

## Usage Scenarios

### Scenario 1: Fresh Node Deployment

**Problem**: New node needs to join cluster
**Solution**: Just create empty PGDATA and start

```bash
# On new node (psql2)
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# Create .pgpass with replication credentials
sudo -u postgres cat > /var/lib/pgsql/.pgpass <<EOF
psql1:5432:replication:replicator:password123
psql2:5432:replication:replicator:password123
EOF
sudo chmod 600 /var/lib/pgsql/.pgpass

# Bring node online - pgtwin does the rest
crm node online psql2

# Monitor progress
crm_mon
# Watch: /var/lib/pgsql/data/.basebackup.log
```

**Result**: Node automatically initializes and joins cluster as standby

---

### Scenario 2: Disk Replacement

**Problem**: Need to replace data disk on standby node
**Solution**: Mount new disk and bring node online

```bash
# Put node in standby
crm node standby psql2

# Replace disk (mount at /var/lib/pgsql/data)
# ... disk replacement procedure ...

# Verify .pgpass still exists (should be on separate volume)
ls -l /var/lib/pgsql/.pgpass

# Bring node back online
crm node online psql2

# pgtwin automatically:
# - Detects empty PGDATA
# - Discovers primary (psql1)
# - Runs pg_basebackup
# - Configures replication
# - Starts PostgreSQL
```

**Duration**: 5-60 minutes depending on database size
**Manual steps**: 3 commands
**Before this feature**: 8+ commands including manual pg_basebackup

---

### Scenario 3: Corrupted Data Recovery

**Problem**: Standby data directory corrupted
**Solution**: Delete corrupted data and restart

```bash
# Put node in standby
crm node standby psql2

# Remove corrupted data
ssh root@psql2 "sudo rm -rf /var/lib/pgsql/data/*"

# Bring node back online
crm node online psql2

# Automatic recovery starts immediately
```

---

### Scenario 4: Clone Failed Node

**Problem**: Node failed completely, need to rebuild
**Solution**: Install OS, configure .pgpass, start cluster

```bash
# On fresh OS installation
# 1. Install PostgreSQL and cluster software
sudo zypper install postgresql17 postgresql17-server pacemaker corosync

# 2. Configure .pgpass
sudo -u postgres cat > /var/lib/pgsql/.pgpass <<EOF
psql1:5432:replication:replicator:password123
EOF
sudo chmod 600 /var/lib/pgsql/.pgpass

# 3. Join Pacemaker cluster
# ... standard cluster join procedure ...

# 4. That's it! PGDATA will be auto-initialized on first start
```

---

## Technical Details

### Detection Logic (`is_valid_pgdata()`)

Checks three conditions:
1. **Directory exists**: `/var/lib/pgsql/data` exists
2. **Not empty**: Directory contains files
3. **Has PG_VERSION**: File present (indicates valid PostgreSQL cluster)

If **any** condition fails → triggers auto-initialization

### Validation Changes (`pgsql_validate()`)

**Before (v1.6.5 and earlier)**:
```bash
if [ ! -d "${PGDATA}" ]; then
    ocf_log err "PostgreSQL data directory does not exist"
    return $OCF_ERR_INSTALLED  # FATAL ERROR
fi
```

**After (v1.6.6)**:
```bash
if [ ! -d "${PGDATA}" ]; then
    ocf_log info "PGDATA does not exist - will be auto-initialized on start"
    mkdir -p "${PGDATA}"  # Create with correct permissions
    return $OCF_SUCCESS   # NOT AN ERROR
fi
```

### Start Logic Flow

```
pgsql_start()
  ├─ Is PostgreSQL running?
  │  └─ Yes → return OCF_SUCCESS
  │
  ├─ Is basebackup in progress?
  │  └─ Yes → check progress, return OCF_NOT_RUNNING
  │
  ├─ Is PGDATA valid?
  │  └─ No (empty/missing/invalid) →
  │       ├─ Ensure .pgpass exists
  │       ├─ Discover primary node
  │       ├─ Get replication user
  │       ├─ Check disk space
  │       ├─ Create empty PGDATA
  │       ├─ Start async pg_basebackup
  │       └─ Return OCF_NOT_RUNNING
  │
  └─ Normal start flow
     ├─ Check standby.signal
     ├─ Validate/fix configuration
     ├─ Start PostgreSQL
     └─ Wait for ready
```

### Monitor Integration

The `pgsql_monitor()` function already handles basebackup in progress:

```bash
pgsql_monitor()
  ├─ Basebackup in progress?
  │  └─ Yes →
  │       ├─ Check progress
  │       ├─ Log status
  │       └─ Return OCF_NOT_RUNNING
  │
  └─ Normal monitoring flow
```

**Progress tracking**:
- Status: `${PGDATA}/.basebackup_in_progress`
- Log: `${PGDATA}/.basebackup.log`
- Result: `${PGDATA}/.basebackup_rc`

---

## Error Handling

### Error: .pgpass not configured

```
Cannot initialize standby: .pgpass file not configured or invalid
Please create /var/lib/pgsql/.pgpass with replication credentials
```

**Solution**: Create `.pgpass` file with correct format and permissions

### Error: Cannot discover primary

```
Cannot initialize standby: unable to discover primary node from cluster
Ensure the primary node is running and promoted
```

**Solution**: Verify primary node is running and promoted in Pacemaker

### Error: Insufficient disk space

```
Cannot initialize standby: insufficient disk space for pg_basebackup
```

**Solution**: Free up disk space or increase disk size

### Error: Basebackup timeout

```
pg_basebackup timeout after 3600s (limit: 3600s), killing process
```

**Solution**: Increase `basebackup_timeout` parameter or check network/disk performance

---

## Configuration Parameters

Auto-initialization respects all existing parameters:

| Parameter | Effect on Auto-Init |
|-----------|---------------------|
| `pgpassfile` | Location of credentials file (required) |
| `slot_name` | Replication slot to use |
| `backup_before_basebackup` | If true, preserves corrupted data in backup directory |
| `basebackup_timeout` | Maximum time for pg_basebackup (default: 3600s) |
| `application_name` | Used in finalized standby configuration |

**No new parameters needed** - works with existing configuration.

---

## Logging and Monitoring

### Pacemaker Logs

```bash
# Monitor cluster events
sudo journalctl -u pacemaker -f

# Example log sequence:
# "PGDATA is empty or invalid - triggering automatic standby initialization"
# "Auto-initializing standby from primary: psql1 (user: replicator)"
# "Automatic standby initialization started (pg_basebackup running in background)"
# "Basebackup in progress: 1234/5678 (elapsed: 120s)"
# "Asynchronous pg_basebackup completed successfully after 456s"
# "PostgreSQL started successfully"
```

### Basebackup Progress

```bash
# Real-time progress
tail -f /var/lib/pgsql/data/.basebackup.log

# Check if in progress
ls -l /var/lib/pgsql/data/.basebackup_in_progress

# Check result (after completion)
cat /var/lib/pgsql/data/.basebackup_rc
```

### Cluster Status

```bash
# Watch cluster state
crm_mon

# Expected states during auto-init:
# 1. OCF_NOT_RUNNING (basebackup starting)
# 2. OCF_NOT_RUNNING (basebackup in progress)
# 3. OCF_SUCCESS (PostgreSQL started as standby)
```

---

## Safety Considerations

### 1. Never Initializes Primary

Auto-initialization only triggers on **unpromoted nodes** with empty PGDATA. The primary node's data is never touched.

### 2. Requires .pgpass

Won't proceed without valid `.pgpass` file. This prevents accidental initialization with wrong credentials.

### 3. Disk Space Check

Validates sufficient disk space before starting basebackup. Prevents running out of space mid-copy.

### 4. Backup Mode Respected

If `backup_before_basebackup=true`, any existing data is preserved in timestamped backup directory.

### 5. Async Operation

Basebackup runs in background to avoid Pacemaker monitor timeouts. Resource stays in `OCF_NOT_RUNNING` state until complete.

### 6. Idempotent

If basebackup is already in progress (from previous start attempt), just checks progress instead of starting new one.

---

## Performance Characteristics

### Initialization Time

| Database Size | Network | Disk | Estimated Time |
|---------------|---------|------|----------------|
| 1 GB | 1 Gbps | SSD | 1-2 minutes |
| 10 GB | 1 Gbps | SSD | 5-10 minutes |
| 100 GB | 1 Gbps | SSD | 30-60 minutes |
| 1 TB | 1 Gbps | SSD | 4-8 hours |
| 1 TB | 10 Gbps | NVMe | 30-60 minutes |

**Factors**:
- Primary database size
- Network bandwidth
- Disk I/O performance
- WAL generation rate on primary
- Compression (if enabled)

### Resource Impact

**On Primary**:
- CPU: Low (pg_basebackup reads existing files)
- Disk I/O: Medium (sequential reads)
- Network: High (streaming entire database)

**On Standby**:
- CPU: Low
- Disk I/O: High (writing entire database)
- Network: High (receiving entire database)

**Recommendation**: Schedule during low-traffic periods for large databases

---

## Comparison: Before vs After

### Before (v1.6.5 and earlier)

```bash
# Disk replacement procedure (10+ steps)
crm node standby psql2
ssh root@psql2
sudo mkdir -p /mnt/pgdata-new
sudo mount /dev/sdc1 /mnt/pgdata-new
sudo chown postgres:postgres /mnt/pgdata-new
sudo chmod 700 /mnt/pgdata-new
sudo rm -rf /mnt/pgdata-new/*
sudo -u postgres pg_basebackup \
    -h psql1 \
    -U replicator \
    -D /mnt/pgdata-new \
    -X stream \
    -P \
    -R \
    -S ha_slot
sudo umount /mnt/pgdata-new
sudo vi /etc/fstab  # Update UUID
sudo umount /var/lib/pgsql/data
sudo mount /var/lib/pgsql/data
crm node online psql2

# Manual verification needed:
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf
```

### After (v1.6.6)

```bash
# Disk replacement procedure (3 steps)
crm node standby psql2
# Mount new disk at /var/lib/pgsql/data
crm node online psql2

# That's it! Auto-initialization handles everything:
# - pg_basebackup
# - Configuration finalization
# - PostgreSQL start
# - Replication setup
```

**Reduction**: 10+ steps → 3 steps
**Time saved**: 5-10 minutes manual work
**Error potential**: Significantly reduced
**Expertise required**: Basic → Minimal

---

## Troubleshooting

### Problem: Auto-initialization not starting

**Check**:
```bash
# 1. PGDATA exists and is empty?
ls -la /var/lib/pgsql/data

# 2. .pgpass exists and has correct permissions?
ls -l /var/lib/pgsql/.pgpass
cat /var/lib/pgsql/.pgpass

# 3. Primary node is discoverable?
crm status

# 4. Check validation logs
sudo journalctl -u pacemaker | grep -i "auto-init\|pgdata"
```

### Problem: Basebackup stuck

**Check progress**:
```bash
# Monitor basebackup log
tail -f /var/lib/pgsql/data/.basebackup.log

# Check network connectivity
ping psql1
telnet psql1 5432

# Check primary is accepting connections
ssh root@psql1 "sudo -u postgres psql -c 'SELECT pg_is_in_recovery()'"
```

### Problem: Basebackup failed

**Check logs**:
```bash
# Basebackup output
cat /var/lib/pgsql/data/.basebackup.log

# Pacemaker logs
sudo journalctl -u pacemaker | grep -i basebackup

# Common causes:
# - Network interruption
# - Disk space exhausted
# - Authentication failure
# - Primary node stopped during copy
```

**Recovery**:
```bash
# Clean up failed attempt
crm node standby psql2
ssh root@psql2 "sudo rm -rf /var/lib/pgsql/data/*"

# Fix underlying issue (disk space, network, etc.)

# Retry
crm node online psql2
```

---

## Migration Guide

### Upgrading from v1.6.5 and Earlier

**No changes required!** Auto-initialization is backward compatible:

1. **Install new resource agent**:
   ```bash
   sudo cp github/pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
   sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
   ```

2. **No cluster configuration changes needed**

3. **Existing nodes continue working normally**

4. **New feature available immediately** for new deployments or recoveries

### Validation

```bash
# Check agent version (look for v1.6.6 or later)
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data | grep version

# Test auto-initialization (on test cluster)
crm node standby psql2
ssh root@psql2 "sudo rm -rf /var/lib/pgsql/data/*"
crm node online psql2
# Watch logs: sudo journalctl -u pacemaker -f
```

---

## Best Practices

### 1. Always Configure .pgpass

Store `.pgpass` on **separate volume** from PGDATA:
- Survives disk replacement
- Available during auto-initialization
- No need to recreate credentials

### 2. Test in Development First

Validate auto-initialization works in test environment before relying on it in production.

### 3. Monitor First Run

Watch logs during first auto-initialization to understand timing and behavior:
```bash
sudo journalctl -u pacemaker -f &
tail -f /var/lib/pgsql/data/.basebackup.log
```

### 4. Set Reasonable Timeout

For large databases, increase `basebackup_timeout`:
```bash
# In pgsql-resource-config.crm
primitive postgres-db ocf:heartbeat:pgtwin \
    params \
        basebackup_timeout="7200"  # 2 hours for 1TB database
```

### 5. Schedule During Low Traffic

For large databases, perform disk replacements during maintenance windows to minimize impact on primary.

---

## Limitations

1. **Requires .pgpass**: Won't work without configured authentication
2. **Network dependency**: Needs network connectivity to primary
3. **Disk space**: Needs sufficient space for full basebackup
4. **Time to first start**: Initial start delayed by basebackup duration
5. **Primary must be running**: Can't auto-initialize if primary is down

---

## Future Enhancements

Potential improvements for future versions:

- **Parallel basebackup**: Use `pg_basebackup --jobs` for faster copy
- **Incremental initialization**: Use existing data if available
- **Compression**: Enable compression for faster network transfer
- **Resume capability**: Resume interrupted basebackup
- **Network throttling**: Limit bandwidth impact on production traffic

---

## Related Features

This feature builds on:
- **Automatic recovery** (v1.6.0): Auto pg_rewind/basebackup on replication failure
- **Configuration finalization** (v1.6.6): Ensures correct standby config
- **Async basebackup** (v1.1): Background pg_basebackup to avoid timeouts
- **Primary discovery** (v1.6.0): Automatic promoted node detection

---

## Conclusion

Auto-initialization transforms pgtwin from "requires manual basebackup" to "just give it empty PGDATA and it works."

This dramatically simplifies:
- ✅ Fresh deployments (new nodes)
- ✅ Disaster recovery (rebuild failed nodes)
- ✅ Disk replacement (mount new disk, done)
- ✅ Maintenance operations (no manual pg_basebackup)

**The key insight**: If PGDATA is empty and .pgpass is configured, there's only **one correct action** → run pg_basebackup from the primary. The resource agent now does this automatically.

---

**Questions or Issues?**
- GitHub: https://github.com/azouhr/pgtwin/issues
- Documentation: See MAINTENANCE_GUIDE.md, QUICKSTART.md
