# pgtwin - Quick Start Guide

**pgtwin** is a PostgreSQL High Availability OCF resource agent for **2-node clusters** using Pacemaker and Corosync.

---

## Prerequisites

- 2 Linux nodes (SUSE/openSUSE/RHEL/CentOS)
- PostgreSQL 17.x installed on both nodes
- Pacemaker 3.0.1+ and Corosync installed
- Network connectivity between nodes
- Optional: Shared block device for SBD STONITH fencing

---

## Part 1: PostgreSQL Configuration for HA

### 1.1 Install PostgreSQL 17

```bash
# On both nodes (openSUSE/SUSE)
sudo zypper ref
sudo zypper up   # or 'zypper dup' on Tumbleweed

# On both nodes (openSUSE/SUSE)
sudo zypper install postgresql17 postgresql17-server postgresql17-contrib

# On both nodes (RHEL/CentOS)
sudo dnf install postgresql17 postgresql17-server postgresql17-contrib

**NOTE**: There seems to be an issue installing postgresql17 at least in Tumbleweed, where it also installs postgres-18. This is not addressed here.
```

### 1.2 Initialize PostgreSQL (Primary Node Only)

```bash
# On node 1 only
sudo systemctl start postgresql
sudo systemctl stop postgresql
```

### 1.3 Configure PostgreSQL for Replication

Create `/var/lib/pgsql/data/postgresql.custom.conf`:

```ini
# HA CRITICAL SETTINGS
restart_after_crash = off              # CRITICAL: Must be 'off' for Pacemaker
wal_level = replica                    # REQUIRED for physical replication
max_wal_senders = 16                   # REQUIRED (minimum: 2)
max_replication_slots = 16             # REQUIRED (match wal_senders)
hot_standby = on                       # Allows read queries on standby

# PRODUCTION TIMEOUTS (v1.5 standards)
wal_sender_timeout = 30000             # 30 seconds (prevents false disconnections)
max_standby_streaming_delay = 60000    # 60 seconds (bounds replication lag)
max_standby_archive_delay = 60000      # 60 seconds (bounds replication lag)

# REPLICATION
listen_addresses = '*'                 # Or specific IPs: 'localhost,192.168.122.60'
synchronous_commit = on                # For zero data loss (sync replication)
synchronous_standby_names = '*'        # Match any standby

# ARCHIVE (optional - for PITR)
archive_mode = off                     # Enable if you need point-in-time recovery
# archive_command = 'rsync -a %p /archive/%f || /bin/true'  # Must have error handling!

# LOGGING
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_replication_commands = on
```

Include custom config in `/var/lib/pgsql/data/postgresql.conf`:

```ini
include = 'postgresql.custom.conf'
```

### 1.4 Configure pg_hba.conf

Edit `/var/lib/pgsql/data/pg_hba.conf`:

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication connections from cluster network
host    replication     replicator      192.168.122.0/24        scram-sha-256

# Application connections
host    all             all             192.168.122.0/24        scram-sha-256
```

### 1.5 Start PostgreSQL on Primary (Temporarily)

**IMPORTANT**: Before starting PostgreSQL, temporarily disable synchronous replication to avoid hanging when creating the replication user (since no standby is connected yet).

```bash
# On node 1 only - backup the config and temporarily disable synchronous_standby_names
sudo cp -a /var/lib/pgsql/data/postgresql.custom.conf /var/lib/pgsql/data/postgresql.custom.conf.backup
sudo sed -i "s/^synchronous_standby_names = .*/synchronous_standby_names = ''/" /var/lib/pgsql/data/postgresql.custom.conf

# Start PostgreSQL temporarily
sudo systemctl start postgresql

# Test connection
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW restart_after_crash;"  # Must show 'off'
```

**Why this is necessary**: With `synchronous_standby_names = '*'` configured, PostgreSQL will wait for a standby to confirm every write operation. Since the standby doesn't exist yet, commands like `CREATE ROLE` will hang indefinitely. We temporarily disable this setting and restore the original configuration after setup is complete.

### 1.6 Create Replication User

```bash
# On primary node (while PostgreSQL is running)
sudo -u postgres psql << EOF
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password_here';
EOF
```

### 1.7 Create Replication Slot

```bash
# On primary node - create the replication slot for standby
sudo -u postgres psql << EOF
SELECT pg_create_physical_replication_slot('ha_slot');
EOF

# Verify slot creation
sudo -u postgres psql -c "SELECT * FROM pg_replication_slots;"
```

### 1.8 Create .pgpass File (Both Nodes)

```bash
# On both nodes
sudo -u postgres bash -c 'cat > /var/lib/pgsql/.pgpass << EOF
*:5432:replication:replicator:strong_password_here
EOF'

