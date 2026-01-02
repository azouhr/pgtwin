# pgtwin PostgreSQL High Availability - Documentation Index

**Last Updated**: 2025-12-27
**Project Version**: v1.6.13
**Status**: Production Ready

---

## Quick Navigation

### 🎯 Start Here

**New to pgtwin?**
➡️ [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - **Conceptual overview of both agents**

**Setting up HA cluster?**
➡️ [README-resource-agent.md](README-resource-agent.md) - Resource agent usage guide
➡️ [README-HA-CLUSTER.md](README-HA-CLUSTER.md) - Complete cluster setup (German)

**Planning PostgreSQL migration?**
➡️ [MIGRATION_DOCUMENTATION_INDEX.md](MIGRATION_DOCUMENTATION_INDEX.md) - Migration documentation hub

**Configuring PostgreSQL for HA?**
➡️ [README.postgres.md](README.postgres.md) - PostgreSQL configuration best practices

---

## Documentation Categories

### 1. Conceptual Documentation

| Document | Purpose | Size | Audience |
|----------|---------|------|----------|
| [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) | Complete conceptual overview of pgtwin and pgtwin-migrate agents | 30KB | Admins, DBAs, Architects |

**What's inside:**
- How pgtwin manages PostgreSQL HA (auto-initialization, pg_rewind, monitoring)
- How pgtwin-migrate orchestrates zero-downtime upgrades
- Design principles and implementation philosophy
- State machines, failure handling, safety mechanisms
- Quick reference for both agents

---

### 2. Setup and Configuration

| Document | Purpose | Size | Audience |
|----------|---------|------|----------|
| [README-resource-agent.md](README-resource-agent.md) | pgtwin OCF agent usage and configuration | ~15KB | System Admins |
| [README-HA-CLUSTER.md](README-HA-CLUSTER.md) | Complete HA cluster setup guide (German) | ~20KB | System Admins |
| [README.postgres.md](README.postgres.md) | PostgreSQL configuration for HA (v1.5) | ~25KB | DBAs |

**README-resource-agent.md covers:**
- Resource agent parameters
- Basic cluster configuration
- Monitoring and operations
- Troubleshooting

**README.postgres.md covers:**
- Critical configuration options (restart_after_crash, wal_log_hints)
- Dangerous settings to avoid
- Performance tuning
- Replication configuration
- Security considerations

---

### 3. Migration Documentation

**Complete migration documentation suite:**
➡️ [MIGRATION_DOCUMENTATION_INDEX.md](MIGRATION_DOCUMENTATION_INDEX.md)

**Includes 6 documents:**
1. MIGRATION_PLANNING_WORKSHEET.md (28KB) - Pre-planning template
2. ADMIN_PREPARATION_PGTWIN_MIGRATE.md (18KB) - Setup guide
3. MIGRATION_SETUP_COMPLETE.md (16KB) - Operational reference
4. MIGRATION_CUTOVER_PROCEDURE.md (14KB) - Cutover execution guide
5. POST_MIGRATION_CLEANUP.md (17KB) - Cleanup procedures
6. CUTOVER_CLEANUP_COMPLETE.md (14KB) - Execution report (example)

**Total**: 107KB of migration documentation

---

### 4. Design Documentation

| Category | Documents | Purpose |
|----------|-----------|---------|
| **Core Design** | DESIGN_DECISIONS_CONSOLIDATED.md | Master design decisions |
| **Storage** | DESIGN_STORAGE_*.md | Storage architecture, cache, compression |
| **Container** | DESIGN_CONTAINER_*.md | Container mode design and optimization |
| **Migration** | DESIGN_PGTWIN_MIGRATE_*.md | Migration agent design |
| **Features** | DESIGN_*.md | Various feature designs |

**Key design documents:**
- [DESIGN_DECISIONS_CONSOLIDATED.md](DESIGN_DECISIONS_CONSOLIDATED.md) - Single source of truth for design
- [DESIGN_PGTWIN_MIGRATE_AGENT.md](DESIGN_PGTWIN_MIGRATE_AGENT.md) - Migration agent specification
- [DESIGN_PGTWIN_MIGRATE_CUTOVER_AUTOMATION.md](DESIGN_PGTWIN_MIGRATE_CUTOVER_AUTOMATION.md) - Cutover automation design (v2.0)

---

### 5. Feature Documentation

**Recent Features** (v1.6.x series):

| Feature | Document | Version | Description |
|---------|----------|---------|-------------|
| Timeline Warning | FEATURE_TIMELINE_WARNING_v1.6.12.md | v1.6.12 | Non-blocking timeline divergence detection |
| Auto Cleanup | FEATURE_AUTO_CLEANUP_v1.6.8.md | v1.6.11 | Self-triggered cleanup after pg_basebackup |
| Version Validation | VERSION_VALIDATION_DEMO.md | v1.6.7 | PostgreSQL version mismatch detection |
| Auto Initialization | BUGFIX_PG_BASEBACKUP_FINALIZATION.md | v1.6.6 | Zero-touch standby deployment |
| Notify Support | github/doc/FEATURE_NOTIFY_SUPPORT.md | v1.6.6 | Dynamic sync/async switching |
| Container Mode | RELEASE_v1.6.5_CONTAINER_MODE.md | v1.6.5 | Seamless Podman/Docker support |

---

### 6. Bug Fixes and Improvements

| Fix | Document | Version | Impact |
|-----|----------|---------|--------|
| pg_basebackup Finalization | BUGFIX_PG_BASEBACKUP_FINALIZATION.md | v1.6.6 | Critical fix for empty primary_conninfo |
| Slot Creation Before Basebackup | BUGFIX_SLOT_CREATION_BEFORE_BASEBACKUP.md | v1.6.10 | Prevents WAL recycling race |
| Parallel Cluster Discovery | BUGFIX_PARALLEL_CLUSTER_DISCOVERY_v1.6.13.md | v1.6.13 | Performance improvement |
| File Ownership | BUGFIX_FILE_OWNERSHIP_v1.6.7.md | v1.6.7 | Container security fix |
| Synchronous Standby Names | BUGFIX_SYNCHRONOUS_STANDBY_NAMES.md | Various | Configuration fix |

---

### 7. Release Documentation

| Release | Document | Key Features |
|---------|----------|--------------|
| v1.6.7 | RELEASE_v1.6.7.md | Version validation, file ownership fix |
| v1.6.6 | RELEASE_v1.6.6_SUMMARY.md | Auto-initialization, notify support, critical bug fix |
| v1.6.5 | RELEASE_v1.6.5_CONTAINER_MODE.md | Container mode (Phase 1) |
| v1.6.1 | RELEASE_v1.6.1.md | 6 critical bug fixes |
| v1.5 | RELEASE_v1.5.md | Configuration resilience |
| v1.4 | RELEASE_v1.4.md | Critical bug fixes, STONITH |

---

### 8. Testing and Validation

| Document | Purpose |
|----------|---------|
| TEST_SUITE_DOCUMENTATION.md | Test suite overview |
| COMPREHENSIVE_TEST_REPORT_v1.6.1.md | Complete test results |
| CLUSTER_TEST_REPORT.md | Cluster testing results |
| CONTAINER_MODE_TEST_REPORT.md | Container mode validation |
| VERSION_VALIDATION_DEMO.md | Version validation testing |

---

### 9. Operational Guides

| Document | Purpose | Audience |
|----------|---------|----------|
| github/MAINTENANCE_GUIDE.md | Operational procedures | System Admins |
| MANUAL_RECOVERY_GUIDE.md | Manual recovery procedures | DBAs |
| LOG_MANAGEMENT_GUIDE.md | Log management and rotation | System Admins |
| PRODUCTION_CHECKLIST.md | Pre-production validation | All |
| PRODUCTION_CHECKLIST_QUICK.md | Quick pre-prod checks | All |

---

### 10. Specialized Topics

#### Container Mode
- DESIGN_CONTAINER_MODE.md - Design specification
- CONTAINER_MODE_IMPLEMENTATION.md - Implementation details
- CONTAINER_MODE_SECURITY.md - Security model
- SEAMLESS_CONTAINER_USAGE_GUIDE.md - Usage guide
- CONTAINER_PERFORMANCE_QUICK_GUIDE.md - Performance optimization

#### Storage and Performance
- DESIGN_STORAGE_DECISION.md - Storage architecture
- DESIGN_CACHE_PLACEMENT_STRATEGY.md - Cache strategy
- DESIGN_COMPRESSION_LAYER_COMPARISON.md - Compression options
- DESIGN_BTRFS_FEATURES.md - Btrfs usage for PostgreSQL

#### Specialized Deployments
- DESIGN_K3S_KINE_PGTWIN_INTEGRATION.md - Kubernetes integration
- DESIGN_MAINFRAME_*.md - IBM Z mainframe deployments
- DESIGN_DATACENTER_INTEGRATION_ANALYSIS.md - Datacenter integration

---

## Documentation by Role

### Database Administrator (DBA)

**Essential Reading:**
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Understanding how it works
2. [README.postgres.md](README.postgres.md) - PostgreSQL configuration
3. [README-resource-agent.md](README-resource-agent.md) - Resource agent usage
4. [MANUAL_RECOVERY_GUIDE.md](MANUAL_RECOVERY_GUIDE.md) - Recovery procedures

**For Migrations:**
- [MIGRATION_DOCUMENTATION_INDEX.md](MIGRATION_DOCUMENTATION_INDEX.md) - Start here

### System Administrator

**Essential Reading:**
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Understanding architecture
2. [README-HA-CLUSTER.md](README-HA-CLUSTER.md) - Cluster setup
3. [README-resource-agent.md](README-resource-agent.md) - Agent configuration
4. github/MAINTENANCE_GUIDE.md - Operational procedures

**For Container Deployments:**
- SEAMLESS_CONTAINER_USAGE_GUIDE.md
- CONTAINER_MODE_SECURITY.md

### Architect

**Essential Reading:**
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Conceptual overview
2. [DESIGN_DECISIONS_CONSOLIDATED.md](DESIGN_DECISIONS_CONSOLIDATED.md) - Design decisions
3. [DESIGN_PGTWIN_MIGRATE_AGENT.md](DESIGN_PGTWIN_MIGRATE_AGENT.md) - Migration design
4. [README.postgres.md](README.postgres.md) - Configuration implications

**For Specialized Deployments:**
- DESIGN_STORAGE_*.md - Storage architecture
- DESIGN_CONTAINER_*.md - Container architecture
- DESIGN_K3S_*.md - Kubernetes integration

### Developer

**Essential Reading:**
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Implementation philosophy
2. pgtwin source code (3180 lines)
3. pgtwin-migrate source code (1098 lines)
4. TEST_SUITE_DOCUMENTATION.md - Testing approach

**Design Documents:**
- DESIGN_*.md - All design specifications
- FEATURE_*.md - Feature implementations
- BUGFIX_*.md - Bug fix details

---

## Documentation by Task

### Setting Up New HA Cluster
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Understand the system
2. [README.postgres.md](README.postgres.md) - Configure PostgreSQL
3. [README-HA-CLUSTER.md](README-HA-CLUSTER.md) - Deploy cluster
4. [PRODUCTION_CHECKLIST.md](PRODUCTION_CHECKLIST.md) - Validate setup

### Planning Major Version Upgrade
1. [MIGRATION_DOCUMENTATION_INDEX.md](MIGRATION_DOCUMENTATION_INDEX.md) - Migration hub
2. MIGRATION_PLANNING_WORKSHEET.md - Collect requirements
3. ADMIN_PREPARATION_PGTWIN_MIGRATE.md - Setup guide
4. MIGRATION_CUTOVER_PROCEDURE.md - Execute cutover

### Troubleshooting Cluster Issues
1. github/MAINTENANCE_GUIDE.md - Common operations
2. [MANUAL_RECOVERY_GUIDE.md](MANUAL_RECOVERY_GUIDE.md) - Recovery procedures
3. [README-resource-agent.md](README-resource-agent.md) - Troubleshooting section
4. LOG_MANAGEMENT_GUIDE.md - Log analysis

### Deploying Container Mode
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Section 2.2.7 (Container Mode)
2. SEAMLESS_CONTAINER_USAGE_GUIDE.md - Step-by-step guide
3. CONTAINER_MODE_SECURITY.md - Security considerations
4. CONTAINER_MODE_TEST_REPORT.md - What to expect

### Understanding a Feature
1. [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) - Conceptual explanation
2. FEATURE_*.md or DESIGN_*.md - Detailed specification
3. pgtwin or pgtwin-migrate source - Implementation
4. TEST_*.md - Testing validation

---

## Quick Reference

### File Sizes

**Concept Documentation**: ~30KB
- PGTWIN_CONCEPTS.md: 30KB

**Setup Guides**: ~60KB
- README-resource-agent.md: ~15KB
- README-HA-CLUSTER.md: ~20KB
- README.postgres.md: ~25KB

**Migration Suite**: 107KB
- 6 documents covering complete migration workflow

**Design Documents**: ~200KB+
- 50+ design documents covering all aspects

**Total Documentation**: ~500KB+ (excluding source code)

### Source Code

| File | Lines | Purpose |
|------|-------|---------|
| pgtwin | 3,180 | Core HA resource agent |
| pgtwin-migrate | 1,098 | Migration orchestrator |
| pgtwin-container-lib.sh | ~500 | Container mode library |

**Total Code**: ~4,800 lines

---

## Version History

| Version | Date | Key Changes |
|---------|------|-------------|
| v1.6.13 | 2025-12-26 | Parallel cluster discovery optimization |
| v1.6.12 | 2025-12-26 | Non-blocking timeline warning |
| v1.6.11 | 2025-12-25 | Auto cleanup after pg_basebackup |
| v1.6.10 | 2025-12-24 | Slot creation before basebackup |
| v1.6.7 | 2025-12-23 | Version validation, file ownership fix |
| v1.6.6 | 2025-12-22 | Auto-initialization, notify support, critical bug fix |
| v1.6.5 | 2025-12-21 | Container mode support (Phase 1) |
| v1.5 | 2025-12 | Configuration resilience |
| v1.4 | 2025-12 | Critical bug fixes, STONITH |

See individual release documents for detailed changelogs.

---

## Contributing to Documentation

### Documentation Standards

1. **Conceptual docs**: Explain the "why" and "how it works"
2. **Setup guides**: Step-by-step procedures with examples
3. **Design docs**: Technical specifications and rationale
4. **Feature docs**: Implementation details and testing

### File Naming Conventions

- `README-*.md` - User-facing guides
- `DESIGN_*.md` - Design specifications
- `FEATURE_*.md` - Feature documentation
- `BUGFIX_*.md` - Bug fix documentation
- `RELEASE_*.md` - Release notes
- `TEST_*.md` - Testing documentation

---

## Getting Help

### Documentation Issues
- Check this index for the right document
- Review [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) for conceptual understanding
- Consult specialized guides for specific tasks

### Technical Support
- Check github/MAINTENANCE_GUIDE.md for common operations
- Review [MANUAL_RECOVERY_GUIDE.md](MANUAL_RECOVERY_GUIDE.md) for recovery scenarios
- See README-resource-agent.md troubleshooting section

### Community
- GitHub: https://github.com/anthropics/pgtwin (if published)
- Issues: Report via GitHub issues
- Discussions: GitHub discussions (if enabled)

---

## License

All documentation: GPL-2.0-or-later (same as code)

---

**Document Index Status**: ✅ COMPLETE

All major documentation categories covered. New documents should be added to appropriate sections above.

**Last Reviewed**: 2025-12-27
**Maintainer**: pgtwin project team
