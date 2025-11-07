# Manual Recovery Guide: PostgreSQL Timeline Divergence

## Error Description

```
FATAL:  requested timeline 4 is not a child of this server's history
DETAIL:  Latest checkpoint in file "pg_control" is at 0/4000358 on timeline 2,
         but in the history of the requested timeline, the server forked off
         from that timeline at 0/4000218.
```

**What this means**: Your standby server is on timeline 2, but the primary is now on timeline 4. The timelines have diverged, making simple replication impossible.

**Common causes**:
- Multiple failovers without proper standby resync
- Standby was promoted while old primary was still running (split-brain)
- Manual intervention that bypassed cluster management
- pg_rewind failed previously and wasn't retried

---

## CRITICAL: pg_hba.conf Requirements for Recovery

⚠️ **Before attempting recovery, ensure your PRIMARY node's pg_hba.conf has BOTH entries:**

```
# Required for pg_rewind (needs SQL database access)
host    postgres        replicator      192.168.122.0/24        scram-sha-256

# Required for pg_basebackup and streaming replication
host    replication     replicator      192.168.122.0/24        scram-sha-256
```

**Why both are needed**:
- **`postgres` database**: pg_rewind needs to execute SQL queries on the primary
- **`replication` database**: pg_basebackup and streaming replication use the replication protocol

**To verify**:
```bash
# On PRIMARY
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE user_name = '{replicator}';"
```

**If missing, add and reload**:
```bash
sudo vim /var/lib/pgsql/data/pg_hba.conf
# Add both lines above (before any restrictive rules)

sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

**See Issue**: This is documented for fix in v1.7.0 (automatic validation during startup)

---

## Understanding the Situation

### Step 1: Identify Node Roles

```bash
# On the failing node (let's call it NODE2)
# Check if PostgreSQL is running
sudo -u postgres pg_ctl status -D /var/lib/pgsql/data

# Check cluster status
crm status

# Identify which node is currently PRIMARY
# The promoted node will show "Promoted" in crm status
```

**Expected output**:
```
Clone Set: postgres-clone [postgres-db] (promotable)
  * Promoted: [ psql1 ]      ← This is the PRIMARY
  * Unpromoted: [ psql2 ]    ← This is where the error occurs
```

### Step 2: Verify Timeline Status

```bash
# On PRIMARY node (psql1)
sudo -u postgres psql -c "SELECT timeline_id, pg_current_wal_lsn() FROM pg_control_checkpoint();"

