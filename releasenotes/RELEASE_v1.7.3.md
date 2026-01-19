# pgtwin v1.7.3 Release Notes

**Release Date:** 2026-01-19
**Type:** Feature Release
**Status:** Production Ready (pgtwin), Experimental (pgtwin-migrate)

---

## Overview

This release includes pgtwin v1.7.3 (production ready) and introduces:
- **pgtwin-migrate-setup v1.0.0** - Interactive setup wizard for migration configuration
- **pgtwin-migrate v2.0.0** (EXPERIMENTAL) - Major redesign with bidirectional failover

---

## What's New

### pgtwin v1.7.3 (Production Ready)

No functional changes from v1.7.2. Version bump for release coordination.

For v1.7.2 changes (FQDN hostname mismatch bugfix), see [RELEASE_v1.7.2.md](RELEASE_v1.7.2.md).

---

### pgtwin-migrate-setup v1.0.0 (NEW)

**Interactive setup wizard for pgtwin-migrate configuration.**

#### Features

- **Guided configuration** - Step-by-step wizard collects all migration parameters
- **Configuration file generation** - Creates reusable `.conf` files
- **CRM snippet generation** - Generates ready-to-use Pacemaker configuration
- **Validation** - Validates cluster connectivity, database access, VIP resources
- **Template support** - Load existing configs with `--config FILE`

#### Usage

```bash
# Interactive setup
./pgtwin-migrate-setup

# Load existing config and modify
./pgtwin-migrate-setup --config migration-forward.conf
```

#### Output Files

1. `migration-forward.conf` - Configuration file (sourceable shell script)
2. `migration-forward.crm` - Pacemaker CRM configuration

#### Example Workflow

```bash
# Step 1: Run setup wizard
./pgtwin-migrate-setup

# Step 2: Apply Pacemaker configuration
crm configure load update migration-forward.crm

# Step 3: Start migration
crm resource start migration-forward
```

See: [README-pgtwin-migrate-setup.md](../README-pgtwin-migrate-setup.md) (to be added)

---

### pgtwin-migrate v2.0.0 (EXPERIMENTAL)

**Major redesign with bidirectional failover capability.**

> **WARNING:** This version is EXPERIMENTAL. Not recommended for production use without thorough testing in your environment.

#### New Features

##### 1. Bidirectional Failover with `production_cluster` Parameter

**Before (v1.x):** `cutover_ready=true` was a one-shot trigger, no easy failback

**After (v2.0):** `production_cluster` parameter allows switching production between clusters:

```bash
# Initial: source is production
crm resource start migration-forward
# Forward replication active: PG17 → PG18

# Cutover to target
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone-18
# Reverse replication active: PG18 → PG17

# Failback to source (if needed)
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone
# Forward replication active again
```

##### 2. Dynamic Database Discovery

**Before:** Required explicit `databases` parameter, needed CRM update when databases changed

**After:** Discovers databases at runtime from production cluster:
- No `databases` parameter needed (auto-discover)
- New databases detected automatically every 10th monitor cycle
- Replication set up automatically for new databases (publication, subscription, schema copy)

##### 3. Delete/Create vs Disable/Enable

**Before:** Cutover disabled old direction, enabled new direction (stale subscription risk)

**After:** Cutover DELETES old direction, CREATES new direction fresh:
- No stale subscription state
- No schema drift issues
- Same code path for cutover and finalization

##### 4. Direction-Aware Start Function

Start function now correctly handles both forward and reverse directions:
- Checks for publications matching current `production_cluster`
- Sets up replication for the correct direction
- Properly sets CIB state (`FORWARD_REPLICATION` or `CUTOVER_COMPLETE`)

##### 5. New Database Auto-Setup

Monitor detects databases without replication and sets them up automatically:
- Creates database on subscriber if it doesn't exist
- Copies schema from publisher to subscriber
- Creates publication and subscription with `copy_data=true`
- Sets up DDL trigger

#### Changed Parameters

| Parameter | Change | Description |
|-----------|--------|-------------|
| `production_cluster` | NEW | Which cluster should be production. Changing triggers cutover. |
| `finalize_replication` | NEW | When true, stop cleans up all replication infrastructure. |
| `stability_timeout` | NEW | Seconds to wait for cluster stability before cutover. |
| `cutover_ready` | REMOVED | Replaced by `production_cluster` |

#### Migration from v1.x

1. Remove `cutover_ready` parameter if present
2. Add `production_cluster=<source_cluster_name>` (initial state)
3. Cutover: Change `production_cluster` to target cluster name
4. Finalize: Set `finalize_replication=true` then stop

---

## File Changes

| File | Version | Status | Notes |
|------|---------|--------|-------|
| `pgtwin` | 1.7.3 | Production Ready | No changes from v1.7.2 |
| `pgtwin-migrate` | 2.0.0 | EXPERIMENTAL | Major redesign |
| `pgtwin-migrate-setup` | 1.0.0 | NEW | Interactive setup wizard |
| `pgtwin-container-lib.sh` | - | No change | Container support library |

---

## Installation

### pgtwin (Production)

```bash
# Copy to all cluster nodes
cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Container library (if using container mode)
cp pgtwin-container-lib.sh /usr/lib/ocf/lib/heartbeat/
chmod 644 /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
```

### pgtwin-migrate (Experimental)

```bash
# Copy to all cluster nodes (both source and target clusters)
cp pgtwin-migrate /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin-migrate
```

### pgtwin-migrate-setup

```bash
# Copy to admin workstation or cluster node
cp pgtwin-migrate-setup /usr/local/bin/
chmod 755 /usr/local/bin/pgtwin-migrate-setup
```

---

## Upgrade Path

### From pgtwin v1.7.2

1. Stop cluster resources: `crm resource stop <resource>`
2. Copy new pgtwin to all nodes
3. Start cluster resources: `crm resource start <resource>`

### From pgtwin-migrate v1.x

> **CAUTION:** v2.0 changes are significant. Test thoroughly before upgrading production migrations.

1. Complete any in-progress migrations
2. Stop and delete old migration resource
3. Deploy pgtwin-migrate v2.0
4. Use pgtwin-migrate-setup to generate new configuration
5. Test with non-production data first

---

## Known Limitations

### pgtwin-migrate v2.0 (Experimental)

1. **max_logical_replication_workers limit** - PostgreSQL default is 4 workers. For migrations with many databases, increase this setting in `postgresql.custom.conf`.

2. **Initial sync for new databases** - When a new database is created, `copy_data=true` handles initial sync, but the database must exist on both clusters (subscriber creates it automatically).

3. **Schema changes during migration** - DDL triggers handle most schema changes, but complex migrations may need manual coordination.

---

## Testing

All features tested on:
- openSUSE Tumbleweed
- PostgreSQL 17.6 → PostgreSQL 18.x migration
- 4-node combined cluster (pgtwin01/02, pgtwin11/12)

Test coverage:
- ✓ Forward replication start
- ✓ Cutover to reverse replication
- ✓ New database auto-detection and setup
- ✓ Direction-aware publication checking
- ✓ CIB state management

---

## Documentation

- [QUICKSTART.md](../QUICKSTART.md) - Getting started guide
- [README-pgtwin-migrate.md](../README-pgtwin-migrate.md) - Migration agent documentation
- [MIGRATION_DOCUMENTATION_INDEX.md](../MIGRATION_DOCUMENTATION_INDEX.md) - Complete migration documentation
- [PGTWIN_CONCEPTS.md](../PGTWIN_CONCEPTS.md) - Core concepts and design philosophy
