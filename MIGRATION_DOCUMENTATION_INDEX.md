# PostgreSQL Migration Documentation - Complete Index

**Last Updated**: 2026-01-19
**Status**: pgtwin-migrate v2.0.0 EXPERIMENTAL
**Total Documentation**: 7+ files

---

## What's New in v2.0.0

**pgtwin-migrate v2.0.0** is a major redesign with bidirectional failover capability:

- **`production_cluster` parameter** - Replaces `cutover_ready`. Change this to switch production between clusters.
- **Dynamic database discovery** - No explicit `databases` parameter needed. Databases discovered at runtime.
- **Direction-aware start function** - Correctly handles both forward and reverse directions.
- **New database auto-setup** - Monitor detects databases without replication and sets them up automatically.

**pgtwin-migrate-setup v1.0.0** - NEW interactive setup wizard:
- Guided configuration collection
- Configuration file generation (`.conf` files)
- CRM snippet generation (ready-to-use Pacemaker configuration)

> **WARNING**: pgtwin-migrate v2.0.0 is EXPERIMENTAL. Test thoroughly before production use.

---

## Quick Navigation

### For Administrators Planning Migration
➡️ **START HERE**: [MIGRATION_PLANNING_WORKSHEET.md](MIGRATION_PLANNING_WORKSHEET.md)

### For Quick Setup (NEW)
➡️ **RECOMMENDED**: Run `pgtwin-migrate-setup` for interactive configuration

### For Implementation
1. [ADMIN_PREPARATION_PGTWIN_MIGRATE.md](ADMIN_PREPARATION_PGTWIN_MIGRATE.md)
2. [MIGRATION_SETUP_COMPLETE.md](MIGRATION_SETUP_COMPLETE.md)

### For Production Cutover (v2.0 Method)
```bash
# Change production_cluster to trigger cutover
crm_resource --resource migration-forward \
  --set-parameter production_cluster \
  --parameter-value postgres-clone-18
```

### For Post-Migration
➡️ [POST_MIGRATION_CLEANUP.md](POST_MIGRATION_CLEANUP.md)

### Cutover Execution Report
➡️ [CUTOVER_CLEANUP_COMPLETE.md](CUTOVER_CLEANUP_COMPLETE.md) - Complete record of production cutover

### Design Documents
➡️ [DESIGN_PGTWIN_MIGRATE_CUTOVER_AUTOMATION.md](DESIGN_PGTWIN_MIGRATE_CUTOVER_AUTOMATION.md) - Cutover automation design

---

## Document Details

### 1. MIGRATION_PLANNING_WORKSHEET.md (28KB)
**When to Use**: BEFORE starting any migration work  
**Purpose**: Collect all required information upfront

**Contains**:
- Cluster configuration (PG17 & PG18)
- Network configuration (IPs, VIPs, subnets)
- Database users and authentication
- Migration resource parameters
- Timeline and schedule
- Backup and recovery plans
- Testing procedures
- Contact information
- Approval checklists

**Output**: Completed worksheet with all values filled in

---

### 2. ADMIN_PREPARATION_PGTWIN_MIGRATE.md (18KB)
**When to Use**: During initial setup phase  
**Purpose**: Step-by-step setup guide

**Contains**:
- Phase 1: PostgreSQL Configuration
- Phase 2: User Management
- Phase 3: Password Management (.pgpass)
- Phase 4: DDL Replication Setup
- Phase 5: Publications
- Phase 6: Agent Deployment
- Phase 7: Pacemaker Resources
- Phase 8: Verification
- Phase 9: Testing
- Troubleshooting section

**Prerequisites**: Completed planning worksheet

---

### 3. MIGRATION_SETUP_COMPLETE.md (16KB)
**When to Use**: As operational reference  
**Purpose**: Document current state and provide monitoring commands

**Contains**:
- Complete cluster overview
- All VIP configurations
- Network architecture diagram
- Migration resource details
- Database users and permissions
- PostgreSQL configuration
- .pgpass file contents
- Operational monitoring commands
- Performance characteristics

**Use For**: Day-to-day operations, troubleshooting, reference

---

### 4. MIGRATION_CUTOVER_PROCEDURE.md (14KB) ⭐ CRITICAL
**When to Use**: During production cutover  
**Purpose**: Execute VIP cutover from PG17 to PG18

**Contains**:
- VIP architecture explanation
- Migration workflow phases
- Option A: Move VIP to PG18 (recommended)
- Option B: Reconfigure applications
- Step-by-step instructions
- Verification procedures
- Rollback procedures
- Timeline estimates (5-15 minutes)
- Common issues and solutions

**Prerequisites**: 
- Migration complete
- Data verified consistent
- Backups completed
- Maintenance window scheduled

---

### 5. POST_MIGRATION_CLEANUP.md (17KB)
**When to Use**: After stable operation on PG18 (7-30 days)  
**Purpose**: Clean up migration resources and optionally decommission PG17

