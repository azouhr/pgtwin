# Changelog

All notable changes to pgtwin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.6] - 2025-12-09

### Fixed
- **CRITICAL**: Fixed pg_basebackup configuration finalization bug that created empty `primary_conninfo` values
  - Bug caused 100% replication failure after pg_basebackup recovery (affects v1.6.0-v1.6.5)
  - Root cause: Code attempted to read values from file after deleting it
  - Fix: Read values before deletion in `check_basebackup_progress()`
  - New unified `finalize_standby_config()` function ensures correct config (lines 1838-1912)
  - Prefers direct file update when PostgreSQL stopped, falls back to ALTER SYSTEM
  - Safety check in `pgsql_start()` detects and auto-fixes broken configurations
  - Used in all recovery paths: pg_rewind, pg_basebackup (async), manual recovery

### Added
- **Automatic Standby Initialization**: Zero-touch deployment from empty PGDATA
  - New `is_valid_pgdata()` function detects empty/missing/invalid PGDATA (lines 1483-1506)
  - Auto-init logic in `pgsql_start()` triggers pg_basebackup automatically (lines 1530-1590)
  - Updated `pgsql_validate()` to allow empty PGDATA (lines 2360-2375)
  - Prerequisites: Only `.pgpass` file with replication credentials required
  - Use cases: Fresh deployment, disk replacement, corrupted data recovery
  - Disk replacement simplified: 10+ steps → 3 steps
- **Pacemaker Notify Support**: Dynamic synchronous replication management
  - New `pgsql_notify()` action handler (lines 2393-2429)
  - `enable_sync_replication()` - enables sync when standby starts (lines 2383-2391)
  - `disable_sync_replication()` - disables sync when standby stops (lines 2373-2381)
  - Prevents write blocking when standby fails
  - Automatically switches between sync and async based on cluster state
  - Requires `notify="true"` in clone meta configuration
  - Handles post-start, post-stop, post-promote, pre-demote events

### Changed
- Updated version to 1.6.6 and release date to 2025-12-09
- Enhanced description includes automatic standby initialization and notify support
- Configuration finalization now unified across all recovery methods
- PGDATA validation more lenient to support auto-initialization

### Documentation
- **NEW**: `doc/BUGFIX_PG_BASEBACKUP_FINALIZATION.md` - Critical bug fix analysis
- **NEW**: `doc/FEATURE_AUTO_INITIALIZATION.md` - Complete auto-init guide
- **NEW**: `doc/FEATURE_NOTIFY_SUPPORT.md` - Complete notify support guide
- **UPDATED**: `MAINTENANCE_GUIDE.md` - Simplified disk replacement procedure
- **UPDATED**: `CHANGELOG.md` - This entry
- **NEW**: `RELEASE_v1.6.6.md` - Complete release notes

### Migration
- **CRITICAL**: Immediate upgrade recommended to fix configuration bug
- Fully backward compatible with v1.6.x
- No cluster configuration changes required
- Optional: Enable notify support by adding `notify="true"` to clone meta
- See RELEASE_v1.6.6.md for complete upgrade instructions

## [1.6.5] - 2025-11-10

### Added
- **Container Mode Support**: Seamless Podman/Docker container deployment (Phase 1)
  - New container library: `pgtwin-container-lib.sh`
  - Automatic container runtime detection (Podman primary, Docker fallback)
  - Transparent PostgreSQL command wrappers (pg_ctl, psql, pg_basebackup, etc.)
  - Container lifecycle management (start, stop, cleanup)
  - New OCF parameters: `container_mode`, `container_name`, `container_image`, `pg_major_version`
  - Container mode validation in `pgsql_validate()`
  - No code changes needed in main agent for container vs bare-metal operation

### Changed
- Added container mode support throughout all PostgreSQL operations
- Enhanced metadata with container-specific parameters
- Installation now includes container library deployment

### Documentation
- **NEW**: `CONTAINER_MODE_IMPLEMENTATION.md` - Container mode technical guide
- **NEW**: `RELEASE_v1.6.5_SUMMARY.md` - Container mode release summary
- **UPDATED**: Installation instructions include container library

## [1.6.4] - 2025-11-07

### Changed
- Prepared release package for GitHub distribution
- Updated documentation and version tracking
- All files synchronized with latest v1.6.3 codebase

### Status
- Stable release ready for production deployment
- Includes all fixes from v1.6.1, v1.6.2, and v1.6.3
- No functional changes from v1.6.3

## [1.6.3] - 2025-11-05

### Fixed
- **CRITICAL**: Fixed cluster node name handling - resource agent now correctly uses Pacemaker cluster node name instead of system hostname
  - Added `get_cluster_node_name()` helper function using `crm_node -n`
  - Fixed 6 locations using `hostname -s` for `crm_attribute` calls
  - Prevents UUID mapping errors when cluster node names differ from hostnames
  - Critical for VM/cloud environments with generic hostnames