sudo chmod 600 /var/lib/pgsql/.pgpass
sudo chown postgres:postgres /var/lib/pgsql/.pgpass
```

### 1.9 Copy Data Directory to Standby (Initial Setup)

```bash
# On node 2 - copy from node 1 (use the replication slot created earlier)
sudo -u postgres pg_basebackup -h psql1 -U replicator -D /var/lib/pgsql/data -P -R -S ha_slot

# Verify standby.signal was created
ls -l /var/lib/pgsql/data/standby.signal
```

**NOTE**: The `-S ha_slot` parameter uses the replication slot created in step 1.7. This ensures the primary retains all necessary WAL files during the initial copy.

### 1.10 Restore Configuration and Stop PostgreSQL

```bash
# On node 1 - restore original configuration with synchronous replication enabled
sudo mv /var/lib/pgsql/data/postgresql.custom.conf.backup /var/lib/pgsql/data/postgresql.custom.conf

# Stop PostgreSQL - Pacemaker will manage it from now on
sudo systemctl stop postgresql
```

**NOTE**: We restore the original configuration with `synchronous_standby_names = '*'` now that the standby is ready. When Pacemaker starts the cluster, both nodes will be available for synchronous replication.


---

## Part 2: Pacemaker Cluster Setup

### 2.1 Install Cluster Software (Both Nodes)

```bash
# openSUSE/SUSE
sudo zypper install pacemaker corosync crmsh resource-agents fence-agents-common fence-agents-sbd

# RHEL/CentOS
sudo dnf install pacemaker corosync pcs
```

### 2.2 Install pgtwin OCF Agent (Both Nodes)

```bash
# openSUSE Tumbleweed
sudo zypper ar https://download.opensuse.org/repositories/home:azouhr:d3v/openSUSE_Factory_standard azouhr-d3v
sudo zypper in pgtwin

# For others, there is no package available yet:
# Copy pgtwin agent to OCF directory
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/
sudo chmod +x /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify installation
ls -l /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Optional: Test agent metadata
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data
```

**NOTE**: Testing with `ocf-tester` requires setting environment variables and can be complex. It's recommended to test the agent once the cluster is configured, where Pacemaker will set all required variables automatically.

### 2.3 Configure Cluster (Node 1)

```bash
sudo crm cluster init --name CLUSTERNAME
```

Answer the questions you are asked. For SBD, you will need a shared block device. You should be aware of a persistent device name of that block device.

### 2.4 Configure Cluster (Node 2)

```bash
sudo crm cluster join
```

### 2.5 Configure Cluster Properties

```bash
# On node 1
sudo crm configure property \
  stonith-enabled=false \
  no-quorum-policy=ignore \
  cluster-recheck-interval=1min
```

**Note**: Set `stonith-enabled=true` in production with proper SBD configuration!

### 2.6 Create PostgreSQL Resource

Make sure that your nodelist reflects your infrastructure.

```bash
sudo crm configure primitive postgres-db pgtwin \
  params \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    backup_before_basebackup="true" \
    basebackup_timeout="3600" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    slot_name="ha_slot" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0" \
  op demote timeout="120s" interval="0" \
  op notify timeout="90s" interval="0"
```

### 2.7 Create Clone Resource

```bash
sudo crm configure clone postgres-clone postgres-db \
  meta \
    promotable="true" \
    notify="true" \
    clone-max="2" \
    clone-node-max="1"
```

### 2.8 Create Virtual IP Resource

```bash
sudo crm configure primitive vip IPaddr2 \
  params ip="192.168.122.20" \
  op monitor interval="10s"
```

### 2.9 Create Constraints

```bash
# VIP follows promoted (primary) instance
sudo crm configure colocation vip-with-postgres inf: vip postgres-clone:Promoted

# VIP starts after promotion
sudo crm configure order postgres-before-vip Mandatory: postgres-clone:promote vip:start

# Prefer node 1 as primary
sudo crm configure location postgres-on-psql1 postgres-clone role=Promoted 100: psql1
sudo crm configure location postgres-on-psql2 postgres-clone role=Promoted 50: psql2
```

### 2.10 Verify Configuration

```bash
# Check configuration syntax
sudo crm configure verify

# View full configuration
sudo crm configure show

# Check cluster status
sudo crm status
```

Expected status:
```
Cluster Summary:
  * Stack: corosync
  * Current DC: psql1
  * 2 nodes configured
  * 3 resource instances configured

Node List:
  * Online: [ psql1 psql2 ]

Full List of Resources:
  * Clone Set: postgres-clone [postgres-db] (promotable):
    * Promoted: [ psql1 ]
    * Unpromoted: [ psql2 ]
  * vip (ocf:heartbeat:IPaddr2): Started psql1