**Contains**:
- Phase 1: Stop migration resources
- Phase 2: Clean up logical replication (PG18)
- Phase 3: Clean up logical replication (PG17)
- Phase 4: Verify replication slots removed
- Phase 5: Remove pgmigrate user
- Phase 6: Clean up pg_hba.conf
- Phase 7: Clean up .pgpass files
- Phase 8: Optional PG17 decommission
- Phase 9: Optional VIP cleanup
- Phase 10: Remove pgtwin-migrate agent
- Verification checklists
- Rollback procedures

**Prerequisites**:
- PG18 stable for 7-30 days
- Recent backups completed
- No rollback needed

---

### 6. CUTOVER_CLEANUP_COMPLETE.md (14KB)
**When to Use**: Reference document after cutover execution
**Purpose**: Complete record of production cutover and cleanup execution

**Contains**:
- Complete cutover execution summary
- All cleanup phases executed (9 phases)
- Final cluster state documentation
- VIP configuration changes
- Resource changes (deleted/remaining)
- Archived file locations
- Success criteria checklist
- Timeline of execution (10 minutes)
- Post-cutover recommendations
- Next steps for fresh cluster setup

**Key Information**:
- Cutover duration: ~3 minutes
- Total execution time: ~10 minutes
- PG17 data archived to .tar.gz files
- All migration resources removed
- PG18 cluster operational with 5 resources
- Replication VIP removed (not needed for production)

**Use For**: Historical reference, lessons learned, future migrations

---

## Migration Workflow (v2.0)

```
┌─────────────────────────────────────────────────────────────────┐
│ STEP 0: PRE-PLANNING (1-2 days)                                │
├─────────────────────────────────────────────────────────────────┤
│ Document: MIGRATION_PLANNING_WORKSHEET.md               ⭐      │
│ Fill out all sections, get approvals                           │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 1: SETUP (30 minutes - 2 hours)                    🆕     │
├─────────────────────────────────────────────────────────────────┤
│ Tool: pgtwin-migrate-setup (interactive wizard)                │
│ Generates: migration-forward.conf, migration-forward.crm       │
│ Then: crm configure load update migration-forward.crm          │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 2: START MIGRATION                                        │
├─────────────────────────────────────────────────────────────────┤
│ Command: crm resource start migration-forward                  │
│ Databases discovered automatically (v2.0)                      │
│ Replication set up for all discovered databases                │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 3: DATA SYNC (days to weeks)                              │
├─────────────────────────────────────────────────────────────────┤
│ Monitor: crm_attribute -G -n migration-state -q                │
│ New databases detected and synced automatically (v2.0)         │
│ Monitor replication, verify consistency, test apps             │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 4: CUTOVER (seconds)                               ⭐ 🆕  │
├─────────────────────────────────────────────────────────────────┤
│ Command: crm_resource --resource migration-forward \           │
│          --set-parameter production_cluster \                  │
│          --parameter-value postgres-clone-18                   │
│ Reverse replication starts automatically                       │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 5: STABILITY + OPTIONAL FAILBACK (7-30 days)              │
├─────────────────────────────────────────────────────────────────┤
│ Monitor PG18, keep PG17 as backup with reverse replication     │
│ Can failback by changing production_cluster back (v2.0)        │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 6: FINALIZE (when confident)                              │
├─────────────────────────────────────────────────────────────────┤
│ Command: crm_resource --resource migration-forward \           │
│          --set-parameter finalize_replication \                │
│          --parameter-value true                                │
│ Then: crm resource stop migration-forward                      │
│ Document: POST_MIGRATION_CLEANUP.md for remaining cleanup      │
└─────────────────────────────────────────────────────────────────┘
```

---

## By Role

### Database Administrator
**Primary Documents**:
1. MIGRATION_PLANNING_WORKSHEET.md (fill out)
2. ADMIN_PREPARATION_PGTWIN_MIGRATE.md (execute)
3. MIGRATION_SETUP_COMPLETE.md (reference)
4. POST_MIGRATION_CLEANUP.md (execute after stability)

**Critical Document**:
- MIGRATION_CUTOVER_PROCEDURE.md (execute during maintenance window)

### Project Manager
**Primary Documents**:
1. MIGRATION_PLANNING_WORKSHEET.md (review and approve)
2. MIGRATION_CUTOVER_PROCEDURE.md (understand timeline)

**Monitor Progress**:
- Timeline section in planning worksheet
- Status tracking in each document

### Application Team
**Primary Documents**:
1. MIGRATION_PLANNING_WORKSHEET.md (Section 7: Application Configuration)
2. MIGRATION_CUTOVER_PROCEDURE.md (understand impact)

**Need to Know**:
- Whether Option A (no changes) or Option B (reconfigure) will be used
- Maintenance window schedule
- Post-cutover validation procedures

### Infrastructure Team
**Primary Documents**:
1. MIGRATION_PLANNING_WORKSHEET.md (Section 2: Network Configuration)
2. MIGRATION_SETUP_COMPLETE.md (VIP architecture)

**Need to Know**:
- VIP addresses and purposes
- Firewall rules required
- Network changes during cutover

---

## By Task

### Setting Up Migration for the First Time
1. Read MIGRATION_PLANNING_WORKSHEET.md
2. Fill out all sections
3. Get approvals
4. Follow ADMIN_PREPARATION_PGTWIN_MIGRATE.md