- **QUICKSTART.md**: Fixed PostgreSQL startup sequence - PostgreSQL must be running before creating replication user
- **QUICKSTART.md**: Added replication slot creation step before `pg_basebackup`
- **QUICKSTART.md**: Simplified ocf-tester verification instructions

### Changed
- All `crm_attribute` operations now use cluster node name from `crm_node -n`
- Node list comparisons use cluster node name for accuracy

### Impact
- Fixes crm_attribute failures in environments where cluster node name ≠ hostname
- Backward compatible - falls back to `hostname -s` if `crm_node` unavailable
- No configuration changes required for existing clusters

## [1.6.2] - 2025-11-03

### Documentation
- **README.md**: Added "Expected Timing" section with detailed performance metrics
  - Automatic failover: 30-60 seconds breakdown
  - Manual failover: 15-30 seconds
  - Node recovery timing (pg_rewind vs pg_basebackup)
  - Replication lag expectations (sync/async modes)
- **QUICKSTART.md**: Integrated complete inline Production Checklist
  - PostgreSQL configuration checklist
  - Replication configuration checklist
  - Cluster configuration checklist
  - Testing verification checklist
  - Monitoring setup checklist
- **PROJECT_SUMMARY.md**: Cleaned up parent repository references

### Changed
- All documentation now self-contained within pgtwin repository
- Focus on operational timing metrics instead of synthetic benchmarks
- No code changes - documentation-only release

## [1.6.1] - 2025-11-03

### Fixed
- **CRITICAL**: Fixed replication failure counter not incrementing (removed `ocf_run` wrapper from GET operations)
- **CRITICAL**: Added missing `passfile` parameter to `primary_conninfo` in 3 locations
  - `pgsql_demote()` function
  - `recover_standby()` after pg_rewind
  - `check_basebackup_progress()` after pg_basebackup
- **CRITICAL**: Fixed CIB parsing returning "*" instead of hostname (improved `crm_mon` parsing)
- **CRITICAL**: Added missing `PGPASSFILE` environment variable for pg_rewind and pg_basebackup
- **CRITICAL**: Fixed `pg_basebackup` exit code handling (accepts exit code 1 as success with warnings)
- **CRITICAL**: Prevented replication slot recreation when slot already exists

### Impact
- Automatic recovery feature from v1.6.0 now fully functional
- Replication reconnection after demote now works correctly
- pg_rewind and pg_basebackup authentication fixed
- All 6 critical bugs preventing v1.6.0 from working are resolved

## [1.6.0] - 2025-11-03

### Added
- **Automatic Replication Recovery**: Monitor function now detects replication failures and automatically triggers recovery
  - Tracks replication health on standby nodes
  - Incremental failure counter with configurable threshold (`replication_failure_threshold` parameter, default: 5)
  - Automatically triggers `pg_rewind`/`pg_basebackup` when threshold exceeded
- **Dynamic Promoted Node Discovery**: New `discover_promoted_node()` function finds current primary using multiple methods:
  - Method 1: Query VIP directly (fastest, most reliable)
  - Method 2: Scan all nodes in `node_list`
  - Method 3: Parse Pacemaker CIB (fallback)
- **Enhanced Monitor Function**: Standby nodes now actively monitor WAL receiver status
- **Enhanced Demote Function**: Uses dynamic discovery to find promoted node for replication setup
- **New Parameters**:
  - `vip`: Virtual IP address for promoted node discovery (optional but recommended)
  - `replication_failure_threshold`: Number of monitor cycles before triggering automatic recovery (default: 5)

### Known Issues
- Replication failure counter may not increment correctly in some scenarios (FIXED in v1.6.1)
- Missing `passfile` parameter in `primary_conninfo` when using `.pgpass` authentication (FIXED in v1.6.1)

### Technical Details
- All v1.6 features are backwards compatible - clusters can upgrade without configuration changes
- Dynamic discovery significantly improves demote reliability in complex failure scenarios
- Automatic recovery reduces manual intervention for timeline divergence issues

## [1.5.0] - 2025-11-02

### Added
- **Enhanced Configuration Validation**: 6 new PostgreSQL configuration checks on startup
  - **CRITICAL**: `restart_after_crash` must be `off` (prevents split-brain)
  - **WARNING**: `wal_sender_timeout` < 10s (prevents false disconnections)
  - **WARNING**: `max_standby_streaming_delay` = -1 (prevents unbounded lag)
  - **WARNING**: `archive_command` error handling validation
  - **NOTICE**: `listen_addresses` security review
- **Runtime Archive Monitoring**: Continuous monitoring for archive failures on primary
  - Detects accumulating archive failures during monitor operations
  - Logs warnings with failure counts and timestamps
  - Prevents silent archive failures that could block writes
