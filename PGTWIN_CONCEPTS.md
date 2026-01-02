# pgtwin PostgreSQL High Availability: Conceptual Overview

**Document Purpose**: Explain the conceptual design and implementation philosophy of the pgtwin OCF agents for PostgreSQL high availability and migration.

**Audience**: System administrators, DBAs, architects who need to understand how pgtwin works

**Version**: 1.0
**Date**: 2025-12-27
**Status**: Documentation

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [The pgtwin OCF Agent](#2-the-pgtwin-ocf-agent)
3. [The pgtwin-migrate OCF Agent](#3-the-pgtwin-migrate-ocf-agent)
4. [How They Work Together](#4-how-they-work-together)
5. [Core Design Principles](#5-core-design-principles)

---

## 1. Introduction

The pgtwin project provides two OCF (Open Cluster Framework) resource agents that work with Pacemaker to deliver high availability and zero-downtime migration for PostgreSQL:

1. **pgtwin** - The core HA agent that manages individual PostgreSQL instances
2. **pgtwin-migrate** - The migration orchestrator that coordinates upgrades between clusters

Both agents are designed around a philosophy of **intelligent automation** - they handle complex PostgreSQL operations automatically while maintaining safety and providing clear visibility into cluster state.

### What is an OCF Resource Agent?

An OCF resource agent is a standardized script that Pacemaker uses to manage a service. It implements five key operations:

- **start**: Start the service
- **stop**: Stop the service
- **monitor**: Check if the service is running and healthy
- **promote**: Promote a standby to primary (for promotable clones)
- **demote**: Demote a primary to standby (for promotable clones)

Pacemaker calls these operations to maintain cluster state, handle failures, and execute administrative actions.

---

## 2. The pgtwin OCF Agent

### 2.1 Core Philosophy

**pgtwin is designed to make PostgreSQL HA "just work".**

Traditional PostgreSQL HA setups require extensive manual intervention:
- Manually rebuild standbys after failures
- Manually run pg_rewind after divergence
- Manually configure replication settings
- Manually initialize new nodes

**pgtwin eliminates these manual steps** through intelligent automation:

```
Administrator's perspective:
  1. Install PostgreSQL on nodes
  2. Configure pgtwin resource
  3. Start cluster
  → Everything else is automatic
```

### 2.2 Key Concepts

#### 2.2.1 Promotable Clone Resource

pgtwin is deployed as a **promotable clone** in Pacemaker:

```
Clone Set: postgres-clone [postgres-db] (promotable)
  * Promoted:  [ node1 ]     ← Primary (read/write)
  * Unpromoted: [ node2 ]    ← Standby (read-only replica)
```

**What this means:**
- Same resource runs on multiple nodes simultaneously
- Exactly ONE instance is "Promoted" (the primary)
- All other instances are "Unpromoted" (standbys)
- Pacemaker ensures this constraint is maintained
- Automatic failover when primary fails

**Why promotable clone?**
- PostgreSQL's primary/standby model maps perfectly to promoted/unpromoted
- Pacemaker understands this relationship and enforces it
- Enables coordinated operations (VIP follows promoted node, monitoring differs by role)

#### 2.2.2 Physical Replication with Slots

pgtwin uses PostgreSQL's **physical streaming replication** for data synchronization:

```
Primary (Promoted)                  Standby (Unpromoted)
┌────────────────────┐             ┌────────────────────┐
│ Receives writes    │             │ Receives WAL       │
│ Generates WAL      │────WAL─────>│ Replays WAL        │
│ Holds repl slot────┼─────────────┼─>Connects via slot │
└────────────────────┘             └────────────────────┘
```

**Replication Slots** are critical:
- Prevent WAL files from being recycled while standby is offline
- Enable standby to catch up after brief disconnections
- Automatically created/managed by pgtwin
- Automatically cleaned up when excessive (prevents disk fill)

**Why physical (not logical)?**
- Byte-identical replica (all databases, all tables, all objects)
- Lower overhead than logical replication
- Crash recovery replay works identically on standby
- Supports pg_rewind for timeline divergence recovery

#### 2.2.3 Automatic Standby Initialization

**The Problem**: Traditional HA requires manual steps to create a standby:

```bash
# Traditional approach (10+ manual steps):
ssh standby-node
sudo -u postgres pg_basebackup -h primary -D /var/lib/pgsql/data ...
sudo -u postgres vi /var/lib/pgsql/data/postgresql.auto.conf  # Edit settings
sudo -u postgres touch /var/lib/pgsql/data/standby.signal
sudo systemctl start postgresql
# ... verify, troubleshoot, repeat ...
```

**pgtwin's Solution**: Zero-touch initialization

```bash
# pgtwin approach (1 command):
crm node online standby-node
# → pgtwin detects empty PGDATA
# → Discovers primary from cluster state
# → Runs pg_basebackup automatically
# → Configures replication settings
# → Creates standby.signal
# → Starts PostgreSQL
# → Standby is online and replicating
```

**How it works:**
1. `pgsql_start()` checks if PGDATA is valid
2. If empty/missing/invalid → triggers auto-initialization
3. Discovers primary node from Pacemaker CIB (cluster information base)
4. Retrieves replication credentials from `.pgpass`
5. Runs `pg_basebackup` asynchronously (to avoid monitor timeouts)
6. Tracks progress via state file (`.basebackup_in_progress`)
7. Finalizes configuration when basebackup completes
8. Starts PostgreSQL automatically

**Use cases:**
- Fresh cluster setup (just bring nodes online)
- Disk replacement (mount new disk, bring node online)
- Data corruption recovery (rm -rf data, bring node online)
- Cloning cluster (copy pgtwin config, bring nodes online)

#### 2.2.4 Timeline Divergence and pg_rewind

**The Problem**: After a failover, the old primary may have diverged from the new primary:

```
Timeline 1 (before failover):
  Primary:  ──A──B──C──✗ (crashed)
  Standby:  ──A──B──C

Timeline 2 (after failover):
  Old Primary:  ──A──B──C──D──E  (has D,E that standby never saw)
  New Primary:  ──A──B──C──F──G  (has F,G that old primary never saw)
                           ↑
                    Divergence point
```

**Traditional Solution**: Rebuild old primary from scratch (pg_basebackup)

**pgtwin's Solution**: Use pg_rewind to reconcile timelines

```bash
# pgtwin automatically:
1. Detects divergence (timeline check in pgsql_demote)
2. Runs pg_rewind to sync from new primary
3. Replays necessary WAL to reconcile
4. Starts as standby
# → Fast recovery (seconds to minutes vs. hours for pg_basebackup)
```

**How pg_rewind works:**
- Compares data files between old and new primary
- Copies only diverged blocks (not entire database)
- Rewinds old primary to divergence point
- Replays WAL from new primary to catch up
- Much faster than full pg_basebackup

**Requirements for pg_rewind:**
- `wal_log_hints = on` (or checksums enabled)
- Replication user has `pg_read_all_data` role
- Replication user has permissions on pg_rewind functions

**Fallback**: If pg_rewind fails, pgtwin falls back to pg_basebackup

#### 2.2.5 Replication Health Monitoring

pgtwin doesn't just check "is PostgreSQL running?" - it monitors **replication health**:

**On Primary (Promoted):**
```sql
-- Every monitor cycle checks:
SELECT * FROM pg_stat_replication;

-- Monitors:
- Is standby connected?
- What is replication state? (streaming, catchup, etc.)
- What is replication lag? (bytes behind)
- Is standby synchronous or async?
```

**On Standby (Unpromoted):**
```sql
-- Every monitor cycle checks:
SELECT * FROM pg_stat_wal_receiver;

-- Monitors:
- Is receiver process running?
- Are we connected to primary?
- What is our replay lag?
- Are we receiving WAL?
```

**Automatic Recovery**: If replication fails for consecutive monitor cycles (threshold configurable), pgtwin automatically triggers recovery:

```
Monitor cycle 1: Replication broken → Counter: 1
Monitor cycle 2: Replication broken → Counter: 2
Monitor cycle 3: Replication broken → Counter: 3
...
Monitor cycle 5: Replication broken → Counter: 5 (threshold reached)
  → Trigger automatic recovery:
    1. Try pg_rewind (fast)
    2. If pg_rewind fails → pg_basebackup (slow but reliable)
    3. Restart PostgreSQL
    4. Resume replication
```

**Why this matters:**
- Prevents "split-brain" scenarios (standby thinks it's in sync, but isn't)
- Catches replication failures before they become critical
- Automatic healing reduces administrator workload
- Configurable threshold balances sensitivity vs. false positives

#### 2.2.6 Configuration Validation

pgtwin validates PostgreSQL configuration on every start to catch dangerous settings:

**Critical Validations** (hard errors - prevent startup):
```bash
restart_after_crash = off  # MUST be off (Pacemaker manages restarts)
```
**Why critical?** If `restart_after_crash = on`, PostgreSQL and Pacemaker compete to manage the service, leading to potential split-brain.

**Warning Validations** (log warnings, but allow startup):
```bash
wal_sender_timeout >= 10000ms     # Prevent false disconnections
max_standby_streaming_delay != -1  # Prevent unbounded lag
archive_command has error handling # Prevent archive failures from blocking writes
```

**Runtime Monitoring:**
- Tracks archive command failures
- Warns when failures accumulate (indicates backup issues)

**Philosophy**: Catch configuration problems early, before they cause outages

#### 2.2.7 Container Mode Support

pgtwin supports running PostgreSQL in **containers** (Podman or Docker):

```
Traditional (bare-metal):              Container mode:
┌──────────────────────┐              ┌──────────────────────┐
│ pgtwin               │              │ pgtwin               │
│   ↓                  │              │   ↓                  │
│ pg_ctl → PostgreSQL  │              │ podman → container   │
│   ↓                  │              │   ↓                  │
│ /var/lib/pgsql/data  │              │ PostgreSQL           │
└──────────────────────┘              │   ↓                  │
                                      │ /var/lib/pgsql/data  │
                                      │ (bind mount)         │
                                      └──────────────────────┘
```

**How it works:**
- pgtwin detects `container_mode = true` parameter
- Loads `pgtwin-container-lib.sh` library
- All PostgreSQL commands (pg_ctl, psql, pg_basebackup) are **wrapped**
- Wrapper transparently routes commands into container
- **No code changes** in pgtwin core - same logic works for both modes

**Container lifecycle:**
```bash
# Start:
pgtwin → podman create + podman start (if not exists)
       → podman exec pg_ctl start (if container exists)

# Stop:
pgtwin → podman exec pg_ctl stop
       → (container remains running for monitoring)

# Monitor:
pgtwin → podman exec psql -c "SELECT pg_is_in_recovery()"
```

**Security model:**
- Container runs as host's postgres UID:GID (using `--user` flag)
- PGDATA owned by host's postgres user
- No file ownership changes needed
- Same security boundary as bare-metal

**Why container mode?**
- Multiple PostgreSQL versions on same host (PG17 + PG18 for migration)
- Simplified deployment (no PostgreSQL packages needed)
- Consistent environment across nodes
- Easier testing and development

#### 2.2.8 Synchronous vs. Asynchronous Replication

pgtwin supports both replication modes:

**Asynchronous (default)**:
```
Primary                           Standby
┌────────────────┐               ┌────────────────┐
│ Write WAL      │──────────────>│ Receive WAL    │
│ Commit ✓       │ (no wait)     │ Replay WAL     │
└────────────────┘               └────────────────┘
    ↑
    Client gets confirmation immediately
```
- **Fast**: Commits don't wait for standby
- **Risk**: Data loss if primary fails before standby receives WAL
- **Best for**: Low-latency requirements, acceptable data loss window

**Synchronous** (enabled via `rep_mode=sync`):
```
Primary                           Standby
┌────────────────┐               ┌────────────────┐
│ Write WAL      │──────────────>│ Receive WAL    │
│ Wait for sync  │<─────ACK──────│ ACK receipt    │
│ Commit ✓       │               │ Replay WAL     │
└────────────────┘               └────────────────┘
    ↑
    Client waits for standby acknowledgment
```
- **Safe**: Zero data loss (standby has WAL before commit)
- **Slower**: Commits wait for network round-trip
- **Risk**: Primary blocks if standby fails (no standby = no writes)

**Pacemaker Notify Support** (v1.6.6+):
pgtwin uses Pacemaker's notify feature to dynamically switch sync mode:

```bash
# When both nodes healthy:
synchronous_standby_names = 'node2'  # Sync mode enabled

# When standby fails:
→ Pacemaker sends "post-stop" notify
→ pgtwin receives notification
→ ALTER SYSTEM SET synchronous_standby_names = '';  # Sync mode disabled
→ Reload PostgreSQL
→ Primary continues accepting writes (async mode)

# When standby recovers:
→ Pacemaker sends "post-start" notify
→ pgtwin receives notification
→ ALTER SYSTEM SET synchronous_standby_names = 'node2';  # Sync mode re-enabled
→ Reload PostgreSQL
→ Resume synchronous replication
```

**Why this matters:**
- Prevents write blocking when standby fails
- Automatic fallback to async mode (availability over consistency)
- Automatic restoration to sync mode (consistency when possible)
- No administrator intervention required

#### 2.2.9 VIP (Virtual IP) Management

pgtwin coordinates with Pacemaker's IPaddr2 resource agent to manage Virtual IPs:

```
Cluster State:                   VIP Placement:
┌──────────────────┐            ┌────────────────┐
│ node1 (Promoted) │◄───────────│ VIP: 10.0.0.10 │
└──────────────────┘            └────────────────┘
┌──────────────────┐
│ node2 (Unpromoted)│
└──────────────────┘

After Failover:
┌──────────────────┐
│ node1 (Unpromoted)│
└──────────────────┘
┌──────────────────┐            ┌────────────────┐
│ node2 (Promoted) │◄───────────│ VIP: 10.0.0.10 │
└──────────────────┘            └────────────────┘
```

**Colocation Constraint**: Ensures VIP follows promoted node
```bash
crm configure colocation vip-with-promoted inf: \
  postgres-vip postgres-clone:Promoted
```

**Ordering Constraint**: Ensures correct startup sequence
```bash
crm configure order promote-before-vip Mandatory: \
  postgres-clone:promote postgres-vip:start
```

**Why VIPs?**
- Clients connect to VIP (not node-specific IP)
- VIP automatically moves during failover
- No client reconfiguration needed
- Zero-downtime failover from client perspective

### 2.3 State Machine and Lifecycle

pgtwin implements a clear state machine for PostgreSQL lifecycle:

```
┌─────────────────────────────────────────────────────────────┐
│                      STOPPED STATE                          │
│  PostgreSQL not running                                     │
└──────────────────────┬──────────────────────────────────────┘
                       │ start operation
                       ↓
              ┌────────────────┐
              │ PGDATA valid?  │
              └────┬───────┬───┘
                   │       │
             NO ←──┘       └──→ YES
              │                 │
              ↓                 ↓
    ┌──────────────────┐  ┌─────────────────┐
    │ Auto-initialize  │  │ Start PostgreSQL│
    │ (pg_basebackup)  │  │ as standby      │
    └────────┬─────────┘  └────────┬────────┘
             │                     │
             └──────────┬──────────┘
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   UNPROMOTED STATE                          │
│  PostgreSQL running as standby                              │
│  - Replaying WAL from primary                               │
│  - Read-only queries allowed                                │
│  - Monitor checks replication health                        │
└──────────────────────┬──────────────────────────────────────┘
                       │ promote operation
                       ↓
              ┌────────────────────┐
              │ pg_ctl promote     │
              │ (remove standby    │
              │  signal)           │
              └────────┬───────────┘
                       ↓
┌─────────────────────────────────────────────────────────────┐
│                    PROMOTED STATE                           │
│  PostgreSQL running as primary                              │
│  - Accepts write operations                                 │
│  - Streams WAL to standby                                   │
│  - Manages replication slot                                 │
│  - Monitor checks replication health                        │
└──────────────────────┬──────────────────────────────────────┘
                       │ demote operation
                       ↓
              ┌────────────────────┐
              │ Stop PostgreSQL    │
              │ Check timeline     │
              │ pg_rewind if needed│
              │ Create standby     │
              │ signal             │
              └────────┬───────────┘
                       ↓
       (returns to UNPROMOTED STATE)
```

**Key Transitions:**

**STOPPED → UNPROMOTED** (start):
- Validate PGDATA (or auto-initialize if empty)
- Validate PostgreSQL version matches data directory
- Start PostgreSQL
- Verify replication connection

**UNPROMOTED → PROMOTED** (promote):
- Update application_name in config
- Run `pg_ctl promote` (removes standby.signal)
- Create replication slot for standby
- Verify promotion successful

**PROMOTED → UNPROMOTED** (demote):
- Stop PostgreSQL
- Check timeline divergence
- Run pg_rewind if needed (or pg_basebackup as fallback)
- Create standby.signal
- Update primary_conninfo to new primary
- Start as standby

### 2.4 Failure Handling

pgtwin handles various failure scenarios automatically:

#### 2.4.1 Primary Failure

```
1. Primary crashes
   → Pacemaker monitor detects failure
   → Pacemaker stops primary resource
   → Pacemaker promotes standby
   → pgtwin promotes PostgreSQL (pg_ctl promote)
   → VIP moves to new primary
   → Clients reconnect to VIP (now on new primary)

2. Old primary returns
   → Pacemaker starts pgtwin on old primary
   → pgtwin detects timeline divergence
   → Runs pg_rewind to reconcile
   → Starts as standby
   → Begins replicating from new primary
```

#### 2.4.2 Standby Failure

```
1. Standby crashes
   → Primary continues serving (async mode) or blocks writes (sync mode)
   → If sync mode + notify enabled:
     - Pacemaker sends post-stop notification
     - Primary disables sync replication
     - Primary continues accepting writes

2. Standby returns
   → pgtwin starts PostgreSQL
   → Standby connects to primary
   → Standby catches up via replication slot
   → If sync mode + notify enabled:
     - Pacemaker sends post-start notification
     - Primary re-enables sync replication
```

#### 2.4.3 Replication Failure

```
1. Replication breaks (network issue, slot loss, etc.)
   → Monitor detects failed replication
   → Increment failure counter
   → Counter reaches threshold (default: 5 consecutive cycles)
   → Trigger automatic recovery:
     a. Try pg_rewind (fast)
     b. If pg_rewind fails → pg_basebackup (slow but reliable)
   → Restart PostgreSQL
   → Resume replication
```

#### 2.4.4 Split-Brain Prevention

pgtwin relies on Pacemaker's quorum and STONITH to prevent split-brain:

```
Two-node cluster with SBD (STONITH Block Device):

Node1 loses network:
  → Cannot reach Node2
  → Cannot reach SBD device
  → Pacemaker self-fences (commits suicide)
  → Node2 continues as primary

Node2 loses network:
  → Cannot reach Node1
  → CAN reach SBD device
  → Uses SBD to fence Node1
  → Node2 becomes/remains primary
```

**Requirements**:
- STONITH must be enabled (`stonith-enabled=true`)
- Quorum must be enforced
- SBD or other fencing mechanism configured

### 2.5 Key Features Summary

| Feature | Purpose | How it Works |
|---------|---------|-------------|
| **Auto-initialization** | Zero-touch standby setup | Detects empty PGDATA, runs pg_basebackup automatically |
| **pg_rewind** | Fast failover recovery | Reconciles timeline divergence without full rebuild |
| **Replication monitoring** | Early failure detection | Monitors pg_stat_replication, auto-recovery on threshold |
| **Configuration validation** | Prevent dangerous configs | Validates settings on start, blocks startup if critical errors |
| **Container mode** | Run PostgreSQL in containers | Transparent command wrappers, same code for bare-metal and containers |
| **Notify support** | Dynamic sync/async switching | Receives Pacemaker notifications, adjusts sync mode automatically |
| **Slot management** | Prevent WAL loss | Creates/manages replication slots, auto-cleanup when excessive |
| **Timeline warning** | Early divergence detection | Non-blocking check warns of timeline issues before startup fails |
| **Version validation** | Prevent version mismatches | Validates data directory version matches binary/container |

---

## 3. The pgtwin-migrate OCF Agent

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

### 3.1 Core Philosophy

**pgtwin-migrate makes PostgreSQL major version upgrades safe and simple.**

Traditional PostgreSQL major version upgrades require downtime:
- Dump entire database (pg_dumpall)
- Install new PostgreSQL version
- Restore dump to new version
- Test application
- Switch production traffic
- **Downtime**: Hours to days depending on database size

**pgtwin-migrate enables zero-downtime upgrades** using logical replication:

```
Administrator's perspective:
  1. Deploy target cluster (new PostgreSQL version)
  2. Create pgtwin-migrate resource
  3. Wait for replication lag to drop
  4. Execute cutover (VIP migration)
  → Zero downtime from application perspective
```

### 3.2 Key Concepts

#### 3.2.1 Logical Replication

Unlike physical replication (binary WAL), **logical replication** streams **logical changes** (SQL statements):

```
Physical Replication:              Logical Replication:
┌────────────────┐                ┌────────────────┐
│ WAL: 0xAB3F... │───────────────>│ Replay binary  │
│ (binary data)  │                │ data           │
└────────────────┘                └────────────────┘
   Same version required            ↕ Different versions OK
   Byte-identical replica            ↕ Logical changes only

                                   ┌────────────────┐
                                   │ INSERT INTO    │
                                   │ UPDATE SET     │
                                   │ DELETE FROM    │
                                   └────────────────┘
```

**Why logical replication for upgrades?**
- Works across major PostgreSQL versions (PG17 → PG18)
- Each cluster uses its own on-disk format
- Allows testing on target before cutover
- Enables gradual migration (selective tables)
- Supports vendor migrations (EDB → Community PostgreSQL)

**Limitations**:
- Only replicates data changes (not DDL by default)
- Both clusters must run simultaneously
- Requires `wal_level = logical` on both sides
- More overhead than physical replication

#### 3.2.2 VIP Architecture for Migration

pgtwin-migrate uses a **three-VIP architecture**:

```
┌─────────────────────────────────────────────────────────────┐
│                   SOURCE CLUSTER (PG17)                     │
├─────────────────────────────────────────────────────────────┤
│ node1 (Primary)                  node2 (Standby)            │
│   ↓                                 ↓                       │
│ Application VIP              Source Repl VIP               │
│ 192.168.60.100 ◄─── Clients  192.168.60.104                │
│ (BEFORE cutover)              (for forward replication)     │
└───────────────────────────────────┬─────────────────────────┘
                                    │
                   Forward Logical Replication
                   (subscription on target)
                                    │
                                    ↓
┌─────────────────────────────────────────────────────────────┐
│                   TARGET CLUSTER (PG18)                     │
├─────────────────────────────────────────────────────────────┤
│ node1 (Primary)                  node2 (Standby)            │
│   ↓                                 ↓                       │
│ Application VIP              Target Repl VIP               │
│ 192.168.60.100 ◄─── Clients  192.168.60.105                │
│ (AFTER cutover)               (for reverse replication)     │
└─────────────────────────────────────────────────────────────┘
```

**Three VIP types:**

1. **Application VIP** (one, moves during cutover):
   - Where clients connect
   - Initially on source cluster
   - Moves to target cluster during cutover
   - IP address stays the same (transparent to clients)

2. **Source Replication VIP** (stays on source standby):
   - Attached to source cluster's standby node
   - Used for forward logical replication (target subscribes here)
   - Follows source standby (via colocation constraint)
   - Ensures subscription connects to available node during source failover

3. **Target Replication VIP** (stays on target standby):
   - Attached to target cluster's standby node
   - Used for reverse logical replication (source subscribes here)
   - Also used for pre-cutover testing
   - Follows target standby (via colocation constraint)

**Why replication VIPs on standbys?**
- **Traffic isolation**: Keeps replication traffic off primary
- **Availability**: VIP follows standby during target cluster failover
- **Testing**: Target replication VIP allows pre-cutover validation

#### 3.2.3 Bidirectional Replication

pgtwin-migrate sets up **bidirectional logical replication**:

```
Forward Replication (before cutover):
Source (PG17) ──────────────> Target (PG18)
- Source is PRIMARY (receives writes)
- Target is SUBSCRIBER (receives data)
- Lag monitored by pgtwin-migrate

Reverse Replication (for rollback safety):
Source (PG17) <────────────── Target (PG18)
- Target becomes publisher
- Source becomes subscriber
- Allows rollback if issues detected

After Cutover:
Source (PG17) <────────────── Target (PG18)
- Application VIP on target
- Writes go to target
- Source receives changes (safety backup)
- Can switch back if needed
```

**Why bidirectional?**
- **Rollback safety**: Can revert to source if target has issues
- **Data preservation**: Source stays synchronized
- **Confidence**: Administrators can test thoroughly before decommissioning source
- **Insurance**: Keep source as backup for days/weeks after cutover

#### 3.2.4 Publication and Subscription

Logical replication uses **publications** (on source) and **subscriptions** (on target):

**Publication** (on source/publisher):
```sql
-- Created by pgtwin-migrate on source
CREATE PUBLICATION pgtwin_migrate_forward_pub
  FOR ALL TABLES;
```
- Defines what to replicate (all tables, specific tables, etc.)
- Exists on the cluster that **has the data**
- Multiple subscriptions can subscribe to one publication

**Subscription** (on target/subscriber):
```sql
-- Created by pgtwin-migrate on target
CREATE SUBSCRIPTION pgtwin_migrate_forward_sub
  CONNECTION 'host=192.168.60.104 port=5432 dbname=postgres user=pgmigrate'
  PUBLICATION pgtwin_migrate_forward_pub
  WITH (copy_data = true, create_slot = true);
```
- Defines where to replicate from (connection string)
- Pulls data from publication
- Creates replication slot on publisher
- Copies existing data (copy_data = true)

**pgtwin-migrate's setup**:
```
Forward Replication:
  Source: CREATE PUBLICATION pgtwin_migrate_forward_pub
  Target: CREATE SUBSCRIPTION pgtwin_migrate_forward_sub

Reverse Replication:
  Target: CREATE PUBLICATION pgtwin_migrate_reverse_pub
  Source: CREATE SUBSCRIPTION pgtwin_migrate_reverse_sub
```

#### 3.2.5 Synchronous DDL Replication

**The Problem**: Logical replication only replicates **data changes** (INSERT/UPDATE/DELETE), not **schema changes** (CREATE TABLE/ALTER TABLE/DROP TABLE).

```
Source (PG17):
  CREATE TABLE new_table (id serial, data text);
  → Table created on source

Target (PG18):
  → Table NOT created (logical replication doesn't replicate DDL)
  → Subscription breaks (can't replicate data to non-existent table)
```

**pgtwin-migrate's Solution**: Event trigger + dblink for synchronous DDL replication

```sql
-- On source (or target, depending on direction):
CREATE FUNCTION replicate_ddl_to_target() RETURNS event_trigger AS $$
DECLARE
    ddl_command text;
BEGIN
    ddl_command := current_query();
    -- Send DDL to target using dblink
    PERFORM dblink_exec(
        'host=target_vip port=5432 dbname=postgres user=pgmigrate',
        ddl_command
    );
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER replicate_ddl_to_target_trigger
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE', 'DROP TABLE')
  EXECUTE FUNCTION replicate_ddl_to_target();
```

**How it works:**
1. User executes `CREATE TABLE` on source
2. PostgreSQL fires event trigger after DDL completes
3. Event trigger extracts DDL command (using `current_query()`)
4. Trigger uses dblink to execute same DDL on target
5. Table now exists on both sides
6. Logical replication can replicate data

**Circular DDL Issue**:
If both directions have DDL replication enabled:
```
Source executes: CREATE TABLE foo;
  → Trigger sends DDL to target
    → Target executes: CREATE TABLE foo;
      → Trigger sends DDL back to source
        → Source executes: CREATE TABLE foo; (ERROR: already exists)
          → DEADLOCK or INFINITE LOOP
```

**pgtwin-migrate's Solution**: Only enable reverse DDL (target → source)
- Before cutover: Applications write to source (no DDL replication needed)
- After cutover: Applications write to target (DDL replicates to source for safety)
- Prevents circular dependency

#### 3.2.6 Resource Colocation

pgtwin-migrate uses **colocation constraints** to ensure it runs on the correct cluster:

```bash
# Forward migration resource runs on TARGET cluster nodes
crm configure primitive migration-forward pgtwin-migrate \
  params source_cluster=postgres-clone target_cluster=postgres-clone-18 ...

crm configure colocation migration-forward-with-target inf: \
  migration-forward postgres-clone-18

# Reverse migration resource runs on SOURCE cluster nodes
crm configure primitive migration-reverse pgtwin-migrate \
  params source_cluster=postgres-clone-18 target_cluster=postgres-clone ...

crm configure colocation migration-reverse-with-target inf: \
  migration-reverse postgres-clone
```

**Why colocation matters:**
- Subscriptions are created on the **subscriber** (target for forward, source for reverse)
- pgtwin-migrate needs to run on nodes where subscription exists
- Ensures pgtwin-migrate can connect to local PostgreSQL for subscription management
- Pacemaker automatically moves resource if target cluster fails over

**Important**: Use **colocation** (not location) constraints:
- Colocation: "Run with this other resource" (dynamic)
- Location: "Run on this specific node" (static)
- Colocation follows cluster failover automatically

### 3.3 Migration Phases

pgtwin-migrate orchestrates migration in phases:

#### Phase 1: Setup (Automatic on Start)

```
1. Discover source cluster primary (via Pacemaker CIB)
2. Discover target cluster primary (via Pacemaker CIB)
3. Create publication on source:
   CREATE PUBLICATION pgtwin_migrate_forward_pub FOR ALL TABLES;
4. Create subscription on target:
   CREATE SUBSCRIPTION pgtwin_migrate_forward_sub
     CONNECTION 'host=source_repl_vip ...'
     PUBLICATION pgtwin_migrate_forward_pub;
5. Wait for initial sync to complete
6. Setup reverse replication (publication on target, subscription on source)
7. Setup DDL replication (event trigger + dblink)
8. Enter monitoring state
```

#### Phase 2: Monitoring (Continuous)

```
Every monitor cycle (default: 10 seconds):
1. Check subscription status:
   SELECT * FROM pg_stat_subscription;
2. Calculate replication lag:
   SELECT pg_wal_lsn_diff(received_lsn, latest_end_lsn);
3. Update resource attributes (visible in crm status)
4. Check for errors
5. Return OCF_SUCCESS if healthy
```

#### Phase 3: Manual Testing (Administrator)

```
Administrator validates target cluster before cutover:
1. Connect to target replication VIP
2. Run application tests
3. Verify data consistency (row counts, checksums, etc.)
4. Test read queries
5. Verify lag is acceptable
6. Approve cutover (or wait for more sync)
```

#### Phase 4: Cutover Execution (Administrator Triggered)

**Option A: Stop Forward Migration** (Manual approach used in current implementation)
```bash
# 1. Stop forward migration resource
crm resource stop migration-forward

# 2. Stop source cluster (prevents new writes)
crm resource stop postgres-clone

# 3. Wait for final sync (lag = 0)

# 4. Move application VIP to target cluster
crm configure edit postgres-vip-18
  # Change IP to production IP (192.168.60.100)

# 5. Verify applications connect successfully

# 6. Reverse replication continues (source receives changes from target)
```

**Option B: Coordinated Cutover** (Design specification approach)
```bash
# Single command triggers entire cutover sequence:
crm_attribute -n pgtwin_active_cluster -v "postgres-clone-18"

# pgtwin-migrate orchestrates:
1. Set source to read-only (quiesce)
2. Wait for lag = 0 (final sync)
3. Synchronize sequences (ensure no gaps)
4. Signal VIP ready to migrate
5. VIP moves to target
6. Resume write operations on target
7. Continue reverse replication
```

#### Phase 5: Post-Cutover (Continuous)

```
1. Application VIP now on target cluster
2. Clients connect to target (transparently via VIP)
3. Source cluster continues running (receives reverse replication)
4. Administrator monitors target stability
5. After confidence period (7-30 days):
   - Stop migration resources
   - Clean up subscriptions/publications
   - Optionally decommission source cluster
```

### 3.4 Safety Mechanisms

pgtwin-migrate includes multiple safety mechanisms:

#### 3.4.1 Replication Lag Monitoring

```
Every monitor cycle:
  lag_bytes = pg_wal_lsn_diff(received_lsn, latest_end_lsn)

  if lag_bytes > lag_threshold:
    ocf_log warn "Replication lag high: ${lag_bytes} bytes"
    # Continue monitoring

  if lag_bytes == 0:
    ocf_log info "Replication fully synchronized"
    # Ready for cutover (if administrator approves)
```

#### 3.4.2 Subscription Refresh (Auto-sync)

**Problem**: New tables created after subscription don't automatically replicate

```sql
-- After subscription created:
CREATE TABLE new_table (id serial, data text);
INSERT INTO new_table VALUES (1, 'test');

-- new_table exists on source, but NOT in subscription
-- Data not replicating!
```

**Solution**: Periodic subscription refresh
```
pgtwin-migrate monitor (every ~2 minutes):
  ALTER SUBSCRIPTION pgtwin_migrate_forward_sub
    REFRESH PUBLICATION WITH (copy_data = true);

-- Now new_table is included in subscription
-- Data replicates
```

**Auto-sync timing**: ~2 minutes (monitor interval × 12 cycles)

#### 3.4.3 Rollback Capability

Because reverse replication is established from the start:

```
1. Cutover to target
2. Discover issue (performance, application bug, etc.)
3. Rollback procedure:
   a. Stop writes to target (maintenance mode)
   b. Wait for reverse replication lag = 0
   c. Move application VIP back to source
   d. Resume writes on source
4. Source is current (received all changes from target)
5. No data loss
```

#### 3.4.4 State Tracking

pgtwin-migrate tracks state via resource attributes:

```bash
# Visible in crm status:
migration_state: monitoring | ready_for_cutover | cutover_in_progress | completed
replication_lag_bytes: 0
last_refresh: 2025-12-27 13:05:00
subscription_status: streaming
```

### 3.5 Key Features Summary

| Feature | Purpose | How it Works |
|---------|---------|-------------|
| **Logical replication** | Cross-version migration | Uses PostgreSQL publications/subscriptions |
| **Bidirectional replication** | Rollback safety | Forward and reverse replication simultaneously |
| **DDL replication** | Replicate schema changes | Event trigger + dblink (reverse direction only) |
| **Auto-sync** | Keep new tables in sync | Periodic subscription refresh (every ~2 min) |
| **VIP architecture** | Zero-downtime cutover | Application VIP moves from source to target |
| **Replication VIPs** | Traffic isolation | Dedicated VIPs on standbys for replication |
| **Colocation** | Correct node placement | Ensures resource runs on target cluster nodes |
| **Lag monitoring** | Cutover readiness | Continuous monitoring of replication lag |

---

## 4. How They Work Together

### 4.1 Complementary Responsibilities

```
┌──────────────────────────────────────────────────────────────┐
│                         pgtwin                               │
│  Manages individual PostgreSQL instances                     │
├──────────────────────────────────────────────────────────────┤
│  • Start/stop PostgreSQL                                     │
│  • Promote/demote                                            │
│  • Physical replication (primary ↔ standby)                  │
│  • Replication slot management                               │
│  • Auto-initialization                                       │
│  • Timeline divergence recovery (pg_rewind)                  │
│  • Configuration validation                                  │
│  • VIP coordination (within cluster)                         │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                    pgtwin-migrate                            │
│  Orchestrates migration between clusters                     │
├──────────────────────────────────────────────────────────────┤
│  • Logical replication setup                                 │
│  • Lag monitoring (cross-cluster)                            │
│  • DDL replication                                           │
│  • Subscription refresh                                      │
│  • Cutover coordination                                      │
│  • VIP migration (between clusters)                          │
│  • Post-cutover monitoring                                   │
└──────────────────────────────────────────────────────────────┘
```

**Clear Separation**:
- pgtwin: **Intra-cluster** operations (within one cluster)
- pgtwin-migrate: **Inter-cluster** operations (between clusters)

### 4.2 Migration Scenario Example

**Scenario**: Upgrade from PostgreSQL 17 to PostgreSQL 18

**Step 1: Deploy PG17 Cluster** (using pgtwin)
```bash
# Configure PG17 cluster
crm configure primitive postgres-db ocf:heartbeat:pgtwin \
  params pgdata=/var/lib/pgsql/data ...

crm configure clone postgres-clone postgres-db \
  meta promotable=true

# pgtwin manages:
- Auto-initialization of standby
- Physical replication (PG17 primary → PG17 standby)
- Failover within PG17 cluster
- VIP following PG17 primary
```

**Step 2: Deploy PG18 Cluster** (using pgtwin)
```bash
# Configure PG18 cluster (parallel to PG17)
crm configure primitive postgres-db-18 ocf:heartbeat:pgtwin \
  params pgdata=/var/lib/pgsql/data container_mode=true ...

crm configure clone postgres-clone-18 postgres-db-18 \
  meta promotable=true

# pgtwin manages:
- Auto-initialization of PG18 standby
- Physical replication (PG18 primary → PG18 standby)
- Failover within PG18 cluster
- VIP following PG18 primary
```

**Step 3: Setup Migration** (using pgtwin-migrate)
```bash
# Create migration resources
crm configure primitive migration-forward pgtwin-migrate \
  params source_cluster=postgres-clone target_cluster=postgres-clone-18 \
         source_replication_vip=192.168.60.104 \
         target_replication_vip=192.168.60.105 ...

crm configure primitive migration-reverse pgtwin-migrate \
  params source_cluster=postgres-clone-18 target_cluster=postgres-clone \
         source_replication_vip=192.168.60.105 \
         target_replication_vip=192.168.60.104 ...

# pgtwin-migrate manages:
- Logical replication (PG17 → PG18)
- Reverse replication (PG18 → PG17)
- DDL replication (PG18 → PG17)
- Lag monitoring
```

**Step 4: Monitor Replication** (pgtwin-migrate)
```bash
# pgtwin-migrate continuously monitors:
crm status
  # Shows: replication_lag_bytes: 0

# Administrator validates:
psql -h 192.168.60.105 -U postgres  # Connect to PG18 via target repl VIP
SELECT count(*) FROM important_table;  # Verify data
```

**Step 5: Execute Cutover** (pgtwin-migrate + manual)
```bash
# Stop forward migration
crm resource stop migration-forward

# Stop PG17 cluster (pgtwin stops PostgreSQL gracefully)
crm resource stop postgres-clone

# Move application VIP to PG18
crm configure edit postgres-vip-18
  # Change IP to production IP

# pgtwin ensures:
- PG18 is promoted and healthy
- VIP attaches to PG18 primary
- Clients can connect
```

**Step 6: Post-Cutover** (both agents)
```bash
# pgtwin manages PG18 cluster:
- Failover within PG18 if needed
- Physical replication health
- VIP following PG18 primary

# pgtwin-migrate manages reverse replication:
- PG18 → PG17 replication
- Allows rollback if issues detected

# After stability period (30 days):
crm resource stop migration-reverse
crm configure delete migration-forward
crm configure delete migration-reverse
crm resource stop postgres-clone  # Decommission PG17
```

### 4.3 Interaction Points

**Discovery**:
- pgtwin-migrate queries Pacemaker CIB to discover pgtwin cluster state
- Finds promoted node (primary) for each cluster
- Connects to PostgreSQL via pgtwin-managed VIPs

**Configuration**:
- pgtwin sets `wal_level = logical` (required for pgtwin-migrate)
- pgtwin creates replication users (used by pgtwin-migrate subscriptions)
- pgtwin manages `.pgpass` (credentials used by pgtwin-migrate)

**Monitoring**:
- pgtwin monitors physical replication health
- pgtwin-migrate monitors logical replication health
- Both update Pacemaker resource attributes (visible in `crm status`)

**Failover Coordination**:
```
PG17 cluster failover (pgtwin handles):
  1. Primary fails
  2. pgtwin promotes standby
  3. Source Replication VIP moves to new standby
  4. pgtwin-migrate subscription reconnects to new VIP
  5. Logical replication resumes

PG18 cluster failover (pgtwin handles):
  1. Primary fails
  2. pgtwin promotes standby
  3. Target Replication VIP moves to new standby
  4. pgtwin-migrate subscription reconnects to new VIP
  5. Reverse replication resumes
```

---

## 5. Core Design Principles

### 5.1 Intelligent Automation

**Philosophy**: Automate complex operations while maintaining safety and visibility

**Examples**:
- Auto-initialization: Detects empty PGDATA, runs pg_basebackup automatically
- pg_rewind: Detects timeline divergence, runs reconciliation automatically
- Subscription refresh: Periodically refreshes to include new tables
- Sync mode switching: Automatically adjusts based on cluster state

**Not "Magic"**: All operations are logged, state is visible, administrators can intervene

### 5.2 Separation of Concerns

**Philosophy**: Each agent has a clear, focused responsibility

**pgtwin**: Manages PostgreSQL instances (start, stop, promote, demote, replicate)
**pgtwin-migrate**: Orchestrates migration (logical replication, cutover, monitoring)

**Benefits**:
- Easier to understand (each agent does one thing well)
- Easier to test (isolated responsibilities)
- Easier to maintain (changes to migration don't affect HA)
- Easier to deploy (can use pgtwin without pgtwin-migrate)

### 5.3 Pacemaker-Native

**Philosophy**: Leverage Pacemaker's cluster management capabilities

**Integration points**:
- OCF resource agent standard (start, stop, monitor, promote, demote)
- Cluster Information Base (CIB) for discovery
- Notify support for dynamic configuration
- Colocation/ordering constraints for resource placement
- Quorum and STONITH for split-brain prevention

**Benefits**:
- Well-understood operational model
- Standard tools (`crm status`, `crm configure`, etc.)
- Proven split-brain prevention
- Multi-node scalability (3+ node clusters possible)

### 5.4 Safety First

**Philosophy**: Prevent data loss and provide rollback capability

**Safety mechanisms**:
- Replication slots prevent WAL loss
- pg_rewind requires wal_log_hints (prevents corruption)
- Configuration validation blocks dangerous settings
- Bidirectional replication enables rollback
- Timeline divergence checks prevent split-brain
- Synchronous replication option (zero data loss)

**Conservative defaults**:
- `backup_before_basebackup = true` (keeps old data)
- `rep_mode = async` (availability over consistency)
- `replication_failure_threshold = 5` (avoids false positives)

### 5.5 Observability

**Philosophy**: Make cluster state visible and understandable

**Visibility mechanisms**:
- Resource attributes updated every monitor cycle
- Detailed logging (ocf_log info/warn/err)
- State files track long-running operations (.basebackup_in_progress)
- `crm status` shows health at a glance
- PostgreSQL system catalogs expose replication state

**Example observability**:
```bash
crm status
  # Shows:
  - Which node is promoted (primary)
  - Which node is unpromoted (standby)
  - VIP locations
  - Migration resource state
  - Replication lag
  - Failed operations

# Deep dive:
psql -c "SELECT * FROM pg_stat_replication;"  # Physical replication
psql -c "SELECT * FROM pg_stat_subscription;"  # Logical replication
cat /var/lib/pgsql/data/.basebackup.log  # Basebackup progress
```

### 5.6 Container-Friendly

**Philosophy**: Support modern deployment patterns without code duplication

**Design approach**:
- **Abstraction layer**: pgtwin-container-lib.sh provides transparent wrappers
- **Same code**: pgtwin core logic unchanged for bare-metal vs. container
- **Runtime detection**: `container_mode` parameter enables container support
- **Security**: Container runs as host's postgres UID (same security model)

**Benefits**:
- Deploy multiple PostgreSQL versions on same host (useful for migrations)
- Simplified testing (no package installation)
- Consistent environment across nodes
- Future-proof (cloud-native deployments)

### 5.7 Graceful Degradation

**Philosophy**: Maintain availability when components fail

**Examples**:
- Synchronous replication falls back to async when standby fails (with notify support)
- pg_rewind falls back to pg_basebackup if rewind fails
- Timeline warning is non-blocking (warns but allows startup)
- Auto-cleanup is best-effort (falls back to timeout if fails)

**Principle**: Availability over perfect consistency (configurable via `rep_mode`)

### 5.8 Zero-Touch Operations

**Philosophy**: Minimize administrator toil for routine operations

**Examples**:
- Standby initialization: Just bring node online (auto pg_basebackup)
- Failover recovery: Automatic pg_rewind after primary returns
- Replication recovery: Automatic rebuild after threshold reached
- Configuration updates: Automatic application_name management
- Slot management: Automatic creation, cleanup when excessive

**Not Zero-Touch**:
- Major upgrades: Requires pgtwin-migrate deployment and monitoring
- Cutover execution: Requires administrator approval
- Decommissioning: Requires administrator decision

---

## 6. Summary

### pgtwin: Core HA Agent

**What it does**: Manages PostgreSQL instances for high availability
**Key innovation**: Zero-touch operations (auto-init, auto-recovery, auto-failover)
**Best for**: Production PostgreSQL clusters requiring 99.9%+ uptime

**Mental model**:
```
pgtwin = PostgreSQL + Pacemaker integration + Intelligent automation
```

### pgtwin-migrate: Migration Orchestrator

**What it does**: Orchestrates zero-downtime migrations between clusters
**Key innovation**: Bidirectional logical replication with coordinated cutover
**Best for**: Major version upgrades, vendor migrations, infrastructure changes

**Mental model**:
```
pgtwin-migrate = Logical replication + DDL sync + VIP migration + Safety net
```

### Together

**pgtwin** manages the **trees** (individual PostgreSQL instances)
**pgtwin-migrate** manages the **forest** (migration between clusters)

Both share core principles:
- Intelligent automation
- Safety first
- Pacemaker-native
- Observability
- Graceful degradation

---

## Appendix: Quick Reference

### pgtwin Key Operations

| Operation | Command | What Happens |
|-----------|---------|-------------|
| **Deploy cluster** | `crm configure clone postgres-clone postgres-db promotable=true` | Pacemaker creates promotable clone |
| **Start node** | `crm node online node1` | pgtwin auto-initializes if empty, starts PostgreSQL |
| **Failover** | (automatic) | pgtwin promotes standby, runs pg_rewind on old primary |
| **Manual failover** | `crm resource move postgres-clone node2` | Forces promotion to node2 |
| **Recover node** | `crm node online node1` | pgtwin runs pg_rewind or pg_basebackup, rejoins |

### pgtwin-migrate Key Operations

| Operation | Command | What Happens |
|-----------|---------|-------------|
| **Setup migration** | `crm configure primitive migration-forward pgtwin-migrate ...` | Creates logical replication |
| **Monitor lag** | `crm status` | Shows replication lag in resource attributes |
| **Test target** | `psql -h target_repl_vip` | Connect to target for validation |
| **Execute cutover** | Stop forward, stop source, move VIP | Switches production to target |
| **Rollback** | Move VIP back to source | Reverse replication enables rollback |
| **Cleanup** | `crm configure delete migration-forward` | Removes migration resources |

### Configuration Quick Reference

**pgtwin minimal configuration**:
```bash
primitive postgres-db ocf:heartbeat:pgtwin \
  params pgdata=/var/lib/pgsql/data \
  op monitor interval=10s role=Promoted \
  op monitor interval=15s role=Unpromoted

clone postgres-clone postgres-db \
  meta promotable=true
```

**pgtwin-migrate minimal configuration**:
```bash
primitive migration-forward pgtwin-migrate \
  params source_cluster=postgres-clone \
         target_cluster=postgres-clone-18 \
         source_replication_vip=192.168.60.104 \
         target_replication_vip=192.168.60.105

colocation migration-forward-with-target inf: \
  migration-forward postgres-clone-18
```

---

**Document Version**: 1.0
**Last Updated**: 2025-12-27
**Status**: Complete

For implementation details, see:
- README-resource-agent.md (pgtwin usage guide)
- ADMIN_PREPARATION_PGTWIN_MIGRATE.md (migration setup guide)
- DESIGN_DECISIONS_CONSOLIDATED.md (architectural decisions)
