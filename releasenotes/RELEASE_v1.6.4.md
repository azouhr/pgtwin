# Release Notes: pgtwin v1.6.4

**Release Date**: 2025-11-07
**Type**: Packaging Release
**Status**: Stable - Ready for Production

## Overview

Version 1.6.4 is a packaging and distribution release that prepares pgtwin for GitHub publication. This release contains no functional changes from v1.6.3 - it consolidates all improvements from the v1.6.x series into a clean, well-documented package ready for production deployment.

## What's Included

This release includes **all features and fixes** from the v1.6.x series:

### From v1.6.3 - Cluster Node Name Handling
- ✅ Fixed critical cluster node name handling (VM/cloud compatibility)
- ✅ Correct use of Pacemaker cluster node names vs system hostnames
- ✅ Helper function `get_cluster_node_name()` using `crm_node -n`

### From v1.6.2 - Documentation Enhancements
- ✅ Complete production checklist integrated into QUICKSTART
- ✅ Performance timing metrics for HA operations
- ✅ Self-contained documentation

### From v1.6.1 - Critical Bug Fixes
- ✅ Fixed replication failure counter (automatic recovery now works)
- ✅ Fixed authentication with `.pgpass` files
- ✅ Fixed promoted node discovery
- ✅ Fixed pg_rewind and pg_basebackup operations

### From v1.6.0 - Automatic Recovery
- ✅ Automatic replication failure detection and recovery
- ✅ Dynamic promoted node discovery (VIP, node scan, CIB)
- ✅ Configurable failure threshold monitoring

## Release Contents

### Core Files
- `pgtwin` - OCF Resource Agent (v1.6.4)
- `VERSION` - Version identifier
- `LICENSE` - GPL-2.0-or-later

### Configuration
- `pgsql-resource-config.crm` - Sample Pacemaker cluster configuration
- `pgtwin.spec` - RPM package specification

### Documentation
- `README.md` - Complete project documentation
- `QUICKSTART.md` - Quick start guide with production checklist
- `CHANGELOG.md` - Detailed changelog (v1.0.0 → v1.6.4)
- `MANUAL_RECOVERY_GUIDE.md` - Recovery procedures
- `BUILD.md` - Build and packaging instructions
- `CHEATSHEET.md` - Command reference
- `PROJECT_SUMMARY.md` - Project overview

### Release Notes
- `RELEASE_v1.6.1.md` - Critical bug fixes (6 bugs)
- `RELEASE_v1.6.2.md` - Documentation improvements
- `RELEASE_v1.6.3.md` - Cluster node name handling
- `RELEASE_v1.6.4.md` - This file

### Build System
- `Makefile` - Build automation

## Installation

### Quick Install

```bash
# Download the release
wget https://github.com/azouhr/pgtwin/archive/refs/tags/v1.6.4.tar.gz
tar xzf v1.6.4.tar.gz
cd pgtwin-1.6.4

# Install on both cluster nodes
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify installation
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data | grep version
# Expected: <version>1.6.4</version>
```

### Using RPM (if available)

```bash
# Build RPM
make rpm

# Install on both nodes
sudo zypper install pgtwin-1.6.4-1.noarch.rpm
```

## Upgrade Instructions

### From v1.6.3 to v1.6.4

**No functional changes** - this is a packaging release only.

```bash
# Optional upgrade (recommended for version consistency)
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# No cluster restart needed
```

### From v1.6.0-v1.6.2 to v1.6.4

**Upgrade recommended** - includes critical bug fixes.

```bash
# On both nodes
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Cleanup and restart
sudo crm resource cleanup postgres-clone
```

### From v1.5.x or Earlier to v1.6.4

**Major upgrade** - new features and parameters available.

```bash
# Install new agent
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Optional: Add new parameters
sudo crm configure edit

# Add these optional parameters:
# - vip: Virtual IP address
# - replication_failure_threshold: Default 5

# Cleanup
sudo crm resource cleanup postgres-clone
```

## Verification