### Monitoring Ongoing Migration
- Use MIGRATION_SETUP_COMPLETE.md for monitoring commands
- Check replication lag
- Verify data consistency

### Executing Production Cutover
- Follow MIGRATION_CUTOVER_PROCEDURE.md step-by-step
- Have rollback plan ready
- Verify at each step

### Cleaning Up After Migration
- Wait 7-30 days for stability
- Follow POST_MIGRATION_CLEANUP.md
- Remove resources in order

### Troubleshooting Issues
- Check troubleshooting sections in:
  - ADMIN_PREPARATION_PGTWIN_MIGRATE.md
  - MIGRATION_CUTOVER_PROCEDURE.md
  - POST_MIGRATION_CLEANUP.md

---

## Quick Reference

### Current Cluster State
```
PG17: pgtwin01 (primary), pgtwin11 (standby)
  - Application VIP: 192.168.60.100
  - Replication VIP: 192.168.60.104

PG18: pgtwin02 (primary), pgtwin12 (standby)
  - Application VIP: 192.168.60.101
  - Replication VIP: 192.168.60.105

Migration Resources:
  - migration-forward: PG17 → PG18 (on pgtwin12)
  - migration-reverse: PG18 → PG17 (on pgtwin11)
```

### Key Commands

**Check cluster status**:
```bash
crm status
```

**Monitor replication lag**:
```bash
sudo -u postgres psql -c "
SELECT 
    subname,
    pg_wal_lsn_diff(received_lsn, latest_end_lsn) as lag_bytes,
    latest_end_time
FROM pg_stat_subscription;"
```

**Manual subscription refresh**:
```bash
sudo -u postgres psql -c "
ALTER SUBSCRIPTION pgtwin_migrate_forward_sub REFRESH PUBLICATION WITH (copy_data = true);"
```

---

## Document Versions

| Document | Version | Last Updated | Status |
|----------|---------|--------------|--------|
| README-pgtwin-migrate.md | 2.0 | 2026-01-19 | v2.0 EXPERIMENTAL |
| MIGRATION_DOCUMENTATION_INDEX.md | 2.0 | 2026-01-19 | Updated for v2.0 |
| MIGRATION_PLANNING_WORKSHEET.md | 1.0 | 2025-12-27 | Current |
| ADMIN_PREPARATION_PGTWIN_MIGRATE.md | 1.0 | 2025-12-27 | Partially superseded by pgtwin-migrate-setup |
| MIGRATION_SETUP_COMPLETE.md | 1.0 | 2025-12-27 | Current |
| MIGRATION_CUTOVER_PROCEDURE.md | 1.0 | 2025-12-27 | Superseded by v2.0 cutover method |
| POST_MIGRATION_CLEANUP.md | 1.0 | 2025-12-27 | Current |
| CUTOVER_CLEANUP_COMPLETE.md | 1.0 | 2025-12-27 | Current |

---

## Getting Help

### Documentation Issues
If you find errors or have suggestions for improving documentation:
1. Document the issue in planning worksheet notes section
2. Update this index with corrections
3. Maintain version history

### Technical Issues
Refer to troubleshooting sections in:
- Setup issues: ADMIN_PREPARATION_PGTWIN_MIGRATE.md
- Cutover issues: MIGRATION_CUTOVER_PROCEDURE.md
- Cleanup issues: POST_MIGRATION_CLEANUP.md

### Emergency Contacts
See Section 11 of MIGRATION_PLANNING_WORKSHEET.md for:
- Database team contacts
- Application team contacts
- Escalation path

---

## Success Criteria

### Planning Complete
- [ ] MIGRATION_PLANNING_WORKSHEET.md filled out
- [ ] All approvals obtained
- [ ] Timeline agreed upon
- [ ] Team trained

### Setup Complete
- [ ] Both clusters configured
- [ ] Migration resources running
- [ ] Bidirectional replication working
- [ ] Tests successful

### Cutover Complete
- [ ] Application VIP on PG18
- [ ] Applications working
- [ ] No errors in logs
- [ ] Performance acceptable

### Cleanup Complete
- [ ] Migration resources removed
- [ ] pgmigrate user removed
- [ ] .pgpass files cleaned
- [ ] PG17 decommissioned (optional)

---

## File Locations

All documentation files are in:
```
/home/claude/postgresHA/
├── MIGRATION_PLANNING_WORKSHEET.md         (28KB)
├── ADMIN_PREPARATION_PGTWIN_MIGRATE.md     (18KB)
├── MIGRATION_SETUP_COMPLETE.md             (16KB)
├── MIGRATION_CUTOVER_PROCEDURE.md          (14KB)
├── POST_MIGRATION_CLEANUP.md               (17KB)
├── CUTOVER_CLEANUP_COMPLETE.md             (14KB)
└── MIGRATION_DOCUMENTATION_INDEX.md        (this file)
```

---

**READY FOR PRODUCTION MIGRATION**

All documentation complete and validated.
Start with MIGRATION_PLANNING_WORKSHEET.md!
