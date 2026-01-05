# pgtwin v1.7.1 Release Notes

**Release Date:** 2026-01-05
**Type:** Feature + Bugfix Release
**Status:** Production Ready (pgtwin) / Experimental (pgtwin-migrate)

---

## Overview

This release focuses on **pgtwin-migrate** enhancements:
- **pgtwin v1.6.18**: No changes (stable, production ready)
- **pgtwin-migrate v1.0.8** ⚠️ **EXPERIMENTAL**: Multi-database migration support
- **pgtwin-migrate v1.0.7**: Auto-stop timing fix

---

## What's New in v1.7.1

### pgtwin-migrate v1.0.8 - Multi-Database Migration Support 🆕

**Major Feature:** Migrate multiple PostgreSQL databases in a single atomic operation

#### New `databases` Parameter

```bash
primitive migration-forward pgtwin-migrate \
    params \
        databases="postgres,myapp_prod,analytics,reporting" \
        source_cluster=postgres-clone \
        target_cluster=postgres-clone-18 \
        ...
```

#### Key Features

- ✅ **Comma-separated database list** - Migrate N databases with one resource
- ✅ **Per-database infrastructure** - Isolated publications, subscriptions, slots, triggers
- ✅ **Per-database monitoring** - Independent lag tracking and state files
- ✅ **Atomic cutover** - All databases switch together with single VIP swap
- ✅ **Backward compatible** - Legacy `pgdatabase` parameter still works
- ✅ **Scales linearly** - Tested with 1-10 databases

#### Use Cases

1. **Microservices Architecture**
   - Migrate all service databases atomically
   - Example: `databases="auth,users,payments,notifications"`

2. **Multi-Tenant SaaS**
   - Migrate all tenant databases together
   - Example: `databases="tenant_1001,tenant_1002,tenant_1003"`

3. **Analytics + OLTP**
   - Keep OLTP and OLAP synchronized
   - Example: `databases="production,analytics,reporting"`

4. **Schema Separation**
   - Maintain logical separation across migration
   - Example: `databases="application,audit_log,metrics,sessions"`

#### Performance Characteristics

**Cutover Window:**
- Single database: 2-3 minutes
- Five databases: 3-5 minutes (adds ~30-60s per database)

**Resource Usage:**
- Per database: 1 publication + 1 subscription + 1 slot + 1 trigger
- Five databases: 20 logical replication resources (forward + reverse)

**Recommendations:**
- `max_replication_slots ≥ (DB_COUNT × 4)`
- `max_wal_senders ≥ (DB_COUNT × 2)`
- `max_worker_processes ≥ (DB_COUNT × 2)`

#### Documentation

- **FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md** (500+ lines)
  - Complete technical specification
  - Configuration examples
  - Use cases and requirements
  - Monitoring guide
  - Troubleshooting

### pgtwin-migrate v1.0.7 - Auto-Stop Timing Fix

**Bug Fix:** Resource auto-stop now happens immediately after cutover completion

#### Problem Fixed

- Resource set `target-role=Stopped` in monitor function
- If `migration-state` attribute deleted before monitor ran, auto-stop never triggered
- Resource stuck in restart loop

#### Solution

- Auto-stop now executes **immediately** in `check_cutover_progress()`
- Runs **before** cluster attribute can be deleted
- Eliminates race condition window
- Monitor function kept as safety net for edge cases

#### Impact

- ✅ No more restart loops after migration completes
- ✅ Resource stops automatically without manual intervention
- ✅ Works even if cluster attributes cleaned up early

#### Documentation

- **BUGFIX_AUTO_STOP_TIMING_v1.0.7.md**

---

## ⚠️ EXPERIMENTAL: pgtwin-migrate

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

### Status: EXPERIMENTAL

pgtwin-migrate is included in this release as an **experimental feature**. While it has been tested and validated in development environments, it should be:
- ✅ Tested thoroughly in non-production environments
- ✅ Used with caution in production
- ✅ Deployed with proper backup and rollback plans
- ⚠️ Considered experimental until v2.0.0

### Complete Feature Set (v1.0.8)

- ✅ **Zero-downtime cutover** - VIP swap in seconds
- ✅ **Multi-database migration** - Migrate N databases atomically (NEW v1.0.8)
- ✅ **Bidirectional DDL replication** - Schema changes replicate both ways
- ✅ **Self-healing reconciliation** - Automatically fixes missing components
- ✅ **Cluster-wide state management** - Works across node reboots and failovers
- ✅ **Idempotent operations** - Safe to run regardless of cluster state
- ✅ **Auto-stop after completion** - Resource stops automatically (FIXED v1.0.7)

### Migration Agent Version History

**v1.0.8** (2026-01-05):
- **NEW**: Multi-database migration support
- **NEW**: `databases` parameter (comma-separated list)
- **NEW**: Per-database publications, subscriptions, slots, triggers
- **NEW**: Per-database state tracking and monitoring
- **NEW**: Atomic cutover for all databases
- Backward compatible with `pgdatabase` parameter

