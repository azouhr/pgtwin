# Release Notes: pgtwin v1.6.2

**Release Date**: 2025-11-03
**Type**: Documentation Update
**Status**: Documentation improvements and self-containment

## Overview

Version 1.6.2 is a documentation-only release that makes the pgtwin repository completely self-contained and ready for GitHub publication. No code changes were made to the OCF resource agent.

## Changes

### Documentation Self-Containment

All documentation has been updated to be self-contained within the pgtwin repository:

1. **README.md**
   - Removed references to parent repository test suite
   - Added "Expected Timing" section with detailed performance metrics:
     - Automatic failover: 30-60 seconds (with breakdown)
     - Manual failover: 15-30 seconds
     - Node recovery timing for pg_rewind and pg_basebackup
     - Replication lag expectations for sync and async modes
   - Updated Testing section to focus on local capabilities

2. **QUICKSTART.md**
   - Removed reference to external PRODUCTION_CHECKLIST.md
   - Added complete inline Production Checklist with 5 categories:
     - PostgreSQL Configuration checklist
     - Replication Configuration checklist
     - Cluster Configuration checklist
     - Testing verification checklist
     - Monitoring setup checklist

3. **PROJECT_SUMMARY.md**
   - Removed specific directory path references
   - Updated "Parent Repository Updates" to "Development History"
   - Cleaned up Acknowledgments section
   - Changed testing references to be generic

### Performance Metrics Clarification

Instead of benchmark throughput numbers (TPS), the documentation now focuses on **operational timing metrics** that are relevant for HA deployments:

- **Failover timing**: How long does it take to switch from failed primary to standby?
- **Recovery timing**: How long does pg_rewind vs pg_basebackup take?
- **Replication lag**: What latency to expect in normal operation?

These metrics are more valuable for capacity planning and SLA definitions than synthetic benchmark numbers.

## What's NOT Changed

- ✅ No OCF resource agent code changes
- ✅ No configuration parameter changes
- ✅ No functional changes
- ✅ Fully backward compatible with v1.6.1

## Upgrade Instructions

### From v1.6.1 to v1.6.2

**No upgrade needed** - this is a documentation-only release. If you have v1.6.1 deployed, it continues to work without any changes.

If you want the updated documentation locally:

```bash
# Download from GitHub
git clone https://github.com/azouhr/pgtwin.git
cd pgtwin
git checkout v1.6.2

# Review updated docs
cat README.md
cat QUICKSTART.md
```

**No cluster restart required** - documentation changes don't affect running clusters.

## Documentation Improvements Summary

### Before v1.6.2
- Referenced external files in parent repository
- Mixed benchmark throughput with operational metrics
- Production checklist in separate file

### After v1.6.2
- All documentation self-contained
- Focus on operational timing metrics (failover, recovery)
- Production checklist integrated into QUICKSTART.md
- Clear performance expectations for all HA operations

## Files Modified

| File | Change Type | Description |
|------|-------------|-------------|
| README.md | Enhanced | Added "Expected Timing" section, removed parent references |
| QUICKSTART.md | Enhanced | Integrated production checklist |
| PROJECT_SUMMARY.md | Updated | Removed parent repository references |
| VERSION | Updated | Changed from 1.6.1 to 1.6.2 |
| pgtwin (header) | Updated | Version number in script header |

## Verification

```bash
# Verify version
cat VERSION
# Output: 1.6.2

head -5 pgtwin | grep Version
# Output: # Version: 1.6.2

# Check documentation is self-contained
grep -r "parent directory\|parent repository" *.md | grep -v CHANGELOG | grep -v RELEASE
# Output: (empty - no references found)
```

## Why This Release?

This release was created to prepare pgtwin for GitHub publication. Key goals:

1. **Self-Containment**: Repository should be usable without external dependencies
2. **Clarity**: Performance metrics should focus on operational concerns (failover timing)
3. **Completeness**: Production checklist integrated directly into setup guide

## Migration Notes

### For Existing v1.6.1 Deployments

**No action required**. This release contains no functional changes.

### For New Deployments

Follow the updated QUICKSTART.md which now includes:
- Inline production checklist
- Clear timing expectations
- Complete self-contained setup guide

## Known Limitations (Unchanged from v1.6.1)

The following limitations from v1.6.1 remain:

1. **pg_basebackup Completion**: May exit with code 1 in some edge cases
2. **Replication Slot Recreation**: May need manual recreation after complex recoveries
3. **Manual Intervention**: Some edge cases may require DBA intervention

These will be addressed in future releases (v1.7.0+).

## Next Release (v1.7.0)

Planned improvements for v1.7.0:

1. Enhanced recovery completion handling
2. Automatic replication slot recreation
3. Improved edge case handling
4. Additional PostgreSQL version support (15, 16)

## Documentation

- [README.md](README.md) - Overview, architecture, design decisions
- [QUICKSTART.md](QUICKSTART.md) - Complete setup guide with production checklist
- [CHEATSHEET.md](CHEATSHEET.md) - Administration command reference
- [CHANGELOG.md](CHANGELOG.md) - Complete version history
- [RELEASE_v1.6.1.md](RELEASE_v1.6.1.md) - Previous release notes

## Support

- **Issues**: https://github.com/azouhr/pgtwin/issues
- **Documentation**: README.md, QUICKSTART.md, CHEATSHEET.md
- **License**: GPL-2.0-or-later

---

**Version Comparison**:

- v1.6.1: Critical bug fixes for automatic recovery (6 bugs fixed)
- **v1.6.2**: Documentation improvements and self-containment (current release)
- v1.7.0: Planned enhancements for recovery completion

**Recommended Version**: v1.6.2 for new deployments (documentation improvements)

---

## Changelog Summary

```
v1.6.2 (2025-11-03)
-------------------
[DOCS] README.md: Added "Expected Timing" section with failover/recovery metrics
[DOCS] README.md: Removed parent repository test suite references
[DOCS] QUICKSTART.md: Integrated inline production checklist
[DOCS] PROJECT_SUMMARY.md: Removed parent repository references
[UPDATED] VERSION: 1.6.1 → 1.6.2
[UPDATED] pgtwin header: Version number updated

v1.6.1 (2025-11-03)
-------------------
[FIXED] Replication failure counter not incrementing (removed ocf_run from GET)
[FIXED] Missing passfile parameter in primary_conninfo (3 locations)
[FIXED] CIB parsing returning "*" instead of hostname
[FIXED] Missing PGPASSFILE environment variable (pg_rewind, pg_basebackup)
[FIXED] pg_basebackup using diverged replication slot
[FIXED] Incomplete marker file cleanup on basebackup completion
```

---

**Release Type**: Documentation Only
**Backward Compatible**: Yes
**Upgrade Required**: No
**GitHub Ready**: Yes ✅
