# pgtwin - Administration Cheat Sheet

Quick reference for all common pgtwin cluster administration commands.

---

## Cluster Status Commands

### Basic Status

```bash
# Quick cluster status
sudo crm status

# Detailed status (1-time refresh, all info, formatted, resources)
sudo crm_mon -1Afr

# Live monitoring (refresh every 2 seconds)
sudo crm_mon -Afr

# Status in XML format
sudo crm_mon -1X
```

### Node Status

```bash
# List cluster nodes
sudo crm node list

# Check node status
sudo crm node status

# Show node attributes
sudo crm node attribute

# Check if node is online
sudo crm node online psql1
```

### Resource Status

```bash
# List all resources
sudo crm resource status

# Show resource configuration
sudo crm configure show postgres-clone

# Check resource failcount
sudo crm resource failcount postgres-clone show psql1

# Show resource operations
sudo crm_resource --resource postgres-clone --query-xml
```

---

## PostgreSQL Monitoring

### Replication Status

```bash
# On PRIMARY - check standby connections
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# Quick replication status
sudo -u postgres psql -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"

# On STANDBY - check replication receiver
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_wal_receiver;"

# Check if instance is primary or standby
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # f=primary, t=standby
```

### Replication Lag

```bash
# On PRIMARY - check lag in bytes
sudo -u postgres psql -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# On PRIMARY - check lag in MB
sudo -u postgres psql -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb FROM pg_stat_replication;"

# On STANDBY - check replay lag
sudo -u postgres psql -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

### Database Health

```bash
# Check PostgreSQL version
sudo -u postgres psql -c "SELECT version();"

# Check uptime
sudo -u postgres psql -c "SELECT pg_postmaster_start_time();"

# Check active connections
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"

# Check database sizes
sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"

# Check replication slots
sudo -u postgres psql -x -c "SELECT * FROM pg_replication_slots;"
```

### Configuration Verification

```bash
# Check critical HA settings
sudo -u postgres psql -c "SHOW restart_after_crash;"  # MUST be 'off'
sudo -u postgres psql -c "SHOW wal_level;"            # Must be 'replica'
sudo -u postgres psql -c "SHOW max_wal_senders;"      # Should be >= 2
sudo -u postgres psql -c "SHOW wal_sender_timeout;"   # Recommended: 30000
sudo -u postgres psql -c "SHOW max_standby_streaming_delay;"  # Recommended: 60000
sudo -u postgres psql -c "SHOW synchronous_commit;"   # For sync: 'on'
sudo -u postgres psql -c "SHOW synchronous_standby_names;"  # For sync: '*' or node name
```

---

## Failover Operations

### Manual Failover

```bash
# Move primary to specific node
sudo crm resource move postgres-clone psql2

# Watch failover happen
watch -n 2 'sudo crm status'

# CRITICAL: Always clear move constraint after!
sudo crm resource clear postgres-clone
```

### Automatic Failover (Simulate)

```bash
# On current primary node - stop pacemaker to trigger failover
sudo systemctl stop pacemaker

# On other node - watch promotion
watch -n 1 'sudo crm status'

# After failover - restart stopped node
sudo systemctl start pacemaker
```

### Ban/Allow Resources

```bash
# Ban resource from running on a node
sudo crm resource ban postgres-clone psql1

# Allow resource back on node
sudo crm resource clear postgres-clone psql1

# Show constraints (including bans)
sudo crm configure show
```

---

## Resource Management

### Start/Stop Resources

```bash
# Stop resource (on all nodes)
sudo crm resource stop postgres-clone

# Start resource
sudo crm resource start postgres-clone

# Restart resource (current node)
sudo crm resource restart postgres-clone

# Cleanup resource (clear failcount)
sudo crm resource cleanup postgres-clone
```

### Resource Constraints

```bash
# Show all constraints
sudo crm configure show | grep -A5 "location\|colocation\|order"

# Add location constraint (prefer node)
sudo crm configure location postgres-on-psql1 postgres-clone 100: psql1

# Remove constraint
sudo crm configure delete postgres-on-psql1
```

### Resource Operations

```bash
# Probe resource (check current state)
sudo crm resource probe postgres-clone

# Refresh resource (update metadata)
sudo crm resource refresh postgres-clone

# Reprobe all resources
sudo crm resource reprobe
```

---

## Configuration Management

### View Configuration

```bash
# Show all configuration
sudo crm configure show

# Show specific resource
sudo crm configure show postgres-clone

# Show properties
sudo crm configure show type:property