**v1.0.7** (2026-01-05):
- **FIX**: Auto-stop timing after cutover completion
- **FIX**: Set target-role=Stopped immediately (not in monitor)
- **FIX**: Eliminates restart loops from attribute cleanup race
- Monitor function provides safety net for edge cases

**v1.0.6** (2026-01-02):
- Fixed cluster attribute scope (node-scoped → cluster-wide)
- Added automatic cleanup when migration completes
- Added stale state detection

**v1.0.5** (2026-01-02):
- Cutover window optimization (98% faster reverse DDL setup)

**v1.0.4** (2026-01-02):
- Bidirectional DDL replication

**v1.0.3** (2026-01-02):
- Completion detection improvements
- Auto-stop when complete

---

## pgtwin v1.6.18 (No Changes)

pgtwin remains at **v1.6.18** - stable and production ready.

All v1.6.18 features and fixes from v1.7.0 release continue to apply:
- Synchronous standby names handling (v1.6.18)
- VIP colocation fix (v1.6.16)
- XML cluster discovery fix (v1.6.15)
- Configuration detection enhancements (v1.6.14)
- Parallel cluster discovery fix (v1.6.13)
- Timeline warning (v1.6.12)
- Resource cleanup optimization (v1.6.11)
- Slot creation before basebackup (v1.6.10)

See **RELEASE_v1.7.0.md** for complete v1.6.x changelog.

---

## Installation

### pgtwin (Production Ready)

```bash
# Install pgtwin
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Install container library (if using container mode)
sudo cp pgtwin-container-lib.sh /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
sudo chmod 644 /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
```

### pgtwin-migrate (⚠️ Experimental)

```bash
# Install pgtwin-migrate
sudo cp pgtwin-migrate /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate

# IMPORTANT: Read full documentation before use
# See: README-pgtwin-migrate.md
```

---

## Upgrade Path

### From v1.7.0 to v1.7.1

**For pgtwin users:**

No changes to pgtwin - optional upgrade, no action needed unless using pgtwin-migrate.

**For pgtwin-migrate users:**

1. **Stop any running migrations:**
   ```bash
   crm resource stop migration-forward
   ```

2. **Deploy new pgtwin-migrate:**
   ```bash
   for node in node1 node2 node3 node4; do
       scp pgtwin-migrate root@$node:/usr/lib/ocf/resource.d/heartbeat/
       ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate"
   done
   ```

3. **(Optional) Enable multi-database migration:**
   ```bash
   crm configure edit migration-forward
   # Change: pgdatabase="postgres"
   # To:     databases="postgres,myapp,analytics"
   ```

4. **Start migration:**
   ```bash
   crm resource start migration-forward
   ```

**For new multi-database migrations:**

See **FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md** for:
- Pre-migration checklist (all databases must exist on both clusters)
- .pgpass file setup (entries for all databases)
- Configuration examples
- Monitoring guide

---

## Breaking Changes

**None** - All changes are backward compatible

- Legacy `pgdatabase` parameter still works
- Single-database migrations work identically
- No cluster reconfiguration needed

---

## Configuration Examples

### Single Database (Legacy - Still Works)

```bash
primitive migration-forward pgtwin-migrate \
    params \
        pgdatabase="postgres" \
        source_cluster=postgres-clone \
        target_cluster=postgres-clone-18 \
        source_replication_vip=192.168.60.104 \
        target_replication_vip=192.168.60.105 \
        production_vip_resource=postgres-vip \
        target_vip_resource=postgres-vip-18
```

### Two Databases (New - Minimal)

```bash
primitive migration-forward pgtwin-migrate \
    params \
        databases="postgres,myapp" \
        source_cluster=postgres-clone \
        target_cluster=postgres-clone-18 \
        source_replication_vip=192.168.60.104 \
        target_replication_vip=192.168.60.105 \
        production_vip_resource=postgres-vip \
        target_vip_resource=postgres-vip-18 \
        pgport=5432 \
        migration_dbuser=pgmigrate
```

### Five Databases (New - Complete)

```bash
primitive migration-forward pgtwin-migrate \
    params \
        databases="postgres,auth,users,orders,inventory" \
        source_cluster=postgres-clone \
        source_replication_vip=192.168.60.104 \
        target_cluster=postgres-clone-18 \
        target_replication_vip=192.168.60.105 \
        production_vip_resource=postgres-vip \
        target_vip_resource=postgres-vip-18 \
        source_pg_bindir="/usr/lib/postgresql17/bin" \
        target_pg_bindir="/usr/lib/postgresql18/bin" \
        pgport=5432 \
        migration_dbuser=pgmigrate \
        cutover_ready=false \
    op start timeout=600s interval=0s \
    op stop timeout=60s interval=0s \
    op monitor timeout=30s interval=10s \
    meta target-role=Started migration-threshold=3 failure-timeout=300s
```

---

## Known Issues

### pgtwin

None known

