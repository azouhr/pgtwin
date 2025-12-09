# pgtwin - PostgreSQL Twin: Simple 2-Node HA

**pgtwin** is a production-ready PostgreSQL High Availability OCF resource agent designed specifically for **2-node clusters** using Pacemaker and Corosync.

[![License: GPL v2+](https://img.shields.io/badge/License-GPL%20v2+-blue.svg)](https://www.gnu.org/licenses/gpl-2.0)
[![PostgreSQL: 17+](https://img.shields.io/badge/PostgreSQL-17+-blue.svg)](https://www.postgresql.org/)
[![Pacemaker: 3.0+](https://img.shields.io/badge/Pacemaker-3.0+-green.svg)](https://clusterlabs.org/)

---

## Why pgtwin?

**Problem**: You need PostgreSQL high availability and recovery from cluster failures but don't want the complexity and cost of 3+ node clusters.

**Solution**: pgtwin provides enterprise-grade PostgreSQL HA with just 2 nodes, using battle-tested Pacemaker/Corosync for cluster management.

### Key Benefits

- ✅ **Cost-Effective**: Only 2 VMs required (vs 3+ for Patroni + etcd/Consul)
- ✅ **Simple**: Pacemaker manages failover - no external DCS needed
- ✅ **Production-Ready**: Automatic configuration validation prevents dangerous misconfigurations
- ✅ **Zero Data Loss**: Synchronous replication with automatic failover in 30-60 seconds
- ✅ **Battle-Tested**: Based on proven Pacemaker/Corosync HA stack

---

## Quick Start

```bash
# 1. Install pgtwin OCF agent
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/
sudo chmod +x /usr/lib/ocf/resource.d/heartbeat/pgtwin

# 2. Configure PostgreSQL for replication (see QUICKSTART.md)
# 3. Setup Pacemaker cluster (see QUICKSTART.md)

# 4. Create PostgreSQL resource
sudo crm configure primitive postgres-db pgtwin \
  params pgdata="/var/lib/pgsql/data" rep_mode="sync" node_list="psql1 psql2"

# 5. Create promotable clone
sudo crm configure clone postgres-clone postgres-db \
  meta promotable=true notify=true

# 6. Create location constraints
sudo crm configure location prefer-psql1 postgres-clone role=Promoted 100: psql1
sudo crm configure location prefer-psql2 postgres-clone role=Promoted 50: psql2

# 7. Done! Check status
sudo crm status
```

For complete setup instructions, see [QUICKSTART.md](QUICKSTART.md).

---

## Features

### Core HA Features

| Feature | Description |
|---------|-------------|
| **Physical Replication** | WAL-based streaming replication for zero data loss |
| **Automatic Failover** | Primary failure detected and standby promoted automatically |
| **VIP Management** | Virtual IP follows primary for transparent client reconnection |
| **pg_rewind Support** | Fast timeline synchronization after failover (seconds vs hours) |
| **Replication Slots** | Prevents WAL deletion before standby consumption |
| **Async pg_basebackup** | Full resync runs in background without blocking cluster |

### Configuration Validation (v1.5)

pgtwin automatically validates your PostgreSQL configuration on startup to prevent dangerous settings:

| Validation | Severity | Purpose |
|------------|----------|---------|
| `restart_after_crash` = off | **CRITICAL** | Prevents split-brain scenarios (PostgreSQL auto-restart conflicts with Pacemaker) |
| `wal_level` = replica | **ERROR** | Required for physical replication |
| `max_wal_senders` >= 2 | **ERROR** | Required for replication connections |
| `wal_sender_timeout` >= 10s | **WARNING** | Prevents false disconnections on network hiccups |
| `max_standby_streaming_delay` != -1 | **WARNING** | Prevents unbounded replication lag |
| `archive_command` error handling | **WARNING** | Prevents cluster-wide write blocking on archive failures |

**CRITICAL** errors block PostgreSQL startup - you must fix them before the cluster will start.

### Automatic Replication Recovery (v1.6)

pgtwin v1.6 introduces intelligent replication failure detection and automatic recovery:

| Feature | Description |
|---------|-------------|
| **Replication Health Monitoring** | Monitor function actively tracks WAL receiver status on standby nodes |
| **Failure Counter** | Incremental counter tracks consecutive replication failures (configurable threshold) |
| **Automatic Recovery** | When threshold exceeded, automatically triggers `pg_rewind` or `pg_basebackup` |
| **Dynamic Node Discovery** | Discovers current primary via VIP query, node scanning, or CIB parsing |
| **Zero-Touch Recovery** | Timeline divergence and replication breaks resolve automatically without manual intervention |

**New Parameters**:
- `vip`: Virtual IP address for fast promoted node discovery (optional but recommended)
- `replication_failure_threshold`: Number of monitor cycles before recovery (default: 5, ~40 seconds with 8s intervals)

**Status**: Production Ready - v1.6.6 fixes all critical bugs from v1.6.0-v1.6.5.

### Automatic Standby Initialization (v1.6.6)

pgtwin v1.6.6 introduces **zero-touch standby deployment** - just provide an empty PGDATA and pgtwin automatically initializes it:

| Feature | Description |
|---------|-------------|
| **Empty PGDATA Detection** | Automatically detects empty/missing/invalid PGDATA on startup |
| **Automatic pg_basebackup** | Discovers primary, runs pg_basebackup in background, finalizes configuration |
| **Zero Manual Steps** | Only `.pgpass` file required - everything else is automatic |
| **Simplified Disk Replacement** | Disk replacement reduced from 10+ steps to just 3 commands |
| **Fresh Node Deployment** | New nodes self-initialize when joining cluster |
| **Corrupted Data Recovery** | Delete corrupted data, bring node online - automatic recovery |

**Prerequisites**: Only requires `.pgpass` file with replication credentials

**Use Case**: Disk replacement now takes 3 commands:
```bash
crm node standby psql2
# Mount new disk at /var/lib/pgsql/data
crm node online psql2  # Auto-initializes!
```

See [doc/FEATURE_AUTO_INITIALIZATION.md](doc/FEATURE_AUTO_INITIALIZATION.md) for complete details.

### Pacemaker Notify Support (v1.6.6)

pgtwin v1.6.6 adds **dynamic synchronous replication management** to prevent write blocking when standby fails:

| Feature | Description |
|---------|-------------|
| **post-start Handler** | Automatically enables sync replication when standby connects |
| **post-stop Handler** | Automatically disables sync replication when standby disconnects |
| **Zero-Touch Operations** | No manual synchronous_standby_names changes needed |
| **High Availability** | Prevents write outages during standby failures |
| **Optimal Consistency** | Automatically uses strongest mode available (sync when possible, async when needed) |

**Configuration**: Just add `notify="true"` to your clone meta:
```bash
clone postgres-clone postgres-db \
  meta notify="true" promotable=true
```

**Benefit**: Standby maintenance no longer blocks writes on primary

See [doc/FEATURE_NOTIFY_SUPPORT.md](doc/FEATURE_NOTIFY_SUPPORT.md) for complete details.

### Critical Bug Fix (v1.6.6)

pgtwin v1.6.6 fixes a **critical bug** that caused replication to fail after pg_basebackup recovery:

| Issue | Impact | Fix |
|-------|--------|-----|
| Empty `primary_conninfo` | 100% replication failure after pg_basebackup | New `finalize_standby_config()` function |
| Read-after-delete | Bug attempted to read file after deleting it | Read values before file deletion |
| Broken recovery paths | Affected automatic recovery, manual failover, disk replacement | Unified config finalization across all paths |

**Impact**: Affects v1.6.0 - v1.6.5. **Immediate upgrade recommended** if using automatic recovery or disk replacement procedures.

See [doc/BUGFIX_PG_BASEBACKUP_FINALIZATION.md](doc/BUGFIX_PG_BASEBACKUP_FINALIZATION.md) for technical details.

### Advanced Features

- **Disk Space Pre-Check**: Validates sufficient space before `pg_basebackup`
- **Backup Mode**: Optional backup of old data before full resync (safer but uses 2× space)
- **Application Name Sanitization**: Automatically converts invalid characters (hyphens → underscores)
- **Credential Management**: Reads replication credentials from `.pgpass` file
- **Runtime Monitoring**: Continuous archive failure detection on primary
- **Smart Recovery**: Tries `pg_rewind` first, falls back to `pg_basebackup` if needed

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    Application Layer                       │
│               (Connects to VIP: 192.168.122.20)            │
└────────────────────┬───────────────────────────────────────┘
                     │
            PostgreSQL Protocol (TCP 5432)
                     │
┌────────────────────┴───────────────────────────────────────┐
│            PostgreSQL HA Cluster (pgtwin)                  │
│                                                            │
│  ┌──────────────────┐              ┌──────────────────┐    │
│  │  Node 1 (psql1)  │◄────────────►│  Node 2 (psql2)  │    │
│  │  192.168.122.60  │ Replication  │  192.168.122.120 │    │
│  │                  │              │                  │    │
│  │  PostgreSQL 17   │              │  PostgreSQL 17   │    │
│  │  ┌────────────┐  │              │  ┌────────────┐  │    │
│  │  │  Primary   │  │─────────────>│  │  Standby   │  │    │
│  │  │  (Active)  │  │ WAL Stream   │  │ (Passive)  │  │    │
│  │  └────────────┘  │              │  └────────────┘  │    │
│  │                  │              │                  │    │
│  │  Pacemaker       │◄────────────►│  Pacemaker       │    │
│  │  Corosync        │ Heartbeat    │  Corosync        │    │
│  │  pgtwin OCF      │ (UDP 5405)   │  pgtwin OCF      │    │
│  └──────────────────┘              └──────────────────┘    │
│           │                                   │            │
│           │         SBD STONITH Fencing       │            │
│           └───────────────┬───────────────────┘            │
│                           │                                │
│                  ┌────────┴────────┐                       │
│                  │  Shared Storage  │                      │
│                  │   /dev/vdb       │                      │
│                  └──────────────────┘                      │
└────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Normal Operation**:
   - Primary accepts writes, standby replays WAL
   - VIP points to primary
   - Pacemaker monitors both nodes (3s intervals on primary, 10s on standby)

2. **Primary Failure**:
   - Pacemaker detects primary failure (missed heartbeats)
   - STONITH fence the failed node (SBD)
   - Standby promoted to primary (pg_ctl promote)
   - VIP moved to new primary
   - Applications reconnect automatically

3. **Old Primary Recovery**:
   - Node restarts and joins cluster
   - pgtwin tries `pg_rewind` (fast, seconds)
   - If timelines diverged too much, falls back to `pg_basebackup` (full copy)
   - Node becomes new standby, replication resumes

### Expected Timing

**Automatic Failover** (Primary → Standby):
- **Detection**: 10-15 seconds (monitor intervals + timeout)
- **Fencing**: 5-10 seconds (STONITH via SBD)
- **Promotion**: 5-10 seconds (pg_ctl promote)
- **VIP Migration**: 2-5 seconds (Pacemaker IPaddr2)
- **Total Downtime**: **30-60 seconds** (typical)

**Manual Failover**:
- **Total Time**: 15-30 seconds (no detection delay)
- Triggered via: `crm resource move postgres-clone <target-node>`

**Node Recovery After Failover**:
- **pg_rewind**: 5-30 seconds (fast, depends on divergence)
- **pg_basebackup**: Minutes to hours (depends on database size)
  - Small databases (<10 GB): 2-5 minutes
  - Medium databases (10-100 GB): 5-30 minutes
  - Large databases (>100 GB): 30+ minutes
- **Replication Resume**: <5 seconds after recovery

**Replication Lag** (Normal Operation):
- **Synchronous Mode**: <1 second (typically <100ms)
- **Asynchronous Mode**: <5 seconds (network dependent)

**Notes**:
- Failover times assume healthy network and properly configured STONITH
- pg_basebackup runs asynchronously to avoid blocking cluster operations
- VIP ensures applications reconnect automatically after failover

---

## Design Decisions

### 1. Two-Node Focus

**Decision**: pgtwin is explicitly designed for 2-node clusters, not 3+.

**Rationale**:
- Many organizations need basic HA but can't afford 3+ Datacenters
- Patroni requires 3+ nodes (1 DCS cluster + N PostgreSQL nodes minimum)
- Pacemaker's 2-node quorum is well-established and reliable
- Simpler architecture = easier to understand and operate

**Trade-off**: Cannot survive simultaneous failure of both nodes. For geographic distribution or multi-site HA, use Patroni instead.

### 2. Physical Replication Only

**Decision**: Only physical (WAL-based) replication is supported, not logical replication.

**Rationale**:
- Physical replication is simpler and more reliable for HA
- Byte-level copy ensures exact replicas (no schema/version mismatches)
- Faster failover (no need to replay transactions)
- Better for disaster recovery (complete cluster state preserved)

**Trade-off**: Cannot replicate between different PostgreSQL major versions or do selective table replication. For those use cases, use PostgreSQL's built-in logical replication.

### 3. Pacemaker Instead of Patroni

**Decision**: Use Pacemaker/Corosync for cluster management instead of Patroni + DCS.

**Rationale**:
- Pacemaker is mature (20+ years), proven in production
- No external dependencies (etcd/Consul/ZooKeeper) needed
- Better resource management (can manage VIP, storage, etc.)
- Industry standard for on-premise HA clusters

**Trade-off**: Less cloud-native than Patroni. Patroni is better for cloud deployments and 3+ nodes.

### 4. Configuration Validation Framework

**Decision**: Automatically validate PostgreSQL configuration on every start.

**Rationale**:
- Dangerous settings like `restart_after_crash=on` cause catastrophic split-brain
- Many PostgreSQL configurations can destabilize HA clusters
- Proactive validation prevents 99% of misconfigurations
- Hard errors (CRITICAL) block startup for safety-critical settings

**Implementation**: 12 configuration checks run during `pgsql_start()`, including:
- Critical: `restart_after_crash`, `wal_level`, `max_wal_senders`
- Warnings: timeout values, replication lag controls, archive error handling

### 5. Asynchronous pg_basebackup

**Decision**: Run `pg_basebackup` in background, return control to Pacemaker immediately.

**Rationale**:
- Large databases take hours to copy
- Pacemaker operations have 2-minute default timeouts
- Synchronous basebackup would timeout and fail repeatedly
- Async allows cluster to stabilize while resync happens

**Implementation**: Background process with progress tracking, timeout handling, and automatic rollback on failure.

### 6. Backup Before Basebackup

**Decision**: Provide optional backup mode (default: enabled) that saves old data before `pg_basebackup`.

**Rationale**:
- `pg_basebackup` failures can leave standby unrecoverable
- Production environments prioritize safety over disk space
- Timestamped backups allow recovery from failed basebackup

**Trade-off**: Uses 2× disk space temporarily. Can be disabled for space-constrained environments.

### 7. Application Name Restrictions

**Decision**: Only allow alphanumeric + underscore in `application_name`, no hyphens.

**Rationale**:
- PostgreSQL's `synchronous_standby_names` uses comma-separated list syntax
- Hyphens can be misinterpreted as minus signs in some contexts
- Explicit validation prevents subtle replication failures

**Implementation**: Automatic sanitization (hostname hyphens → underscores) with validation errors for user-provided names.

### 8. No Archive Command Defaults

**Decision**: WAL archiving is optional and disabled by default.

**Rationale**:
- Many HA deployments don't need Point-in-Time Recovery (PITR)
- Archiving adds complexity (destination setup, monitoring, space management)
- Synchronous replication already provides zero data loss for failover
- Users who need PITR should explicitly configure it

**Implementation**: If enabled, pgtwin validates that `archive_command` has error handling (`|| /bin/true`) to prevent cluster-wide write blocking.

---

## vs. Patroni

| Feature | pgtwin (2-node) | Patroni (3+ nodes) |
|---------|-----------------|-------------------|
| **Minimum Nodes** | 2 | 3+ (PostgreSQL + DCS) |
| **Infrastructure Cost** | Lower (2 VMs) | Higher (3+ VMs + DCS) |
| **Setup Complexity** | Lower | Higher |
| **External Dependencies** | None (Pacemaker built-in) | Requires etcd/Consul/ZooKeeper |
| **Maturity** | Mature (Pacemaker 20+ years) | Mature (Patroni 8+ years) |
| **Cloud-Native** | On-premise focused | Cloud-optimized |
| **Geographic Distribution** | Limited (2 nodes, low latency) | Excellent (multi-site support) |
| **Use Case** | Budget-constrained, simple HA | Multi-node, cloud, complex topologies |

**Choose pgtwin when**: You need simple 2-node HA, have budget constraints, or prefer Pacemaker's resource management.

**Choose Patroni when**: You need 3+ nodes, cloud-native deployment, or geographic distribution.

---

## Requirements

- **PostgreSQL**: 17.x (earlier versions may work but untested)
- **OS**: Linux (openSUSE Tumbleweed tested)
- **Pacemaker**: 3.0.1 or higher
- **Corosync**: 3.x
- **Python**: Not required (pure bash OCF agent)
- **Shared Storage**: Optional (for SBD STONITH)

---

## Installation

```bash
# Clone repository
git clone https://github.com/azouhr/pgtwin.git
cd pgtwin

# Install OCF agent
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/
sudo chmod +x /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify installation
sudo bash -n /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data
```

See [QUICKSTART.md](QUICKSTART.md) for complete setup guide.

---

## Documentation

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | Complete setup guide (PostgreSQL + Pacemaker) |
| [CHEATSHEET.md](CHEATSHEET.md) | Administration command reference |
| README.md | This file - overview and design decisions |

---

## Configuration Example

```bash
# Minimal configuration
sudo crm configure primitive postgres-db pgtwin \
  params \
    pgdata="/var/lib/pgsql/data" \
    rep_mode="sync" \
    node_list="psql1 psql2"

# Production configuration with all options
sudo crm configure primitive postgres-db pgtwin \
  params \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    pguser="postgres" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    slot_name="ha_slot" \
    backup_before_basebackup="true" \
    basebackup_timeout="3600" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    max_slot_wal_keep_size="1024" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0" \
  op demote timeout="120s" interval="0" \
  op notify timeout="90s" interval="0"
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| **1.5.0** | 2025-01-02 | Configuration validation framework, production-safe timeouts |
| **1.4.0** | 2025-12 | Async pg_basebackup, backup mode |
| **1.3.0** | 2025-11 | Enhanced configuration checks |
| **1.2.0** | 2025-10 | Disk space validation |
| **1.1.0** | 2025-10 | Application name validation, .pgpass support |
| **1.0.0** | 2025-10 | Initial release |

---

## Common Operations

```bash
# Check cluster status
sudo crm status

# Manual failover to node 2
sudo crm resource move postgres-clone psql2
sudo crm resource clear postgres-clone  # Always clear after move!

# Check replication status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# Check replication lag
sudo -u postgres psql -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb FROM pg_stat_replication;"

# Check logs
sudo journalctl -u pacemaker -f
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log
```

See [CHEATSHEET.md](CHEATSHEET.md) for complete command reference.

---

## Troubleshooting

### Resource Won't Start

Check validation errors in Pacemaker logs:

```bash
sudo journalctl -u pacemaker | grep -E "CRITICAL ERROR|CONFIGURATION ERROR"
```

Most common issue: `restart_after_crash='on'` (MUST be 'off' for Pacemaker).

### Replication Not Working

```bash
# On primary - check standby connection
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# On standby - check recovery status
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # Should be 't'

# Check .pgpass permissions
ls -l /var/lib/pgsql/.pgpass  # Must be 600, owner postgres
```

### Split-Brain Scenarios

**Prevention**: Ensure `restart_after_crash = off` in `postgresql.conf`!

**Recovery**: See CHEATSHEET.md section "Recovery from Split-Brain"

---

## Testing

pgtwin includes testing capabilities:

```bash
# Test syntax
sudo bash -n /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify OCF metadata
sudo OCF_ROOT=/usr/lib/ocf \
  OCF_RESKEY_pgdata=/var/lib/pgsql/data \
  /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data

# Test OCF agent manually
sudo OCF_ROOT=/usr/lib/ocf \
  OCF_RESKEY_pgdata=/var/lib/pgsql/data \
  /usr/lib/ocf/resource.d/heartbeat/pgtwin monitor
```

---

## Contributing

Contributions welcome! Please:

1. Test changes in staging environment
2. Run test suite before submitting PR
3. Update documentation for new features
4. Follow bash best practices (shellcheck clean)

---

## License

GNU General Public License v2.0 or later (GPL-2.0-or-later)

This project is licensed under the GPL-2.0-or-later license to facilitate integration with the ClusterLabs resource-agents project. See LICENSE file for details.

SPDX-License-Identifier: GPL-2.0-or-later

---

## Credits

- **Author**: Original development team
- **Inspiration**: Based on OCF PostgreSQL resource agents and PostgreSQL HA best practices
- **Technology**: Built on Pacemaker/Corosync HA stack

---

## Support

- **Issues**: https://github.com/azouhr/pgtwin/issues
- **Documentation**: See QUICKSTART.md and CHEATSHEET.md
- **Pacemaker**: https://clusterlabs.org/
- **PostgreSQL**: https://www.postgresql.org/docs/17/

---

**pgtwin** - PostgreSQL Twin: Two-Node HA Made Simple

*When you need PostgreSQL high availability but not the complexity of multi-node clusters.*