# Check timeline history files on PRIMARY
sudo ls -la /var/lib/pgsql/data/pg_wal/*.history
```

```bash
# On STANDBY node (psql2) - the one with the error
sudo -u postgres pg_controldata /var/lib/pgsql/data | grep -E "timeline|checkpoint"
```

**What you're looking for**:
- Primary timeline: 4 (from the error message)
- Standby timeline: 2 (from the error message)
- Timeline mismatch = need to resync

---

## Recovery Options

You have three options, in order of preference:

### Option 1: Let pgtwin Auto-Recover (Recommended)

The pgtwin resource agent has automatic recovery that will handle this.

```bash
# Put the failing node in standby mode (if not already)
crm node standby psql2

# Clean up the resource
crm resource cleanup postgres-clone

# Bring the node back online
crm node online psql2

# Watch the recovery process
sudo journalctl -u pacemaker -f
```

**What happens**:
1. pgtwin detects the timeline mismatch during monitor
2. Replication failure counter increments
3. After threshold (default: 5 cycles), automatic recovery triggers
4. Attempts `pg_rewind` first (fast, if possible)
5. Falls back to `pg_basebackup` if rewind fails
6. Rejoins cluster as standby

**Check progress**:
```bash
# Monitor Pacemaker logs
sudo journalctl -u pacemaker -f | grep -E "recovery|rewind|basebackup"

# Check for basebackup progress file
sudo ls -la /var/lib/pgsql/data/.basebackup_in_progress
sudo tail -f /var/lib/pgsql/data/.basebackup.log
```

---

### Option 2: Manual pg_rewind (Fast, but may not work)

If automatic recovery isn't working or you want manual control:

```bash
# On STANDBY node (psql2)

# 1. Stop Pacemaker management temporarily
crm node standby psql2

# 2. Ensure PostgreSQL is stopped
sudo -u postgres pg_ctl stop -D /var/lib/pgsql/data

# 3. Get PRIMARY hostname
PRIMARY_HOST="psql1"  # Adjust if different

# 4. Attempt pg_rewind
sudo -u postgres PGPASSFILE=/var/lib/pgsql/.pgpass pg_rewind \
  --source-server="host=${PRIMARY_HOST} port=5432 user=replicator dbname=postgres" \
  --target-pgdata=/var/lib/pgsql/data \
  --progress

# 5. Check result
echo "pg_rewind exit code: $?"
```

**If pg_rewind succeeds** (exit code 0):
```bash
# 6. Create standby.signal
sudo -u postgres touch /var/lib/pgsql/data/standby.signal

# 7. Update primary_conninfo in postgresql.auto.conf
sudo -u postgres bash -c "cat >> /var/lib/pgsql/data/postgresql.auto.conf << EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=replicator application_name=psql2 passfile=/var/lib/pgsql/.pgpass'
EOF"

# 8. Bring node back online (let Pacemaker manage it)
crm node online psql2
crm resource cleanup postgres-clone
```

**If pg_rewind fails**, proceed to Option 3.

---

### Option 3: Manual pg_basebackup (Slow, but always works)

Complete re-sync from primary:

```bash
# On STANDBY node (psql2)

# 1. Stop Pacemaker management
crm node standby psql2

# 2. Stop PostgreSQL
sudo -u postgres pg_ctl stop -D /var/lib/pgsql/data

# 3. Check disk space (need 2x current data size if backup enabled)
df -h /var/lib/pgsql/data

# 4. Backup current data (OPTIONAL, for safety)
sudo mv /var/lib/pgsql/data /var/lib/pgsql/data.backup.$(date +%s)
# OR delete immediately (risky!)
# sudo rm -rf /var/lib/pgsql/data/*

# 5. Run pg_basebackup
PRIMARY_HOST="psql1"  # Adjust if needed
SLOT_NAME="ha_slot"   # Must match your configuration

sudo -u postgres PGPASSFILE=/var/lib/pgsql/.pgpass pg_basebackup \
  -h ${PRIMARY_HOST} \
  -U replicator \
  -D /var/lib/pgsql/data \
  -P \
  -R \
  -S ${SLOT_NAME} \
  --checkpoint=fast

# 6. Check result
echo "pg_basebackup exit code: $?"
ls -la /var/lib/pgsql/data/standby.signal  # Should exist

# 7. Bring node back online
crm node online psql2
crm resource cleanup postgres-clone
```

**Monitor progress**:
```bash
# During basebackup
watch -n 5 'du -sh /var/lib/pgsql/data'

# After completion
sudo journalctl -u pacemaker -f
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log
```

---

## Verification After Recovery

### 1. Check Cluster Status

```bash
crm status
```

**Expected output**:
```
Clone Set: postgres-clone [postgres-db] (promotable)
  * Promoted: [ psql1 ]
  * Unpromoted: [ psql2 ]    ← Should show Unpromoted, not FAILED
```

### 2. Verify Replication

```bash
# On PRIMARY (psql1)
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
```

**Expected output**:
```
application_name | psql2
state            | streaming
sync_state       | sync (or async)
```

```bash
# On STANDBY (psql2)
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return: t (true)

sudo -u postgres psql -x -c "SELECT * FROM pg_stat_wal_receiver;"
# Should show: status | streaming
```

### 3. Check Replication Lag

```bash
# On PRIMARY
sudo -u postgres psql -c "SELECT
  application_name,
  state,
  sync_state,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;"
```

**Expected**: lag_bytes should be small (< 1MB in normal operation)

### 4. Verify Timeline Consistency

```bash
# On PRIMARY
sudo -u postgres psql -c "SELECT timeline_id FROM pg_control_checkpoint();"

# On STANDBY
sudo -u postgres pg_controldata /var/lib/pgsql/data | grep "Latest checkpoint's TimeLineID"
```

**Both should show the same timeline** (e.g., timeline 4)

---

## Troubleshooting

### pg_rewind Fails with "target server needs to use either data checksums or 'wal_log_hints'"

**Solution**: You cannot use pg_rewind. Must use pg_basebackup (Option 3).

```bash
# Verify on primary
sudo -u postgres psql -c "SHOW wal_log_hints;"
sudo -u postgres psql -c "SHOW data_checksums;"
```

To enable wal_log_hints for future:
```bash
# In postgresql.custom.conf
wal_log_hints = on
# Requires PostgreSQL restart
```

---

### pg_basebackup Fails with "replication slot does not exist"

**Solution**: Create the replication slot on the primary first.

```bash
# On PRIMARY
sudo -u postgres psql << EOF
SELECT pg_create_physical_replication_slot('ha_slot');
EOF

# Verify
sudo -u postgres psql -c "SELECT * FROM pg_replication_slots;"
```

Then retry pg_basebackup **without** the `-S` option:
```bash
sudo -u postgres PGPASSFILE=/var/lib/pgsql/.pgpass pg_basebackup \
  -h ${PRIMARY_HOST} \
  -U replicator \
  -D /var/lib/pgsql/data \
  -P \
  -R \
  --checkpoint=fast
```

---

### Authentication Fails during pg_rewind or pg_basebackup

**Check .pgpass file**:
```bash
# Must exist and have correct permissions
ls -la /var/lib/pgsql/.pgpass
# Should show: -rw------- 1 postgres postgres

# Verify contents
sudo cat /var/lib/pgsql/.pgpass
# Format: host:port:database:user:password
# Example: *:5432:replication:replicator:YourPasswordHere
```

**Check pg_hba.conf on PRIMARY**:
```bash
# On PRIMARY, verify replication access
sudo grep replication /var/lib/pgsql/data/pg_hba.conf
# Should have line like:
# host  replication  replicator  192.168.122.0/24  scram-sha-256
```

---

### pg_hba.conf Rejects Replication Connection

**Error**: `FATAL: no pg_hba.conf entry for host "192.168.122.120"...`

This means the PRIMARY server is blocking connections from the STANDBY's IP address.

**Step 1: Identify the Standby's IP**:
```bash
# On STANDBY node
ip addr show | grep -E "inet .* (eth|ens|enp)" | grep -v "127.0.0.1"
# Note the IP address (e.g., 192.168.122.120)

# Or test what IP the primary sees
# On STANDBY, try to connect and check
psql "host=<primary_ip> user=replicator dbname=postgres" -c "SELECT inet_client_addr();"
```

**Step 2: Check Current pg_hba.conf on PRIMARY**:
```bash
# On PRIMARY
sudo cat /var/lib/pgsql/data/pg_hba.conf | grep -E "^host.*replication"

# Check what PostgreSQL sees
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database = '{replication}';"
```

**Step 3: Fix pg_hba.conf on PRIMARY**:
```bash
# On PRIMARY, edit pg_hba.conf
sudo vim /var/lib/pgsql/data/pg_hba.conf
```

Add or update the replication line:
```
# BEFORE (may not exist or be too restrictive)
host    replication     replicator      127.0.0.1/32            scram-sha-256

# AFTER (allow from cluster network)
host    replication     replicator      192.168.122.0/24        scram-sha-256

# Or specific IP (replace with your standby's IP)
host    replication     replicator      192.168.122.120/32      scram-sha-256

# Or if using hostnames (requires DNS/hosts file)
host    replication     replicator      psql2.example.com       scram-sha-256
```

**Important order** - place replication entries BEFORE more restrictive rules:
```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Replication connections (MUST come first!)
host    replication     replicator      192.168.122.0/24        scram-sha-256

# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256

# Application connections
host    all             all             192.168.122.0/24        scram-sha-256
```

**Step 4: Reload PostgreSQL Configuration**:
```bash
# On PRIMARY (no restart needed!)
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# Verify the change was loaded
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database = '{replication}';"
```

**Step 5: Test from Standby**:
```bash
# On STANDBY, test connection
PGPASSFILE=/var/lib/pgsql/.pgpass psql \
  -h <primary_hostname_or_ip> \
  -U replicator \
  -d postgres \
  -c "SELECT 'Connection successful';"
```

**If still failing**, check:

1. **Firewall blocking port 5432**:
```bash
# On PRIMARY, check if port is listening
sudo ss -tlnp | grep 5432

# Check firewall
sudo firewall-cmd --list-all | grep 5432
# Or
sudo iptables -L -n | grep 5432

# If needed, allow PostgreSQL
sudo firewall-cmd --permanent --add-port=5432/tcp
sudo firewall-cmd --reload
```

2. **PostgreSQL not listening on correct interface**:
```bash
# On PRIMARY, check listen_addresses
sudo -u postgres psql -c "SHOW listen_addresses;"

# Should be '*' or include the cluster network IP
# If it's 'localhost', edit postgresql.custom.conf:
sudo vim /var/lib/pgsql/data/postgresql.custom.conf

# Add or change:
listen_addresses = '*'  # Or '192.168.122.60,localhost'

# Restart required for listen_addresses change
sudo -u postgres pg_ctl restart -D /var/lib/pgsql/data
```

3. **Wrong hostname/IP being used**:
```bash
# Check what hostname is being used in primary_conninfo
# On STANDBY
sudo grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf

# Make sure it matches the PRIMARY's network interface
# On PRIMARY
hostname
hostname -I
```

---

### Hostname vs Node Name Mismatch During Recovery

**Error**: Recovery tries to connect to cluster node name (e.g., "psql1") but that name doesn't resolve.

**Problem**: Pacemaker cluster node names may differ from actual network hostnames.

**Solution 1 - Use node_list Parameter** (Recommended):
```bash
# Ensure your cluster configuration has node_list with RESOLVABLE names
crm configure show postgres-db | grep node_list

# If using hostnames, verify DNS or /etc/hosts
ping psql1
ping psql2

# If node names don't resolve, use IP addresses in node_list
crm configure edit postgres-db

# Change:
node_list="psql1 psql2"

# To:
node_list="192.168.122.60 192.168.122.120"
```

**Solution 2 - Add /etc/hosts Entries** (on both nodes):
```bash
# Edit /etc/hosts
sudo vim /etc/hosts

# Add cluster node mappings
192.168.122.60   psql1
192.168.122.120  psql2

# Test
ping psql1
ping psql2
```

**Solution 3 - Use VIP Parameter**:
```bash
# Configure VIP in cluster resource
crm configure edit postgres-db

# Add vip parameter
vip="192.168.122.20"

# The agent will use VIP for discovery instead of node names
```

**Verify the fix**:
```bash
# Test name resolution from both nodes
for node in psql1 psql2; do
  echo "Testing $node..."
  ping -c 1 $node
done

# Test PostgreSQL connectivity
for node in psql1 psql2; do
  echo "Testing PostgreSQL on $node..."
  PGPASSFILE=/var/lib/pgsql/.pgpass psql -h $node -U replicator -d postgres -c "SELECT version();" 2>&1 | head -1
done
```

---

### Cluster Won't Start After Recovery

**Cleanup and retry**:
```bash
# Clean up resource
crm resource cleanup postgres-clone

# Check for error messages
sudo journalctl -u pacemaker -n 100

# Check PostgreSQL logs
sudo tail -100 /var/lib/pgsql/data/log/postgresql-*.log

# Verify standby.signal exists on STANDBY
sudo ls -la /var/lib/pgsql/data/standby.signal

# Verify postgresql.auto.conf has primary_conninfo
sudo grep primary_conninfo /var/lib/pgsql/data/postgresql.auto.conf
```

---

## Prevention

### 1. Enable wal_log_hints

Add to `postgresql.custom.conf`:
```ini
wal_log_hints = on
```

This allows pg_rewind to work without data checksums.

### 2. Configure Automatic Recovery

Ensure pgtwin automatic recovery is enabled:
```bash
crm configure show postgres-db | grep replication_failure_threshold
```

Should show:
```
replication_failure_threshold="5"
```

### 3. Regular Testing

Test failover scenarios:
```bash
# 1. Manual failover
crm resource move postgres-clone psql2
crm resource clear postgres-clone

# 2. Verify both nodes can become primary
# 3. Check automatic recovery works
```

---

## When to Call for Help

**Stop and ask for assistance if**:
- You're unsure which node is the current primary
- Multiple nodes show as promoted
- Data loss is unacceptable and you haven't backed up
- The cluster is in production and you're not confident

**Emergency contact checklist**:
- Current `crm status` output
- PostgreSQL logs from both nodes
- Timeline information from both nodes
- Recent cluster changes or failover history

---

## Quick Reference

```bash
# Identify primary
crm status | grep Promoted

# Check timeline on primary
sudo -u postgres psql -c "SELECT timeline_id FROM pg_control_checkpoint();"

# Check timeline on standby
sudo -u postgres pg_controldata /var/lib/pgsql/data | grep TimeLineID

# Put node in standby mode
crm node standby <nodename>

# Bring node back online
crm node online <nodename>

# Clean up resource
crm resource cleanup postgres-clone

# Watch recovery
sudo journalctl -u pacemaker -f

# Check replication status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
```

---

**Last Updated**: 2025-11-05 (v1.6.3)
**Related Documentation**:
- `github/QUICKSTART.md` - Initial cluster setup
- `CLAUDE.md` - Architecture and design principles
- `README.postgres.md` - PostgreSQL configuration guide