### pgtwin-migrate (⚠️ Experimental)

**General:**
- **New table DML delay**: When new table created on target, DML replication delayed until subscription refreshed (typically <2 minutes, no data loss)
- **Manual subscription refresh**: For immediate DML replication: `ALTER SUBSCRIPTION <name> REFRESH PUBLICATION;`
- **Future enhancement**: Automatic subscription refresh via LISTEN/NOTIFY (planned v1.1+)

**Multi-Database (NEW v1.0.8):**
- **All databases must exist** on both clusters before starting migration
- **Database list cannot change** during active migration (validated before cutover)
- **Cutover window increases** with database count (~30-60s per additional database)
- **Resource usage scales linearly** with database count (plan PostgreSQL config accordingly)

---

## Testing Recommendations

### pgtwin Testing

No changes from v1.7.0 - see **RELEASE_v1.7.0.md** for testing guide.

### pgtwin-migrate Testing (Updated for v1.0.8)

**MUST test in non-production first:**

#### Single-Database Migration Test

1. Deploy two test clusters (source and target)
2. Run complete migration workflow
3. Test reverse replication
4. Test fallback scenarios
5. Validate application behavior

#### Multi-Database Migration Test (NEW)

1. **Pre-migration validation:**
   ```bash
   # Verify all databases exist on both clusters
   for db in postgres myapp analytics; do
       ssh source "psql -d $db -c 'SELECT current_database();'"
       ssh target "psql -d $db -c 'SELECT current_database();'"
   done
   ```

2. **Monitor all databases during migration:**
   ```bash
   # Watch replication lag for all databases
   watch -n 2 'for db in postgres myapp analytics; do \
       echo "=== $db ==="; \
       psql -d $db -x -c "SELECT * FROM pg_stat_subscription"; \
   done'
   ```

3. **Verify cutover atomicity:**
   - All databases should switch at same time (single VIP swap)
   - No partial migration scenarios

4. **Test reverse replication for all databases:**
   ```bash
   # Insert test data on target
   for db in postgres myapp analytics; do
       psql -h target -d $db -c "INSERT INTO test_table VALUES (...);"
   done

   # Verify replication to source
   for db in postgres myapp analytics; do
       psql -h source -d $db -c "SELECT * FROM test_table;"
   done
   ```

See **FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md** for complete testing guide.

---

## Documentation

### New in v1.7.1

- **FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md** (500+ lines)
  - Complete technical specification
  - Four detailed use cases
  - Configuration examples
  - Pre-migration checklist
  - Monitoring guide
  - Troubleshooting section
  - Performance characteristics

- **BUGFIX_AUTO_STOP_TIMING_v1.0.7.md**
  - Problem description and root cause
  - Solution implementation
  - Testing guide
  - Deployment instructions

### Existing Documentation

- **README-pgtwin-migrate.md** - Complete usage guide
- **MIGRATION_DOCUMENTATION_INDEX.md** - Full migration workflow
- **PGTWIN_CONCEPTS.md** - Conceptual overview
- **README.md** - Main project documentation
- **QUICKSTART.md** - Quick start guide

---

## Contributors

- pgtwin project team
- Community testers and feedback providers

---

## Support

**For issues:**
- Review documentation in `doc/` directory
- Check TROUBLESHOOTING sections in documentation
- Review Pacemaker and PostgreSQL logs

**For pgtwin-migrate (experimental):**
- Thorough testing in non-production is essential
- Have backup and rollback plan ready
- Monitor closely during first production use

**For multi-database migrations (NEW):**
- Read FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md completely
- Validate all prerequisites (databases exist, .pgpass configured, etc.)
- Start with 2-3 databases before attempting larger migrations
- Monitor each database independently during migration

---

## License

GPL-2.0-or-later

---

## Summary

**v1.7.1** is a focused release featuring:
- **pgtwin-migrate v1.0.8**: Multi-database migration support (major feature)
- **pgtwin-migrate v1.0.7**: Auto-stop timing fix (critical bugfix)
- **pgtwin v1.6.18**: No changes (stable, production ready)
- Backward compatible - safe upgrade from v1.7.0

**Highlights:**

✅ **Multi-Database Migration** - Migrate N databases atomically with single VIP swap
✅ **Auto-Stop Fix** - Resource stops automatically after cutover completion
✅ **Complete Documentation** - 500+ lines of new documentation
✅ **Backward Compatible** - Legacy configurations continue to work
✅ **Production Ready pgtwin** - No changes, stable and reliable

**Recommendation:**
- ✅ **pgtwin users**: Optional upgrade (no changes to pgtwin)
- ✅ **pgtwin-migrate single-DB users**: Recommended for auto-stop fix
- 🆕 **pgtwin-migrate multi-DB users**: Upgrade required for multi-database support
- ⚠️ **All pgtwin-migrate users**: Test thoroughly before production use

---

**Next Release:** v1.8.0 or v2.0.0 (pgtwin-migrate promoted to production-ready)
