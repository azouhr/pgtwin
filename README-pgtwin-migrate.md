# pgtwin-migrate

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

> **WARNING**: pgtwin-migrate v2.0.0 is EXPERIMENTAL. Test thoroughly before production use.

## Overview

pgtwin-migrate enables **zero-downtime PostgreSQL migrations** by orchestrating logical replication between two parallel PostgreSQL clusters managed by Pacemaker. It handles the complete migration lifecycle: forward replication, cutover automation, and reverse replication for fallback scenarios.

### Use Cases

- **Major version upgrades** (e.g., PostgreSQL 17 → 18)
- **Vendor migrations** (e.g., on-premise → cloud)
- **Hosting provider changes** (e.g., AWS RDS → self-hosted)
- **Architecture changes** (e.g., physical → containerized)

### Key Features

- ✅ **Zero downtime** - Applications keep running during migration
- ✅ **Bidirectional failover** - Switch production between clusters using `production_cluster` parameter (v2.0)
- ✅ **Dynamic database discovery** - Databases discovered at runtime, no explicit list needed (v2.0)
- ✅ **New database auto-setup** - New databases detected and replicated automatically (v2.0)
- ✅ **Automatic DDL replication** - Schema changes replicated automatically
- ✅ **Direction-aware** - Correctly handles both forward and reverse directions (v2.0)
- ✅ **Self-healing** - Automatically reconciles missing components

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      BEFORE MIGRATION                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Source Cluster (PG17)              Target Cluster (PG18)           │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Primary (RW)   │──────────────>  │ Primary (RW)   │              │
│  │ pgtwin01       │  Logical Rep    │ pgtwin02       │              │
│  └────────────────┘  (Forward)      └────────────────┘              │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Standby        │                 │ Standby        │              │
│  │ pgtwin11       │                 │ pgtwin12       │              │
│  └────────────────┘                 └────────────────┘              │
│                                                                     │
│  Production VIP: 192.168.60.100 → Points to Source (PG17)           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       AFTER CUTOVER                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Source Cluster (PG17)              Target Cluster (PG18)           │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Primary (RW)   │  <──────────────│ Primary (RW)   │              │
│  │ pgtwin01       │  Logical Rep    │ pgtwin02       │              │
│  └────────────────┘  (Reverse)      └────────────────┘              │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Standby        │                 │ Standby        │              │
│  │ pgtwin11       │                 │ pgtwin12       │              │
│  └────────────────┘                 └────────────────┘              │
│                                                                     │
│  Production VIP: 192.168.60.100 → Points to Target (PG18)           │
│  Applications now running on new PostgreSQL version!                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Migration Phases (v2.0)

### 1. Start Phase (Automated)

When you start the migration resource:
- Discovers all databases from the production cluster (no explicit list needed)
- Creates publications on source cluster for each database
- Creates subscriptions on target cluster with `copy_data=true`
- Creates DDL triggers for schema replication
- Initial data sync via logical replication
- Continuous forward replication (source → target)

### 2. Monitoring Phase (Continuous)

While the migration runs:
- Every 10th monitor cycle, checks for new databases
- New databases detected automatically and replication set up
- DDL changes replicated automatically
- Replication lag monitored

### 3. Cutover Phase (Automated)

**Triggered by:** Changing the `production_cluster` parameter

```bash
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone-18
```

**What happens (all automated):**
1. Old direction replication is DELETED (publications, subscriptions, slots)
2. New direction replication is CREATED fresh
3. VIP follows production cluster automatically
4. CIB state updated to reflect new direction

**Downtime:** Zero - Applications reconnect to new VIP seamlessly

### 4. Failback Option (v2.0)

Can switch production back to source cluster at any time:
```bash
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone
```

### 5. Finalization (When Ready)

When confident the migration is complete:
```bash
# Mark for cleanup
crm_resource --resource migration-forward \
  --set-parameter finalize_replication \
  --parameter-value true

# Stop resource (triggers cleanup)
crm resource stop migration-forward
```

## Installation

```bash
# Copy agent to OCF directory (all cluster nodes)
sudo cp pgtwin-migrate /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate

# Copy setup wizard (admin workstation or one cluster node)
sudo cp pgtwin-migrate-setup /usr/local/bin/
sudo chmod 755 /usr/local/bin/pgtwin-migrate-setup
```

## Quick Start (v2.0)

### Option A: Interactive Setup (Recommended)

```bash
# Step 1: Run setup wizard
./pgtwin-migrate-setup

# Wizard will ask for:
# - Source and target cluster names
# - VIP resource names
# - Migration user credentials
# - Which databases to migrate (or auto-discover)

# Generates:
#   migration-forward.conf  - Configuration file
#   migration-forward.crm   - Pacemaker configuration

# Step 2: Apply configuration
crm configure load update migration-forward.crm

# Step 3: Start migration
crm resource start migration-forward
```

