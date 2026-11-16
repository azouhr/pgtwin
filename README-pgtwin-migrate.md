# pgtwin-migrate

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

> **WARNING**: pgtwin-migrate v2.1.0 is EXPERIMENTAL. Test thoroughly before production use. The package moves to
> 2.x once pgtwin-migrate is considered stable.

## Overview

pgtwin-migrate enables **PostgreSQL migrations with a short cutover window** by orchestrating logical replication between two parallel PostgreSQL clusters managed by Pacemaker. It handles the complete migration lifecycle: forward replication, cutover automation, and reverse replication for fallback scenarios.

### Use Cases

- **Major version upgrades** (e.g., PostgreSQL 17 → 18)
- **Vendor migrations** (e.g., on-premise → cloud)
- **Hosting provider changes** (e.g., AWS RDS → self-hosted)
- **Architecture changes** (e.g., physical → containerized)

### Key Features

- ✅ **Short downtime** - Applications keep running during the copy; only the cutover needs a short quiesce
  (see [Cutover Phase](#3-cutover-phase-automated))
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

**What the agent does (v2.1.0):**

0. Waits until the new production cluster is stable and the mirror has caught up (up to `stability_timeout`),
   and creates the replication slots of the new direction on it in advance
1. Sets the old production read-only (verified) and ends open client sessions over TCP; their open
   transactions roll back, so no commit is acknowledged after this point. The migration user is exempted
   (`ALTER ROLE ... SET default_transaction_read_only = off`)
2. Waits until every slot of the old direction has confirmed the WAL position taken after step 1; aborts if a
   slot is missing or the publisher does not answer
3. Deletes the old direction (publications, subscriptions, slots, DDL trigger)
4. Creates the new direction on the slots from step 0 (no data copy, no schema copy), advances the slots to
   the current position and enables the subscriptions; checks that every slot exists
5. Swaps the `ip=` values of the two VIP resources
6. Sets the old production read-write again (it is now the subscriber) and updates the CIB state

Any failure before step 5 sets the old production read-write again and leaves the VIP where it was. Clients
see "cannot execute ... in a read-only transaction" errors and one refused connection during the window, never
an acknowledgement that is later lost. Lab (three databases, writer through the VIP): about 11 s without an
acknowledged write, 0 acknowledged commits lost in four cutovers.

The window grows with the number of databases (about 2 s each in step 4). The monitor starts a requested cutover
only every 5th monitor cycle (about 2.5 minutes at a 30 s interval).

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
# Copy to a new file and rename it: a monitor running while the file is overwritten in place
# reads a half-written agent and fails hard (Pacemaker then moves the primary)
sudo install -m 755 pgtwin-migrate /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate.new && sudo mv /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate.new /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate

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
        target_vip_resource="postgres-vip-18" \
        source_replication_vip="192.168.60.10" \
        target_replication_vip="192.168.60.20" \
        source_pgpassfile="/var/lib/pgsql/.pgpass" \
        target_pgpassfile="/var/lib/pgsql/.pgpass" \
        migration_dbuser="pgmigrate" \
    op start timeout=120s \
    op stop timeout=60s \
    op monitor interval=30s timeout=60s \
    meta \
        target-role=Stopped \
        migration-threshold=3 \
        failure-timeout=300s
```

The `op monitor` line is required: the monitor checks the mirror and starts a requested cutover. Without it a
change of `production_cluster` only restarts the resource and nothing else happens (lab 2026-11-16).

`production_vip_resource` and `target_vip_resource` must both already exist
as Pacemaker `IPaddr2` primitives before starting the migration resource,
each colocated with its own cluster's Promoted role (see
[Preparing the clusters](#preparing-the-clusters)). Cutover works by swapping the two resources' `ip=`
values, not by moving either resource - without that colocation the IP swap
still happens but the resource carrying the production address can end up
running on an arbitrary node instead of the actual new primary.

`source_replication_vip`/`target_replication_vip` are plain IP addresses
(not resource names) and `source_pgpassfile`/`target_pgpassfile` are not
auto-discovered from the corresponding `pgtwin` primitive despite the
`ocf-tester`-visible parameter descriptions suggesting otherwise - set them
explicitly. Authentication uses `.pgpass` (matching the main `pgtwin` RA),
there is no `migration_dbpassword` parameter.

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
| `production_vip_resource` | Production VIP resource name - must already exist as an `IPaddr2` primitive colocated with `source_cluster`'s Promoted role | `postgres-vip` |
| `target_vip_resource` | The VIP resource that gets swapped with `production_vip_resource` during cutover - must already exist as an `IPaddr2` primitive colocated with `target_cluster`'s Promoted role | `postgres-vip-18` |
| `source_replication_vip` | IP address (not a resource name) used to reach the source cluster's primary for logical replication | `192.168.60.10` |
| `target_replication_vip` | IP address (not a resource name) used to reach the target cluster's primary for logical replication | `192.168.60.20` |
| `source_pgpassfile` | Path to the `.pgpass` file to use against the source cluster - not auto-discovered, must be set explicitly | `/var/lib/pgsql/.pgpass` |
| `target_pgpassfile` | Path to the `.pgpass` file to use against the target cluster - not auto-discovered, must be set explicitly | `/var/lib/pgsql/.pgpass` |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `databases` | (auto-discover) | Comma-separated list of databases. If not set, discovers from production cluster. |
| `migration_dbuser` | `pgmigrate` | Migration user for logical replication. Authenticates via `.pgpass` - there is no `migration_dbpassword` parameter. |
| `pgport` | `5432` | PostgreSQL port |
| `source_node_role` | `Promoted` | Source node to use: "Promoted" or "Unpromoted" |
| `finalize_replication` | `false` | When true, stop cleans up all replication infrastructure |
| `stability_timeout` | `300` | Seconds to wait for cluster stability before cutover |

### v2.0 Parameter Changes

| Change | Parameter | Notes |
|--------|-----------|-------|
| **NEW** | `production_cluster` | Which cluster should be production. Changing triggers cutover. |
| **NEW** | `finalize_replication` | When true, stop cleans up all replication infrastructure. |
| **NEW** | `stability_timeout` | Seconds to wait for cluster stability before cutover. |
| **REMOVED** | `cutover_ready` | Replaced by `production_cluster` |
| **CHANGED** | `databases` | Now optional - auto-discovers if not specified |

## Version History

- **v2.1.0** (2026-11-16, pgtwin 1.8.4) - **EXPERIMENTAL**, review requested
  - Cutover: no acknowledged commit lost (read-only that works, sync check on the publisher's slots, no copy
    for a direction created by a cutover, slots checked before the VIP swap); write window about 11 s
  - A missing slot or subscription is reported ("Mirror incomplete"), not recreated at the current position
  - No automatic stop after a cutover; the monitor checks the active direction
  - Sanity checks on start, `validate-all` and before every cutover: both clusters are pgtwin clones with
    `node_list` naming their own two nodes, no overlap, each clone runs only on its list; pgtwin 1.8.4 or newer;
    `resource-discovery=never` protection for every node outside a clone's `node_list`; a warning when corosync
    has more than two votes and `no-quorum-policy` is not `ignore`
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

- [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - conceptual overview of pgtwin and pgtwin-migrate
- [doc/FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md](doc/FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md) - multi-database migration
- [doc/BUGFIX_AUTO_STOP_TIMING_v1.0.7.md](doc/BUGFIX_AUTO_STOP_TIMING_v1.0.7.md) - auto-stop timing
- [doc/STATE_MATRIX.md](doc/STATE_MATRIX.md) - cluster states, including four nodes with a logical subscriber (section 7)

## Requirements

- Two pgtwin-managed PostgreSQL clusters (source and target) in one Pacemaker cluster, both healthy.
- Source and target can run the same or different PostgreSQL major versions (logical replication).
- `pgtwin-migrate` installed on every node of both clusters.

The steps below are what the 2026-11 lab setup (PG17 pair pg1/pg2, PG18 pair pg3/pg4) needed.

## Preparing the clusters

### 1. Add the target nodes to the existing cluster

Before the new nodes join, keep each pair's resources off the other pair, and stop Pacemaker from even probing
them there. Without `resource-discovery=never`, a probe of the PG17 resource on a PG18 node finds a running
PostgreSQL and can trigger recovery actions against the wrong cluster:

```bash
crm configure location postgres-avoid-pg3 postgres-clone resource-discovery=never -inf: pg3
crm configure location postgres-avoid-pg4 postgres-clone resource-discovery=never -inf: pg4
crm configure location vip-avoid-pg3 vip resource-discovery=never -inf: pg3
crm configure location vip-avoid-pg4 vip resource-discovery=never -inf: pg4
```

Extend the fence devices (host map or host list) to the new nodes. A clone meant for every node, such as a ping
clone, must not keep `clone-max=2`.

Then join each new node with `crm cluster join -c <existing node>`. crmsh changes cluster properties on join:

| Property | Before | After join | Action |
|----------|--------|------------|--------|
| `no-quorum-policy` | `ignore` | deleted | set again after the last join |
| `priority-fencing-delay` | e.g. `5` | `0` | set again |
| `rsc_defaults priority` | e.g. `1` | `0` | set again |
| `fencing-timeout` | e.g. `30` | recalculated (69 in the lab) | check the value |
| corosync `two_node` | `1` | off (4 votes, quorum 3) | expected |

```bash
crm configure property no-quorum-policy=ignore priority-fencing-delay=5
crm configure rsc_defaults priority=1
```

**Both** pgtwin clones need `node_list` with the two nodes of their own pair (`node_list="pg1 pg2"` on the
source, `node_list="pg3 pg4"` on the target) **before the third node joins**. From pgtwin 1.8.4 on, a clone
without `node_list` refuses to start in a cluster of more than two nodes, and its monitor logs an error. Before
1.8.4, pgtwin took the first other node of the whole cluster as its peer, which in the lab made a PG18 node
record a PG17 node and promote without checking its own standby (481 acknowledged commits lost). Check:

```bash
crm configure show | grep -E '^primitive|node_list'
```

pgtwin-migrate 2.1.0 checks this, the probe protection below and the pgtwin version on start, on
`validate-all` and before every cutover, and refuses with the reason. To check before creating the resource:
`crm_resource -r migration-forward --validate`.

Create the target pgtwin clone with `node_list` set to the target nodes, and keep it and its VIP off the source
nodes the same way. The first standby start can run while the new primary is still promoting. It then fails with
"unable to discover primary" and is retried only after `failure-timeout`; a
`crm resource cleanup <target-clone>` after the promote shortens this.

### 2. `wal_level = logical`

The source needs `wal_level = logical`, and so does the target for the reverse direction after cutover. Put it
into `postgresql.custom.conf` on **both** nodes of each pair. `ALTER SYSTEM` on the primary only does not reach
the standby, which then runs with a different setting after the next switchover.

```ini
# postgresql.custom.conf, every node of both clusters
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
max_logical_replication_workers = 10
```

`wal_level` needs a restart. Restart node by node: the standby first, then the old primary, so the standby
takes over in between. Do not use `crm resource restart` of the clone, which stops production:

```bash
crm node standby <standby-node>; crm node online <standby-node>   # wait until it streams again
crm node standby <primary-node>; crm node online <primary-node>   # the standby takes over
```

### 3. Migration user, `pg_hba.conf`, `.pgpass`

Create a superuser for the migration on both primaries. It creates publications, subscriptions and event
triggers:

```sql
CREATE ROLE pgmigrate WITH LOGIN SUPERUSER PASSWORD '...';
```

The cutover sets the old production read-only and exempts this user with
`ALTER ROLE pgmigrate SET default_transaction_read_only = off` (2.1.0 does this itself), so that it can drop the
old direction and create the new one there. Applications must not use this role: its sessions are neither
read-only nor ended during the cutover. Logical replication does not copy roles: create the application roles
on both clusters.

The agent connects to **every** migrated database, not only to `postgres`. Allow the user for all databases on
both nodes of each pair, then reload. `pg_hba.conf` is not replicated, and a node that becomes primary later
needs the line too:

```
host  all  pgmigrate  <node and VIP network>  scram-sha-256
```

`.pgpass` on every node, owned by postgres, mode 0600, with `*` as the database:

```
<source-replication-vip>:5432:*:pgmigrate:<password>
<target-replication-vip>:5432:*:pgmigrate:<password>
<each node address>:5432:*:pgmigrate:<password>
```

The target nodes also need their own `replicator` lines for pgtwin's physical replication (see QUICKSTART.md).

### 4. Replication VIPs

`source_replication_vip` and `target_replication_vip` are IP addresses that always point to the primary of their
own cluster. They must be separate from the production VIPs, because those are swapped at cutover:

```bash
crm configure primitive vip17-repl IPaddr2 params ip=192.168.122.22 cidr_netmask=24 op monitor interval=10s
crm configure colocation vip17-repl-with-primary inf: vip17-repl postgres-clone:Promoted
crm configure order vip17-repl-after-promote Mandatory: postgres-clone:promote vip17-repl:start
# the same for the target (vip18-repl with pg18-clone); keep each VIP off the other pair
```

Check both before starting the migration resource:

```bash
sudo -u postgres psql -h <source-replication-vip> -U pgmigrate -d postgres -c 'select version()'
sudo -u postgres psql -h <target-replication-vip> -U pgmigrate -d postgres -c 'select version()'
```

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

## Known Limitations (v2.1)

- **Failover of the publishing pair loses the mirror.** Logical slots exist only on the primary; after a failover
  the new primary has none. pgtwin-migrate reports "Mirror incomplete" instead of recreating the slot (which
  would hide a gap). Resync: stop the resource, empty the replicated tables (or drop the database) on the
  non-production side, start again. Failover slots (PostgreSQL 17+) are planned. The `postgres` database
  should be emptied, not dropped.
- **Sequences and roles are not replicated** (logical replication). Set sequences above the source value before
  a cutover; create application roles on both clusters.
- **`pg_bindir` is not in pgtwin's metadata**: `crm configure` rejects it; set it with
  `crm_resource --set-parameter` when the second cluster runs another PostgreSQL version.
- **The cutover window grows with the number of databases** (about 2 s each), and a requested cutover starts
  with the next 5th monitor cycle.

1. **max_logical_replication_workers limit** - PostgreSQL default is 4 workers. For migrations with many databases, increase this setting in `postgresql.custom.conf`.

2. **Initial sync for new databases** - When a new database is created, `copy_data=true` handles initial sync, but the database must exist on both clusters (subscriber creates it automatically).

3. **Schema changes during migration** - DDL triggers handle most schema changes, but complex migrations may need manual coordination.

## Migration from v1.x

1. Complete any in-progress migrations
2. Stop and delete old migration resource
3. Deploy pgtwin-migrate v2.1
4. Use pgtwin-migrate-setup to generate new configuration
5. Test with non-production data first

**Breaking changes:**
- `cutover_ready` parameter removed - use `production_cluster` instead
- Cutover triggered by changing `production_cluster`, not setting a trigger attribute

## License

GPL-2.0-or-later

## Support

For issues and questions:
- GitHub: https://github.com/azouhr/pgtwin/issues

---

**pgtwin-migrate v2.1.0 (EXPERIMENTAL) - Pacemaker OCF agent for PostgreSQL cluster migrations via logical replication**