# Export configuration to file
sudo crm configure save postgres-cluster.conf
```

### Modify Configuration

```bash
# Enter configuration edit mode
sudo crm configure edit

# Verify configuration syntax
sudo crm configure verify

# Load configuration from file
sudo crm configure load update postgres-cluster.conf

# Commit changes (done automatically, but can force)
sudo crm configure commit
```

### Backup Configuration

```bash
# Save current configuration
sudo crm configure save /root/cluster-backup-$(date +%Y%m%d).conf

# Save with shadow copy
sudo crm configure save shadow backup-$(date +%Y%m%d)
```

---

## Log Analysis

### Pacemaker Logs

```bash
# Follow pacemaker logs
sudo journalctl -u pacemaker -f

# Last 100 pacemaker entries
sudo journalctl -u pacemaker -n 100

# Pacemaker logs since today
sudo journalctl -u pacemaker --since today

# Pacemaker errors only
sudo journalctl -u pacemaker -p err

# Pacemaker logs with grep
sudo journalctl -u pacemaker | grep -i "postgres\|error\|failed"
```

### Corosync Logs

```bash
# Corosync logs
sudo journalctl -u corosync -n 100

# Check for membership changes
sudo journalctl -u corosync | grep -i "member"

# Check for quorum changes
sudo journalctl -u corosync | grep -i "quorum"
```

### PostgreSQL Logs

```bash
# Follow PostgreSQL logs
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log

# Last 50 lines
sudo tail -50 /var/lib/pgsql/data/log/postgresql-*.log

# Search for errors
sudo grep -i "error\|fatal\|panic" /var/lib/pgsql/data/log/postgresql-*.log

# Search for replication issues
sudo grep -i "replication\|standby\|wal sender" /var/lib/pgsql/data/log/postgresql-*.log
```

### Configuration Validation Messages

```bash
# Check for pgtwin v1.5 validation warnings
sudo journalctl -u pacemaker | grep -E "CRITICAL ERROR|CONFIGURATION ERROR|WARNING"

# Check restart_after_crash validation (CRITICAL)
sudo journalctl -u pacemaker | grep "restart_after_crash"

# Check timeout warnings
sudo journalctl -u pacemaker | grep "wal_sender_timeout\|max_standby"

# Check archive warnings
sudo journalctl -u pacemaker | grep -i "archive"
```

---

## Maintenance Operations

### Maintenance Mode

```bash
# Enable maintenance mode (resources won't failover)
sudo crm configure property maintenance-mode=true

# Perform maintenance...

# Disable maintenance mode
sudo crm configure property maintenance-mode=false
```

### Standby Mode (Node)

```bash
# Put node in standby (stop all resources on node)
sudo crm node standby psql1

# Bring node back online
sudo crm node online psql1

# Check node state
sudo crm node status psql1
```

### Resource Cleanup

```bash
# Clear failed operations
sudo crm resource cleanup postgres-clone

# Clear failed operations on specific node
sudo crm resource cleanup postgres-clone psql1

# Reset failcount to zero
sudo crm resource failcount postgres-clone delete psql1
```

---

## Cluster Operations

### Cluster Start/Stop

```bash
# Stop cluster on single node
sudo crm cluster stop

# Stop cluster on all nodes
sudo crm cluster stop --all

# Start cluster on single node
sudo crm cluster start

# Start cluster on all nodes
sudo crm cluster start --all

# Restart cluster
sudo crm cluster restart
```

### Quorum

```bash
# Check quorum status
sudo corosync-quorumtool

# Check quorum expected votes
sudo corosync-quorumtool -s

# Set expected votes (emergency only!)
sudo corosync-quorumtool -e 1  # WARNING: Use with caution!
```

---

## Diagnostics and Troubleshooting

### Generate Report

```bash
# Generate comprehensive cluster report
sudo crm report /tmp/cluster-report-$(date +%Y%m%d)

# Generate report for specific time period
sudo crm report -f "2025-01-01 00:00" -t "2025-01-02 00:00" /tmp/cluster-report
```

### Check Resource Agent

```bash
# Test OCF agent syntax
sudo bash -n /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Test OCF agent manually (as root)
sudo OCF_ROOT=/usr/lib/ocf \
  OCF_RESKEY_pgdata=/var/lib/pgsql/data \
  OCF_RESKEY_pgport=5432 \
  /usr/lib/ocf/resource.d/heartbeat/pgtwin monitor

# Check agent metadata
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data
```

### Network Diagnostics

```bash
# Check connectivity between nodes
ping -c 3 psql2

