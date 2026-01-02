# pgtwin-migrate

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

## Overview

pgtwin-migrate enables **zero-downtime PostgreSQL migrations** by orchestrating logical replication between two parallel PostgreSQL clusters managed by Pacemaker. It handles the complete migration lifecycle: forward replication, cutover automation, and reverse replication for fallback scenarios.

### Use Cases

- **Major version upgrades** (e.g., PostgreSQL 15 → 17)
- **Vendor migrations** (e.g., on-premise → cloud)
- **Hosting provider changes** (e.g., AWS RDS → self-hosted)
- **Architecture changes** (e.g., physical → containerized)

### Key Features

- ✅ **Zero downtime** - Applications keep running during migration
- ✅ **Bidirectional replication** - Forward (source→target) and reverse (target→source)
- ✅ **Automatic DDL replication** - Schema changes replicated automatically
- ✅ **VIP management** - Seamless traffic redirection during cutover
- ✅ **Self-healing** - Automatically reconciles missing components (v1.0.6+)
- ✅ **Idempotent** - Works regardless of cluster state (v1.0.6+)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      BEFORE MIGRATION                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Source Cluster (PG17)              Target Cluster (PG18)            │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Primary (RW)   │──────────────>  │ Primary (RW)   │              │
│  │ pgtwin01       │  Logical Rep    │ pgtwin02       │              │
│  └────────────────┘  (Forward)      └────────────────┘              │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Standby        │                 │ Standby        │              │
│  │ pgtwin11       │                 │ pgtwin12       │              │
│  └────────────────┘                 └────────────────┘              │
│                                                                       │
│  Production VIP: 192.168.60.100 → Points to Source (PG17)           │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       AFTER CUTOVER                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Source Cluster (PG17)              Target Cluster (PG18)            │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Primary (RW)   │  <──────────────│ Primary (RW)   │              │
│  │ pgtwin01       │  Logical Rep    │ pgtwin02       │              │
│  └────────────────┘  (Reverse)      └────────────────┘              │
│  ┌────────────────┐                 ┌────────────────┐              │
│  │ Standby        │                 │ Standby        │              │
│  │ pgtwin11       │                 │ pgtwin12       │              │
│  └────────────────┘                 └────────────────┘              │
│                                                                       │
│  Production VIP: 192.168.60.100 → Points to Target (PG18)           │
│  Applications now running on new PostgreSQL version!                 │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Migration Phases

### 1. Preparation Phase (Automated)

- Creates publication on source cluster
- Creates subscription on target cluster (disabled)
- Creates forward DDL trigger (source → target)
- Creates reverse DDL trigger (target → source, disabled)
- Initial data sync via `COPY` protocol
- Continuous forward replication (source → target)

### 2. Cutover Phase (Automated)

**Triggered by:** `crm_attribute -n migration-trigger -v start_cutover -l reboot`

**Steps (all automated):**
1. Set source cluster read-only
2. Wait for target to catch up (LSN synchronization)
3. Swap VIPs (production VIP → target cluster)
4. Set source cluster read-write
5. Enable reverse replication (target → source)
6. Monitor completion

**Downtime:** Zero - Applications reconnect to new VIP seamlessly

### 3. Post-Cutover (Continuous)

- **Production:** Target cluster (newer PostgreSQL version)
- **Backup:** Source cluster (receives reverse replication)
- **Fallback option:** Can migrate back using reverse replication

## Installation

```bash
# Copy agent to OCF directory
sudo cp pgtwin-migrate /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate

# Configure cluster resource
crm configure primitive migration-forward ocf:heartbeat:pgtwin-migrate \
    params \
        source_cluster="postgres-clone" \
        target_cluster="postgres-clone-18" \
        production_vip_resource="postgres-vip" \
        source_replication_vip_resource="postgres-replication-vip" \
        target_replication_vip_resource="postgres-replication-vip-18" \
        pgdatabase="postgres" \
        migration_dbuser="pgmigrate" \
        migration_dbpassword="SecurePassword" \
    meta \
        target-role=Stopped \
        migration-threshold=3 \
        failure-timeout=300s
```

## Usage

### Start Migration

```bash
# Start forward replication
crm resource start migration-forward

# Monitor progress
crm resource status migration-forward
journalctl -u pacemaker -f | grep migration-forward
```

### Trigger Cutover

```bash
# When ready to switch to target cluster
crm_attribute -n migration-trigger -v start_cutover -l reboot

# Monitor cutover progress (completes in seconds)
journalctl -u pacemaker -f | grep cutover
```

### Verify Migration

```bash
# Check production VIP points to target
crm status | grep postgres-vip

# Verify reverse replication
ssh root@<target-primary> "sudo -u postgres psql -x -c \
  'SELECT * FROM pg_stat_subscription;'"

# Test reverse DDL replication
ssh root@<target-primary> "sudo -u postgres psql -c \
  'CREATE TABLE migration_test (id INT);'"
  
ssh root@<source-primary> "sudo -u postgres psql -c \
  '\\d migration_test'"  # Should exist
```

## Configuration Parameters

### Required

- `source_cluster` - Source cluster resource name (e.g., "postgres-clone")
- `target_cluster` - Target cluster resource name (e.g., "postgres-clone-18")
- `production_vip_resource` - Production VIP resource name
- `source_replication_vip_resource` - Source replication VIP
- `target_replication_vip_resource` - Target replication VIP

### Optional

- `pgdatabase` - Database name (default: "postgres")
- `migration_dbuser` - Migration user (default: "pgmigrate")
- `migration_dbpassword` - Migration password
- `pgport` - PostgreSQL port (default: 5432)
- `source_node_role` - Source node to use: "Promoted" or "Unpromoted" (default: "Promoted")

## Version History

- **v1.0.0** (2025-12-28) - Initial release
- **v1.0.1** (2025-12-29) - Log retention enhancements
- **v1.0.2** (2025-12-30) - Production cutover validation
- **v1.0.3** (2026-01-02) - Completion detection + reliability
- **v1.0.4** (2026-01-02) - Bidirectional DDL replication
- **v1.0.5** (2026-01-02) - Cutover window optimization
- **v1.0.6** (2026-01-02) - Self-healing + cluster attribute fix

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
```

### Cutover fails

```bash
# Check cutover logs
tail -f /var/lib/pgsql/.cutover.log

# Check replication lag
ssh root@<target-primary> "sudo -u postgres psql -c \
  'SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;'"
```

### Reverse replication not working

```bash
# Check reverse subscription
ssh root@<source-primary> "sudo -u postgres psql -x -c \
  'SELECT * FROM pg_stat_subscription;'"

# Check reverse DDL trigger
ssh root@<target-primary> "sudo -u postgres psql -c \
  'SELECT evtname, evtenabled FROM pg_event_trigger;'"

# Restart migration resource to trigger reconciliation (v1.0.6+)
crm resource start migration-forward
```

## License

GPL-2.0-or-later

## Support

For issues and questions:
- GitHub: https://github.com/anthropics/pgtwin (if published)
- Documentation: See MIGRATION_DOCUMENTATION_INDEX.md

---

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication**