### Option B: Manual Configuration

```bash
# Configure cluster resource (v2.0 parameters)
crm configure primitive migration-forward ocf:heartbeat:pgtwin-migrate \
    params \
        source_cluster="postgres-clone" \
        target_cluster="postgres-clone-18" \
        production_cluster="postgres-clone" \
        production_vip_resource="postgres-vip" \
        source_replication_vip_resource="postgres-replication-vip" \
        target_replication_vip_resource="postgres-replication-vip-18" \
        migration_dbuser="pgmigrate" \
        migration_dbpassword="SecurePassword" \
    meta \
        target-role=Stopped \
        migration-threshold=3 \
        failure-timeout=300s
```

## Usage (v2.0)

### Start Migration

```bash
# Start forward replication (databases discovered automatically)
crm resource start migration-forward

# Monitor progress
crm_attribute -G -n migration-state -q
journalctl -u pacemaker -f | grep migration-forward
```

### Trigger Cutover

```bash
# Switch production to target cluster
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone-18

# Monitor cutover progress (completes in seconds)
journalctl -u pacemaker -f | grep -i cutover
```

### Failback (if needed)

```bash
# Switch production back to source cluster
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone
```

### Finalize Migration

```bash
# When confident, mark for cleanup
crm_resource --resource migration-forward \
  --set-parameter finalize_replication \
  --parameter-value true

# Stop resource (triggers cleanup)
crm resource stop migration-forward
```

### Verify Migration

```bash
# Check current state
crm_attribute -G -n migration-state -q

# Check replication on target
ssh root@<target-primary> "sudo -u postgres psql -x -c \
  'SELECT * FROM pg_stat_subscription;'"

# Test DDL replication
ssh root@<target-primary> "sudo -u postgres psql -c \
  'CREATE TABLE migration_test (id INT);'"

ssh root@<source-primary> "sudo -u postgres psql -c \
  '\\d migration_test'"  # Should exist (reverse replication)
```

## Configuration Parameters

### Required

| Parameter | Description | Example |
|-----------|-------------|---------|
| `source_cluster` | Source cluster resource name | `postgres-clone` |
| `target_cluster` | Target cluster resource name | `postgres-clone-18` |
| `production_cluster` | Which cluster is production (v2.0) | `postgres-clone` |
| `production_vip_resource` | Production VIP resource name | `postgres-vip` |
| `source_replication_vip_resource` | Source replication VIP | `postgres-replication-vip` |
| `target_replication_vip_resource` | Target replication VIP | `postgres-replication-vip-18` |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `databases` | (auto-discover) | Comma-separated list of databases. If not set, discovers from production cluster. |
| `migration_dbuser` | `pgmigrate` | Migration user for logical replication |
| `migration_dbpassword` | - | Migration password (can use .pgpass instead) |
| `pgport` | `5432` | PostgreSQL port |
| `source_node_role` | `Promoted` | Source node to use: "Promoted" or "Unpromoted" |
| `finalize_replication` | `false` | When true, stop cleans up all replication infrastructure |
| `stability_timeout` | `30` | Seconds to wait for cluster stability before cutover |

### v2.0 Parameter Changes

| Change | Parameter | Notes |
|--------|-----------|-------|
| **NEW** | `production_cluster` | Which cluster should be production. Changing triggers cutover. |
| **NEW** | `finalize_replication` | When true, stop cleans up all replication infrastructure. |
| **NEW** | `stability_timeout` | Seconds to wait for cluster stability before cutover. |
| **REMOVED** | `cutover_ready` | Replaced by `production_cluster` |
| **CHANGED** | `databases` | Now optional - auto-discovers if not specified |

## Version History

- **v2.0.0** (2026-01-19) - **EXPERIMENTAL** Major redesign
  - Bidirectional failover with `production_cluster` parameter
  - Dynamic database discovery (no explicit `databases` parameter needed)
  - Direction-aware start function
  - New database auto-setup in monitor
  - Delete/create approach for cutover (no stale subscriptions)
- **v1.0.8** (2026-01-10) - Multi-database migration support
- **v1.0.7** (2026-01-07) - Auto-stop, quiesce-based reverse slots
- **v1.0.6** (2026-01-02) - Self-healing + cluster attribute fix
- **v1.0.5** (2026-01-02) - Cutover window optimization
- **v1.0.4** (2026-01-02) - Bidirectional DDL replication
- **v1.0.3** (2026-01-02) - Completion detection + reliability
- **v1.0.2** (2025-12-30) - Production cutover validation
- **v1.0.1** (2025-12-29) - Log retention enhancements
- **v1.0.0** (2025-12-28) - Initial release

## Documentation