# Check PostgreSQL port
telnet psql2 5432

# Check corosync port
sudo nc -zv psql2 5405

# Check pacemaker port
sudo nc -zv psql2 2224
```

### Disk Space

```bash
# Check disk space
df -h /var/lib/pgsql/data

# Check PGDATA size
du -sh /var/lib/pgsql/data

# Check WAL directory size
du -sh /var/lib/pgsql/data/pg_wal

# Check archive failures (if archiving enabled)
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
```

---

## VIP Management

### VIP Status

```bash
# Check which node has VIP
sudo crm resource status vip

# Check VIP from network
ping 192.168.122.20

# Show IP addresses on all interfaces
ip addr show

# Check VIP with grep
ip addr show | grep "192.168.122.20"
```

### VIP Operations

```bash
# Move VIP (by moving primary)
sudo crm resource move postgres-clone psql2

# Stop VIP
sudo crm resource stop vip

# Start VIP
sudo crm resource start vip

# Check VIP connectivity
psql -h 192.168.122.20 -U postgres -c "SELECT inet_server_addr();"
```

---

## Emergency Procedures

### Force Stop Resource

```bash
# Stop resource immediately (may leave processes)
sudo crm resource stop postgres-clone

# If stuck, try:
sudo crm_resource --resource postgres-clone --force-stop

# Last resort - kill PostgreSQL manually
sudo pkill -9 postgres
sudo crm resource cleanup postgres-clone
```

### Recovery from Split-Brain

```bash
# 1. Stop cluster on both nodes
sudo crm cluster stop --all

# 2. On node to become primary (psql1):
sudo -u postgres pg_ctl -D /var/lib/pgsql/data start

# 3. On node to become standby (psql2):
sudo -u postgres rm -rf /var/lib/pgsql/data
sudo -u postgres pg_basebackup -h psql1 -U replicator -D /var/lib/pgsql/data -P -R

# 4. Stop PostgreSQL on both
sudo -u postgres pg_ctl -D /var/lib/pgsql/data stop

# 5. Start cluster
sudo crm cluster start --all

# 6. Verify status
sudo crm status
```

### Reset Cluster Configuration

```bash
# DANGER: This will wipe all cluster configuration!
sudo crm cluster stop --all
sudo rm -rf /var/lib/pacemaker/cib/*
# Re-initialize cluster from scratch
```

---

## Performance Monitoring

### Connection Stats

```bash
# Active connections by state
sudo -u postgres psql -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"

# Long-running queries
sudo -u postgres psql -c "SELECT pid, now() - query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '5 minutes';"
```

### Replication Slot Monitoring

```bash
# Check slot lag
sudo -u postgres psql -c "SELECT slot_name, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS lag_mb FROM pg_replication_slots;"

# Check slot status
sudo -u postgres psql -c "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;"
```

---

## Quick Diagnostics Checklist

```bash
# Run this for quick health check:

echo "=== Cluster Status ==="
sudo crm status

echo "=== Node Status ==="
sudo crm node list

echo "=== PostgreSQL Primary/Standby ==="
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

echo "=== Replication Status ==="
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;" 2>/dev/null || echo "Not primary"

echo "=== Replication Lag ==="
sudo -u postgres psql -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb FROM pg_stat_replication;" 2>/dev/null || echo "Not primary"

echo "=== Critical Settings ==="
sudo -u postgres psql -c "SHOW restart_after_crash; SHOW wal_level; SHOW max_wal_senders;"

echo "=== VIP Status ==="
ip addr show | grep "192.168.122.20" || echo "VIP not on this node"

echo "=== Disk Space ==="
df -h /var/lib/pgsql/data | tail -1

echo "=== Recent Errors ==="
sudo journalctl -u pacemaker --since "1 hour ago" -p err
```

---

## Useful Aliases

Add to `~/.bashrc` for convenience:

```bash
# Cluster status
alias cst='sudo crm status'
alias cmon='sudo crm_mon -Afr'

# PostgreSQL commands
alias pgprimary='sudo -u postgres psql -c "SELECT pg_is_in_recovery();"'
alias pgrepl='sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"'
alias pglag='sudo -u postgres psql -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb FROM pg_stat_replication;"'

# Logs
alias plog='sudo journalctl -u pacemaker -f'
alias pglog='sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log'
```

---

**pgtwin** - PostgreSQL Twin: Two-Node HA Made Simple

For more information, visit: https://github.com/azouhr/pgtwin