```bash
# Check version
head -5 /usr/lib/ocf/resource.d/heartbeat/pgtwin | grep Version
# Expected: # Version: 1.6.4

# Verify metadata
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data | head -20

# Check cluster status
sudo crm status

# Verify replication (on standby)
sudo -u postgres psql -c "SELECT status FROM pg_stat_wal_receiver;"
```

## What's NOT Changed

- ✅ No configuration changes required
- ✅ No parameter changes
- ✅ Fully backward compatible with v1.6.x
- ✅ No cluster downtime needed
- ✅ Same system requirements

## System Requirements

### PostgreSQL
- **Version**: 17.x (tested with 17.6)
- **Configuration**: See QUICKSTART.md for required settings

### Cluster Software
- **Pacemaker**: 3.0.1+
- **Corosync**: 3.x
- **Resource Agents**: heartbeat provider

### Operating System
- openSUSE Tumbleweed (tested)
- openSUSE Leap 15.6+
- SUSE Linux Enterprise 15 SP6+
- Other RPM-based distributions (may require adaptation)

## Features Summary

### Automatic High Availability
- Automatic failover on primary failure
- Automatic node recovery with pg_rewind
- Automatic replication failure detection
- Configurable recovery thresholds

### Replication Management
- Physical streaming replication
- Replication slot management with size limits
- Synchronous and asynchronous modes
- Dynamic promoted node discovery

### Recovery Capabilities
- pg_rewind for timeline reconciliation
- pg_basebackup fallback for full resync
- Configurable backup modes
- Asynchronous basebackup with timeouts

### Configuration Safety
- Comprehensive configuration validation (v1.3+)
- Runtime archive monitoring (v1.5+)
- Critical parameter checks on startup
- Clear error messages and warnings

## Getting Started

1. **Read Documentation**
   - Start with `README.md` for overview
   - Follow `QUICKSTART.md` for setup
   - Review production checklist

2. **Configure PostgreSQL**
   - Set required parameters
   - Create replication user
   - Configure authentication

3. **Deploy Cluster**
   - Install pgtwin on both nodes
   - Configure Pacemaker
   - Test failover scenarios

4. **Production Readiness**
   - Complete production checklist
   - Configure monitoring
   - Document recovery procedures

## Support and Documentation

- **GitHub**: https://github.com/azouhr/pgtwin
- **Issues**: https://github.com/azouhr/pgtwin/issues
- **Documentation**: See docs/ directory in release
- **License**: GPL-2.0-or-later

## Changelog Highlights (v1.6.x Series)

```
v1.6.4 (2025-11-07) - Packaging release
v1.6.3 (2025-11-05) - Cluster node name handling
v1.6.2 (2025-11-03) - Documentation enhancements
v1.6.1 (2025-11-03) - 6 critical bug fixes
v1.6.0 (2025-11-03) - Automatic recovery feature
```

See `CHANGELOG.md` for complete history.

## Production Readiness

**Status**: ✅ **PRODUCTION READY**

This release has been tested in:
- ✅ Development environments
- ✅ QA testing with failover scenarios
- ✅ Live cluster deployments
- ✅ VM/cloud environments

Recommended for:
- ✅ New production deployments
- ✅ Upgrades from v1.5.x and earlier
- ✅ VM and cloud environments
- ✅ Enterprise PostgreSQL HA clusters

## Next Release

**v1.7.0** (Planned) will include:
- Timeline divergence auto-recovery enhancements
- Improved pg_rewind permissions handling
- Additional PostgreSQL version support (15, 16)
- Enhanced configuration management

See `RELEASE_v1.7.0_TASKS.md` for development roadmap.

---

**Release Type**: Packaging & Distribution
**Backward Compatible**: Yes (with all v1.6.x)
**Configuration Changes**: None required
**Recommended Upgrade**: Optional (from v1.6.3), Recommended (from v1.6.2 or earlier)

**SHA256 Checksums**: See release assets

---

Released by: pgtwin development team
Date: 2025-11-07
Version: 1.6.4
License: GPL-2.0-or-later