```

---

## Part 3: Verification

### 3.1 Check PostgreSQL Status

```bash
# On primary (promoted) node
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # Should be 'f' (false)
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# On standby (unpromoted) node
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # Should be 't' (true)
```

### 3.2 Test VIP

```bash
# From any node or client
ping 192.168.122.20

# Connect via VIP
psql -h 192.168.122.20 -U postgres -c "SELECT inet_server_addr();"
```

### 3.3 Test Failover

```bash
# Trigger manual failover to node 2
sudo crm resource move postgres-clone psql2

# Watch status
sudo crm_mon

# IMPORTANT: Clear the constraint after move!
sudo crm resource clear postgres-clone
```

---

## Part 4: Common Operations

### Check Cluster Status

```bash
sudo crm status
sudo crm_mon -1Afr
```

### Check PostgreSQL Logs

```bash
# Pacemaker logs. This is **strongly recommended**. pgtwin will print lots of warning if the configuration is not optimal.
sudo journalctl -u pacemaker -f

# PostgreSQL logs
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log
```

### Manual Failover

```bash
# Move primary to specific node
sudo crm resource move postgres-clone <node_name>

# ALWAYS clear after move!
sudo crm resource clear postgres-clone
```

### Check Replication Lag

```bash
# On primary
sudo -u postgres psql -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

### Restart Resource

```bash
# Restart PostgreSQL resource on current node
sudo crm resource restart postgres-clone
```

### Stop/Start Cluster

```bash
# Stop all cluster resources
sudo crm resource stop postgres-clone

# Start all cluster resources
sudo crm resource start postgres-clone
```

---

## Troubleshooting

### Resource Won't Start

```bash
# Check pacemaker logs
sudo journalctl -u pacemaker -n 100

# Check PostgreSQL logs
sudo cat /var/lib/pgsql/data/log/postgresql-*.log

# Check resource agent output
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin start
```

### Split-Brain Prevention

**CRITICAL**: Ensure `restart_after_crash = off` in PostgreSQL configuration!

```bash
# Verify setting
sudo -u postgres psql -c "SHOW restart_after_crash;"  # MUST be 'off'
```

### Replication Not Working

```bash
# On primary - check connections
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# On standby - check replay status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_wal_receiver;"

# Check .pgpass permissions
ls -l /var/lib/pgsql/.pgpass  # Should be 600, owned by postgres
```

### Configuration Validation Errors

The pgtwin agent performs automatic validation on startup. Check for:

```bash
# Look for validation messages in logs
sudo journalctl -u pacemaker | grep -E "CRITICAL ERROR|WARNING"

# Common issues:
# - restart_after_crash='on' → CRITICAL ERROR (must fix immediately!)
# - wal_sender_timeout < 10s → WARNING (increase to 15-30 seconds)
# - max_standby_streaming_delay=-1 → WARNING (set to 30-60 seconds)
```

---

## Production Checklist

Before deploying to production, verify:

- ☑ **PostgreSQL Configuration**
  - `restart_after_crash = off` (CRITICAL - prevents split-brain)
  - `wal_level = replica`
  - `max_wal_senders >= 2`
  - `wal_sender_timeout >= 15000` (15 seconds minimum)
  - `max_standby_streaming_delay != -1` (set to 30000-60000)

- ☑ **Replication**
  - `.pgpass` file configured with proper permissions (0600)
  - Replication user created with correct grants
  - `pg_hba.conf` allows replication from standby node
  - Replication slot created and active

- ☑ **Cluster Configuration**
  - STONITH enabled (`stonith-enabled=true`)
  - Fencing device configured and tested
  - VIP configured and reachable
  - Both nodes have identical pgtwin agent version
  - Location constraints configured for both nodes

- ☑ **Testing**
  - Manual failover tested successfully
  - Automatic failover tested (node power-off)
  - Replication lag monitored (<1 second normal)
  - VIP migration verified
  - Client reconnection tested

- ☑ **Monitoring**
  - Cluster status monitoring configured
  - PostgreSQL log monitoring
  - Disk space alerts (especially for WAL)
  - Replication lag alerts

---

## Next Steps

1. **Administration Commands**: See CHEATSHEET.md for complete command reference
2. **Architecture Details**: See README.md for design decisions and features

---

## Quick Reference

| Task | Command |
|------|---------|
| Check status | `sudo crm status` |
| Check detailed status | `sudo crm_mon -1Afr` |
| Manual failover | `sudo crm resource move postgres-clone <node>` |
| Clear constraints | `sudo crm resource clear postgres-clone` |
| Check replication | `sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"` |
| Check configuration | `sudo crm configure show` |
| Pacemaker logs | `sudo journalctl -u pacemaker -f` |
| PostgreSQL logs | `sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log` |

---

**pgtwin** - PostgreSQL Twin: Two-Node HA Made Simple

For more information, visit: https://github.com/azouhr/pgtwin