### Complete Documentation

- **MIGRATION_DOCUMENTATION_INDEX.md** - Complete migration workflow guide
- **PGTWIN_CONCEPTS.md** - Conceptual overview of pgtwin agents
- **FEATURE_REVERSE_DDL_REPLICATION_v1.0.4.md** - Bidirectional DDL details
- **OPTIMIZATION_CUTOVER_WINDOW_v1.0.5.md** - Cutover performance
- **BUGFIX_CLUSTER_ATTRIBUTE_SCOPE_v1.0.6.md** - Self-healing implementation

### Quick Guides

- **QUICKSTART_MIGRATION_SETUP.md** - Migration cluster setup
- **MIGRATION_CUTOVER_PROCEDURE.md** - Step-by-step cutover guide
- **POST_MIGRATION_CLEANUP.md** - Cleanup after migration

## Requirements

### PostgreSQL Configuration

**Both clusters must have:**
```ini
# postgresql.conf
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
max_logical_replication_workers = 10
```

**Authentication (.pgpass):**
```
# On all nodes in both clusters
<source-replication-vip>:5432:postgres:pgmigrate:<password>
<target-replication-vip>:5432:postgres:pgmigrate:<password>
<source-replication-vip>:5432:replication:replicator:<password>
<target-replication-vip>:5432:replication:replicator:<password>
```

### Cluster Setup

- Two pgtwin-managed PostgreSQL clusters (source and target)
- Replication VIPs configured on both clusters
- Production VIP managed separately
- Both clusters must be healthy before starting migration

## Troubleshooting

### Migration won't start

```bash
# Check cluster state
crm_attribute -G -n migration-state -q

# If stale state exists
crm_attribute -D -n migration-state

# Verify clusters healthy
crm status

# Check for existing publications (v2.0 checks these)
ssh root@<source-primary> "sudo -u postgres psql -c \
  \"SELECT pubname FROM pg_publication WHERE pubname LIKE 'pgtwin_migrate_%';\""
```

### Cutover fails

```bash
# Check logs
journalctl -u pacemaker -f | grep -i cutover

# Check current production_cluster value
crm_resource --resource migration-forward --get-parameter production_cluster

# Verify both clusters are healthy before cutover
crm status
```

### New database not being replicated

```bash
# Check if database exists on subscriber
ssh root@<target-primary> "sudo -u postgres psql -l"

# Check for missing publications (v2.0 auto-detects every 10th monitor cycle)
ssh root@<source-primary> "sudo -u postgres psql -c \
  \"SELECT pubname FROM pg_publication WHERE pubname LIKE 'pgtwin_migrate_%';\""

# Force re-check by restarting resource
crm resource restart migration-forward
```

### max_logical_replication_workers limit

```bash
# Check current setting
ssh root@<target-primary> "sudo -u postgres psql -c 'SHOW max_logical_replication_workers;'"

# Increase in postgresql.custom.conf (NOT postgresql.conf)
echo "max_logical_replication_workers = 10" >> /var/lib/pgsql/data/postgresql.custom.conf

# Restart PostgreSQL
crm resource restart postgres-clone-18
```

### Reverse replication not working

```bash
# Check reverse subscription on source
ssh root@<source-primary> "sudo -u postgres psql -x -c \
  'SELECT * FROM pg_stat_subscription;'"

# Check DDL triggers on target
ssh root@<target-primary> "sudo -u postgres psql -c \
  'SELECT evtname, evtenabled FROM pg_event_trigger;'"

# Restart to trigger reconciliation
crm resource restart migration-forward
```

## Known Limitations (v2.0)

1. **max_logical_replication_workers limit** - PostgreSQL default is 4 workers. For migrations with many databases, increase this setting in `postgresql.custom.conf`.

2. **Initial sync for new databases** - When a new database is created, `copy_data=true` handles initial sync, but the database must exist on both clusters (subscriber creates it automatically).

3. **Schema changes during migration** - DDL triggers handle most schema changes, but complex migrations may need manual coordination.

## Migration from v1.x

1. Complete any in-progress migrations
2. Stop and delete old migration resource
3. Deploy pgtwin-migrate v2.0
4. Use pgtwin-migrate-setup to generate new configuration
5. Test with non-production data first

**Breaking changes:**
- `cutover_ready` parameter removed - use `production_cluster` instead
- Cutover triggered by changing `production_cluster`, not setting a trigger attribute

## License

GPL-2.0-or-later

## Support

For issues and questions:
- GitHub: https://github.com/anthropics/pgtwin (if published)
- Documentation: See MIGRATION_DOCUMENTATION_INDEX.md

---

**pgtwin-migrate v2.0.0 (EXPERIMENTAL) - Pacemaker OCF agent for PostgreSQL cluster migrations via logical replication**