- **Comprehensive PostgreSQL Configuration Guide**: New `README.postgres.md` with:
  - Complete configuration reference
  - "Getting Started with HA PostgreSQL" tutorial
  - Critical and dangerous configuration options explained
  - Performance tuning and security considerations
  - Troubleshooting guide

### Changed
- Configuration validation now blocks startup on CRITICAL errors
- Archive failure monitoring runs on every primary monitor cycle (interval: 3s)

## [1.4.0] - 2025-11-01

### Fixed
- **CRITICAL**: Fixed promotion failure - `pg_ctl promote` now handles `standby.signal` removal automatically
  - Removed manual `rm -f standby.signal` which caused permission errors
  - PostgreSQL properly manages `standby.signal` during promotion
- **CRITICAL**: Added dual location constraints for proper failover migration
  - Both nodes now have `role=Promoted` score assignments
  - Enables bidirectional failover (psql1 ↔ psql2)

### Added
- **Automatic application_name Management**: Resource agent updates `application_name` in `postgresql.auto.conf`
  - On start: Updates to configured value or sanitized hostname
  - On promote: Ensures consistency between primary and standby
  - Eliminates manual synchronous_standby_names mismatches
- **STONITH/SBD Configuration**: Cluster now includes proper fencing
  - `stonith-enabled=true` with SBD device
  - `have-watchdog=true` for split-brain protection
  - `priority-fencing-delay=60s` for safer fencing

### Changed
- Promotion process now relies entirely on `pg_ctl promote` for file management
- Location constraints now explicitly include `role=Promoted` qualifier
- Default cluster configuration includes STONITH device

## [1.3.0] - 2025-10-31

### Added
- **Configuration Validation Framework**: 8 comprehensive checks run on every PostgreSQL start
  - PostgreSQL version compatibility check (17.x)
  - Critical replication settings validation (`wal_level`, `max_wal_senders`, `hot_standby`)
  - Archive mode configuration check
  - Listen addresses validation
  - Replication user existence verification
  - Replication slot configuration check
  - VIP parameter validation
  - Synchronous replication mode verification
- Early startup blocking for critical misconfigurations
- Detailed error messages for each validation failure
- Prevents cluster startup with unsafe configurations

## [1.2.0] - 2025-10-30

### Changed
- **Disk Space Calculation Refactoring**: Switched from logical database size to actual filesystem usage
  - Now uses `du -sb $PGDATA` for accurate total space requirements
  - Includes all data files, WAL, logs, temp files, and metadata
  - Backup mode: `(actual_usage × 2) + 10% safety margin`
  - No-backup mode: `(actual_usage × 1) + 10% safety margin`
- More accurate disk space safety margin calculations
- Improved error messages showing required vs available space

### Removed
- `pg_database_size()` based disk calculations (too narrow, missed critical space usage)

## [1.1.0] - 2025-10-29

### Added
- **Application Name Validation**: Enforces `[a-zA-Z0-9_]` character set
  - Automatic sanitization (hyphens → underscores) when using hostname fallback
  - Validation prevents PostgreSQL replication parsing issues
- **Disk Space Pre-Check**: Validates sufficient space before `pg_basebackup`
  - Checks available space on PGDATA filesystem
  - Accounts for backup mode (2× space) vs no-backup mode (1× space)
  - Prevents failed basebackups due to insufficient space
- **Backup Mode Semantics**: Clear distinction between backup and no-backup modes
  - `backup_before_basebackup=true`: Moves data to `.backup.<timestamp>` (recoverable)
  - `backup_before_basebackup=false`: Immediate permanent deletion (50% space savings)
- **Asynchronous pg_basebackup**: Long-running basebackups execute in background
  - Prevents Pacemaker monitor timeouts
  - Progress tracking in `${PGDATA}/.basebackup.log`
  - State file: `${PGDATA}/.basebackup_in_progress`
  - Configurable timeout via `basebackup_timeout` parameter (default: 3600s)
- **Enhanced .pgpass Support**: Automatic credential extraction
  - Parses `pgpassfile` parameter for replication credentials
  - Extracts host, port, user, password for `pg_basebackup` and `pg_rewind`
  - Fallback logic for credential discovery

### Parameters Added
- `basebackup_timeout` (default: 3600s): Maximum time for basebackup operation
- `pgpassfile` (optional): Path to .pgpass file for credential management
- `backup_before_basebackup` (default: false): Enable/disable backup mode

## [1.0.0] - 2025-10-28

### Initial Release
- PostgreSQL 17 High Availability support
- Physical streaming replication with replication slots
- Automatic failover with Pacemaker
- Virtual IP (VIP) management
- `pg_rewind` support for timeline reconciliation
- Synchronous and asynchronous replication modes
- Basic configuration validation
- WAL archiving support
- Comprehensive logging and error handling

[1.6.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.6.0
[1.5.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.5.0
[1.4.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.4.0
[1.3.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.3.0
[1.2.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.2.0
[1.1.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.1.0
[1.0.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.0.0
