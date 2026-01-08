# pgtwin v1.7.0 Release Notes

**Release Date:** 2026-01-02  
**Type:** Combined Bugfix + Feature Release  
**Status:** Production Ready (pgtwin) / Experimental (pgtwin-migrate)

---

## Overview

This is a combined release featuring:
- **pgtwin v1.6.18**: Critical bugfixes and stability improvements
- **pgtwin-migrate v1.0.6** ⚠️ **EXPERIMENTAL**: Zero-downtime PostgreSQL migration agent

---

## ⚠️ EXPERIMENTAL: pgtwin-migrate

**A Pacemaker OCF agent that orchestrates PostgreSQL cluster migrations via logical replication (major version upgrades, vendor migrations, hosting provider changes, etc.)**

### Status: EXPERIMENTAL

pgtwin-migrate is included in this release as an **experimental feature**. While it has been tested and validated in development environments, it should be:
- ✅ Tested thoroughly in non-production environments
- ✅ Used with caution in production
- ✅ Deployed with proper backup and rollback plans
- ⚠️ Considered experimental until v2.0.0

### What pgtwin-migrate Does

Enables zero-downtime PostgreSQL migrations using logical replication:
- **Major version upgrades** (e.g., PostgreSQL 15 → 17)
- **Vendor migrations** (e.g., on-premise → cloud)
- **Hosting provider changes** (e.g., AWS → self-hosted)
- **Architecture changes** (e.g., physical → containerized)

### Key Features (v1.0.6)

- ✅ **Zero-downtime cutover** - VIP swap in seconds
- ✅ **Bidirectional DDL replication** - Schema changes replicate both ways
- ✅ **Self-healing reconciliation** - Automatically fixes missing components
- ✅ **Cluster-wide state management** - Works across node reboots and failovers
- ✅ **Idempotent operations** - Safe to run regardless of cluster state

### Documentation

- **README-pgtwin-migrate.md** - Complete usage guide
- **MIGRATION_DOCUMENTATION_INDEX.md** - Full migration workflow
- **PGTWIN_CONCEPTS.md** - Conceptual overview

### Migration Agent Changelog

**v1.0.6** (2026-01-02):
- Fixed cluster attribute scope (node-scoped → cluster-wide)
- Added automatic cleanup when migration completes
- Added stale state detection
- Enables long-running migrations (survives reboots)

**v1.0.5** (2026-01-02):
- Cutover window optimization (98% faster reverse DDL setup)
- Moved trigger creation to preparation phase

**v1.0.4** (2026-01-02):
- Bidirectional DDL replication
- Generic resource naming (not tied to PG17/PG18)

**v1.0.3** (2026-01-02):
- Completion detection improvements
- Resource instance scoping
- Auto-stop when complete

---

## pgtwin v1.6.18 Changes

### Critical Bugfixes (since v1.6.7)

**v1.6.18** - Synchronous Standby Names Bug Fix:
- **CRITICAL**: Fixed `synchronous_standby_names` handling in config files
- Bug: `update_application_name_in_config()` unconditionally wrote sync setting
- Fix: Only write sync setting when rep_mode=sync (lines 400-409)
- Impact: Prevents async clusters from being forced to sync mode

**v1.6.17** - Sync Replication Improvements:
- Enhanced `update_synchronous_standby_names()` with new parameters
- Better handling of single-node scenarios
- Improved logging for sync configuration changes

**v1.6.16** - VIP Colocation Fix:
- **CRITICAL**: Fixed VIP started on wrong node during failover
- Bug: VIP started on demoting node instead of promoting node
- Fix: Added colocation constraint check (lines 670-706)
- Impact: Ensures VIP always on promoted (primary) node

**v1.6.15** - XML Cluster Discovery Fix:
- **CRITICAL**: Fixed cluster node discovery during failover
- Bug: CIB XML parsing incorrectly identified standby as primary
- Fix: Enhanced XML parsing with proper Promoted role detection
- Impact: Prevents operations on read-only nodes

**v1.6.14** - Config Detection Enhancement:
- Fixed configuration value detection using `postgres -C`
- Enhanced double-failure safety check
- More robust config reading

**v1.6.13** - Parallel Cluster Discovery & Timeline Fix:
- **CRITICAL**: Fixed timeline check breaking parallel cluster discovery
- Fixed PROMOTED_NODE_DISCOVERY race condition
- Single-node sync safety check

**v1.6.12** - Timeline Warning:
- Non-blocking timeline divergence warning
- Early detection without blocking startup
- Two-tier discovery (Pacemaker CIB + direct query)

**v1.6.11** - Resource Cleanup:
- Automatic cleanup after pg_basebackup (98%+ speedup for small DBs)
- See v1.6.7 changelog for details (already released)

**v1.6.10** - Slot Creation:
- Replication slot created before pg_basebackup
- See v1.6.7 changelog for details (already released)

**v1.6.9** - Slot Management:
- Improved replication slot conflict handling
- Better error messages for slot-related failures

**v1.6.8** - Promotion Safety:
- Enhanced double-failure detection
- Single-node promotion guard

### Minor Improvements

- Enhanced logging throughout
- Better error messages for various failure scenarios
- Improved documentation in code comments

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

### From v1.6.7 to v1.7.0

**For pgtwin users:**

1. **Backup current configuration:**
   ```bash
   crm configure show > /tmp/cluster-config-backup.crm
   ```

2. **Deploy new pgtwin:**
   ```bash
   for node in node1 node2; do
       scp pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/
       ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin"
   done
   ```

3. **No cluster reconfiguration needed** - All changes backward compatible

4. **Verify after deployment:**
   ```bash
   crm status  # Check cluster health
   journalctl -u pacemaker -f  # Watch for issues
   ```

**For new pgtwin-migrate users:**

1. **Read complete documentation** - This is experimental software
2. **Test in non-production first** - Verify in dev/staging environment
3. **See README-pgtwin-migrate.md** - Complete setup guide
4. **See MIGRATION_DOCUMENTATION_INDEX.md** - Full migration workflow

---

## Breaking Changes

**None** - All changes are backward compatible

---

## Known Issues

### pgtwin

None known

### pgtwin-migrate (⚠️ Experimental)

- **New table DML delay**: When new table created on target, DML replication delayed until subscription refreshed (typically <2 minutes, no data loss)
- **Manual subscription refresh**: For immediate DML replication: `ALTER SUBSCRIPTION <name> REFRESH PUBLICATION;`
- **Future enhancement**: Automatic subscription refresh via LISTEN/NOTIFY (planned v1.1+)

---

## Testing Recommendations

### pgtwin Testing

**Recommended tests after upgrade:**

1. **Failover test:**
   ```bash
   crm resource move postgres-clone node2
   # Verify VIP moves correctly
   crm resource clear postgres-clone
   ```

2. **Standby recovery test:**
   ```bash
   crm node standby node1
   # Verify automatic recovery
   crm node online node1
   ```

3. **Monitor cluster:**
   ```bash
   watch -n 2 'crm status'
   ```

### pgtwin-migrate Testing

**MUST test in non-production first:**

1. Deploy two test clusters (source and target)
2. Run complete migration workflow
3. Test reverse replication
4. Test fallback scenarios
5. Validate application behavior

See **MIGRATION_DOCUMENTATION_INDEX.md** for complete testing guide.

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

---

## License

GPL-2.0-or-later

---

## Summary

**v1.7.0** is a significant release combining:
- 11 critical bugfixes in pgtwin (v1.6.8 through v1.6.18)
- New experimental pgtwin-migrate agent for zero-downtime migrations
- Enhanced stability and reliability
- Backward compatible - safe upgrade from v1.6.7

**Recommendation:**
- ✅ **pgtwin users**: Upgrade recommended for critical bugfixes
- ⚠️ **pgtwin-migrate**: Test thoroughly before production use

---

**Next Release:** v1.8.0 or v2.0.0 (pgtwin-migrate promoted to production-ready)
