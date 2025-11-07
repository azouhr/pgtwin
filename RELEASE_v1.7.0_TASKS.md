# Release v1.7.0 - Planned Tasks and Improvements

**Target Release Date**: TBD
**Type**: Feature Release + Bug Fixes
**Status**: Planning

---

## Critical Issues from v1.6.3 Field Testing

### Issue #1: pg_rewind PGPASSFILE Environment Variable Not Working

**Problem**:
- `runuser` command doesn't properly pass environment variables to pg_rewind
- Current code (line 1240):
  ```bash
  runuser -u ${OCF_RESKEY_pguser} -- sh -c "${env_vars} ${PG_REWIND} ..."
  ```
- PGPASSFILE not being set in the subshell context

**Impact**:
- pg_rewind fails with authentication errors
- Falls back to pg_basebackup (slower but works)
- Users report pg_basebackup works fine with same credentials

**Proposed Fix**:
```bash
# Option 1: Use -w flag with password in connection string (if supported)
runuser -u ${OCF_RESKEY_pguser} -- sh -c "PGPASSFILE='${OCF_RESKEY_pgpassfile}' ${PG_REWIND} ..."

# Option 2: Create temporary .pgpass in postgres home
# Option 3: Use --no-ensure-shutdown and libpq environment variables differently
```

**Testing Required**:
- Test with PGPASSFILE set via runuser
- Test with password in connection string
- Verify both authentication and authorization work

**Files to Modify**:
- `pgtwin` (line 1234-1241)
- Test suite

**Priority**: HIGH
**Complexity**: Medium

---

### Issue #2: pg_hba.conf Validation for pg_rewind Requirements

**Problem**:
- pg_rewind requires **TWO types of access**:
  1. `host replication replicator <network> scram-sha-256` - for replication protocol
  2. `host postgres replicator <network> scram-sha-256` - for SQL queries
- Current code doesn't validate pg_hba.conf has both entries
- Users only configure replication access, causing pg_rewind to fail silently

**Impact**:
- pg_rewind fails with "no pg_hba.conf entry" errors
- No warning during cluster setup
- Recovery always falls back to slow pg_basebackup

**Proposed Fix**:
Add validation during startup (in `check_postgresql_config()` function):

```bash
# New validation check (around line 730)
validate_pghba_for_rewind() {
    local standby_nodes="${OCF_RESKEY_node_list}"

    # Only check on promoted (primary) node
    if ! pgsql_is_promoted; then
        return 0
    fi

    ocf_log info "Validating pg_hba.conf for pg_rewind support"

    # Check if replication user can access postgres database
    local has_postgres_access=$(sudo -u ${OCF_RESKEY_pguser} psql -Atc "
        SELECT COUNT(*) FROM pg_hba_file_rules
        WHERE database @> '{postgres}'
        AND user_name @> '{${rep_user}}'
        AND type = 'host'
    ")

    local has_replication_access=$(sudo -u ${OCF_RESKEY_pguser} psql -Atc "
        SELECT COUNT(*) FROM pg_hba_file_rules
        WHERE database @> '{replication}'
        AND user_name @> '{${rep_user}}'
        AND type = 'host'
    ")

    if [ "$has_postgres_access" = "0" ]; then
        ocf_log warn "CONFIGURATION WARNING: pg_hba.conf missing entry for pg_rewind"
        ocf_log warn "pg_rewind requires: host postgres ${rep_user} <standby_network> scram-sha-256"
        ocf_log warn "Without this, recovery will always use slower pg_basebackup"
        ocf_log warn "Add to pg_hba.conf: host postgres replicator <network> scram-sha-256"
    else
        ocf_log info "✓ pg_hba.conf allows pg_rewind access (postgres database)"
    fi

    if [ "$has_replication_access" = "0" ]; then
        ocf_log err "CRITICAL: pg_hba.conf missing replication access"
        ocf_log err "Required: host replication ${rep_user} <standby_network> scram-sha-256"
        return $OCF_ERR_CONFIGURED
    else
        ocf_log info "✓ pg_hba.conf allows replication access"
    fi

    return 0
}
```

**Additional Feature**: Add `--pghba-check` to help administrators validate:
```bash
# Manual validation command
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin validate-pghba

# Output:
# ✓ Replication access configured
# ✗ pg_rewind access missing
#
# To fix, add to pg_hba.conf on PRIMARY:
# host    postgres        replicator      192.168.122.0/24        scram-sha-256
```

**Files to Modify**:
- `pgtwin` (new function around line 730)
- `check_postgresql_config()` - add call to new function
- `MANUAL_RECOVERY_GUIDE.md` - document the requirement
- `github/QUICKSTART.md` - update pg_hba.conf examples

**Priority**: HIGH
**Complexity**: Medium

---

### Issue #3: Post-Promotion Connectivity Test

**Problem**:
- After failover/promotion, there's no verification that standby can reach the new primary
- Network issues or hostname resolution problems only discovered during next failover
- No proactive monitoring of "can standby connect to primary?"

**Impact**:
- Recovery fails unexpectedly when roles switch
- Silent failures until next failover attempt
- No early warning of network/DNS issues

**Proposed Fix**:
Add connectivity test in `pgsql_promote()` function after promotion completes:

```bash
# In pgsql_promote() function (after line 1120)
test_standby_connectivity() {
    local primary_host=$(hostname -s)

    ocf_log info "Testing connectivity for standby nodes after promotion"

    # Get list of other nodes
    for node in ${OCF_RESKEY_node_list}; do
        if [ "$node" != "$(get_cluster_node_name)" ]; then
            ocf_log debug "Testing if standby ${node} can reach new primary ${primary_host}"

            # Try to connect from this node's perspective
            # This is tricky - we're on the primary, testing if remote node can reach us

            # Method 1: Check if PostgreSQL is listening on network interface
            local listen_addrs=$(sudo -u ${OCF_RESKEY_pguser} psql -Atc "SHOW listen_addresses")
            if [ "$listen_addrs" = "localhost" ]; then
                ocf_log warn "WARNING: listen_addresses='localhost' - standby cannot connect"
                ocf_log warn "Set listen_addresses='*' or include cluster network IP"
            fi

            # Method 2: Check pg_hba.conf allows connections from standby
            local standby_allowed=$(sudo -u ${OCF_RESKEY_pguser} psql -Atc "
                SELECT COUNT(*) FROM pg_hba_file_rules
                WHERE database @> '{replication}'
                AND user_name @> '{replicator}'
                AND type IN ('host', 'hostssl')
            ")

            if [ "$standby_allowed" = "0" ]; then
                ocf_log warn "WARNING: pg_hba.conf may not allow standby ${node} to connect"
            fi
        fi
    done

    return 0
}
```

**Better Approach**: Add to monitor function on STANDBY:
```bash
# In pgsql_monitor() on unpromoted (standby) node
# Test if we can reach the primary (around line 937)

if ! pgsql_is_promoted; then
    # This is standby - verify we can reach primary
    local primary_host=$(grep "^host=" "${PGDATA}/postgresql.auto.conf" | cut -d= -f2 | cut -d' ' -f1)

    if [ -n "$primary_host" ]; then
        # Quick connectivity test (every 5th monitor cycle to avoid overhead)
        local cycle_count=$(crm_attribute -N $(get_cluster_node_name) -n pgtwin-monitor-cycle -G -q -d 0 2>/dev/null)
        cycle_count=$((cycle_count + 1))
        crm_attribute -N $(get_cluster_node_name) -n pgtwin-monitor-cycle -v $cycle_count 2>/dev/null

        if [ $((cycle_count % 5)) -eq 0 ]; then
            ocf_log debug "Testing connectivity to primary ${primary_host}"

            # Test if we can connect
            timeout 5 bash -c "</dev/tcp/${primary_host}/${OCF_RESKEY_pgport}" 2>/dev/null
            if [ $? -ne 0 ]; then
                ocf_log warn "WARNING: Cannot connect to primary ${primary_host}:${OCF_RESKEY_pgport}"
                ocf_log warn "Check: 1) Network connectivity 2) Firewall 3) PostgreSQL listen_addresses"
            fi
        fi
    fi
fi
```

**Files to Modify**:
- `pgtwin` - `pgsql_monitor()` function (line 937+)
- `pgtwin` - `pgsql_promote()` function (line 1120+)
- Test suite

**Priority**: MEDIUM
**Complexity**: Medium

---

## Additional Improvements for v1.7.0

### Enhancement #4: Better PGPASSFILE Handling

**Issue**: Environment variables with `runuser` are problematic

**Options**:
1. Always use `.pgpass` in postgres user's home directory
2. Copy `${OCF_RESKEY_pgpassfile}` to `/var/lib/pgsql/.pgpass` during start
3. Use connection string with password (less secure)

**Proposed**:
```bash
# Ensure .pgpass exists in correct location
ensure_pgpass() {
    local target_pgpass="/var/lib/pgsql/.pgpass"

    if [ -n "${OCF_RESKEY_pgpassfile}" ] && [ -f "${OCF_RESKEY_pgpassfile}" ]; then
        if [ "${OCF_RESKEY_pgpassfile}" != "${target_pgpass}" ]; then
            ocf_log info "Copying pgpassfile to ${target_pgpass}"
            cp "${OCF_RESKEY_pgpassfile}" "${target_pgpass}"
            chown ${OCF_RESKEY_pguser}:$(id -gn ${OCF_RESKEY_pguser}) "${target_pgpass}"
            chmod 600 "${target_pgpass}"
        fi
    fi
}
```

**Priority**: MEDIUM

---

### Enhancement #5: Improved Recovery Logging

**Issue**: Hard to diagnose why recovery fails

**Proposed**:
- Log pg_rewind output to separate file
- Log pg_basebackup output with more detail
- Add recovery attempt counter
- Save last recovery attempt details for post-mortem

```bash
# Recovery log directory
RECOVERY_LOG_DIR="${PGDATA}/recovery_logs"
mkdir -p "${RECOVERY_LOG_DIR}"

# Log format: recovery-YYYYMMDD-HHMMSS-attempt-N.log
LOG_FILE="${RECOVERY_LOG_DIR}/recovery-$(date +%Y%m%d-%H%M%S)-attempt-${attempt_num}.log"
```

**Priority**: LOW

---

### Enhancement #6: Recovery Pre-Check

**Issue**: Recovery starts without verifying prerequisites

**Proposed**: Add pre-flight checks before attempting recovery:
```bash
pre_recovery_check() {
    ocf_log info "Running pre-recovery checks"

    # 1. Check disk space
    check_disk_space_for_basebackup "$primary_host" || return 1

    # 2. Verify primary is reachable
    timeout 5 bash -c "</dev/tcp/${primary_host}/${OCF_RESKEY_pgport}" || {
        ocf_log err "Cannot reach primary ${primary_host}:${OCF_RESKEY_pgport}"
        return 1
    }

    # 3. Verify authentication works
    PGPASSFILE="${target_pgpass}" psql -h "$primary_host" -U "$rep_user" -d postgres -c "SELECT 1" >/dev/null 2>&1 || {
        ocf_log err "Authentication to primary failed"
        return 1
    }

    # 4. Check if replication slot exists
    local slot_exists=$(PGPASSFILE="${target_pgpass}" psql -h "$primary_host" -U "$rep_user" -d postgres -Atc "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name='${OCF_RESKEY_slot_name}'")
    if [ "$slot_exists" = "0" ]; then
        ocf_log warn "Replication slot '${OCF_RESKEY_slot_name}' does not exist on primary"
        ocf_log warn "pg_basebackup will run without -S option"
    fi

    ocf_log info "Pre-recovery checks passed"
    return 0
}
```

**Priority**: MEDIUM

---

### Enhancement #7: Automatic pg_hba.conf Fix (Optional)

**Issue**: Users struggle with pg_hba.conf configuration

**Proposed**: Add helper command to fix pg_hba.conf automatically:
```bash
# New operation mode
pgsql_fix_pghba() {
    # Only on promoted node
    if ! pgsql_is_promoted; then
        ocf_log err "Can only fix pg_hba.conf on promoted (primary) node"
        return $OCF_ERR_GENERIC
    fi

    local pghba="${PGDATA}/pg_hba.conf"
    local backup="${pghba}.backup.$(date +%s)"

    ocf_log info "Backing up pg_hba.conf to ${backup}"
    cp "$pghba" "$backup"

    # Check if entries exist
    if ! grep -q "host.*postgres.*replicator" "$pghba"; then
        ocf_log info "Adding pg_rewind access to pg_hba.conf"
        # Add after first comment block
        sed -i '/^# TYPE.*DATABASE.*USER/a\
# pg_rewind access\
host    postgres        replicator      192.168.122.0/24        scram-sha-256' "$pghba"
    fi

    if ! grep -q "host.*replication.*replicator" "$pghba"; then
        ocf_log info "Adding replication access to pg_hba.conf"
        sed -i '/^# TYPE.*DATABASE.*USER/a\
# Streaming replication\
host    replication     replicator      192.168.122.0/24        scram-sha-256' "$pghba"
    fi

    # Reload
    sudo -u ${OCF_RESKEY_pguser} psql -c "SELECT pg_reload_conf();"

    ocf_log info "pg_hba.conf updated and reloaded"
    return $OCF_SUCCESS
}
```

**Priority**: LOW (could be separate utility)

---

## Documentation Updates for v1.7.0

### Update QUICKSTART.md
- Add both pg_hba.conf entries to setup
- Explain why two entries are needed
- Add validation steps

### Update MANUAL_RECOVERY_GUIDE.md
- Add section on pg_hba.conf requirements
- Add troubleshooting for pg_rewind authentication
- Add pre-recovery checklist

### Create TROUBLESHOOTING.md
- Common pg_hba.conf issues
- Authentication debugging
- Network connectivity issues
- Timeline divergence scenarios

### Update CLAUDE.md
- Document new validation checks
- Update line numbers for v1.7.0
- Add troubleshooting section reference

---

## Testing Requirements for v1.7.0

### Unit Tests
- [ ] pg_hba.conf validation function
- [ ] PGPASSFILE handling in all recovery paths
- [ ] Connectivity test logic
- [ ] Pre-recovery checks

### Integration Tests
- [ ] Recovery with correct pg_hba.conf
- [ ] Recovery with missing postgres entry (should warn)
- [ ] Recovery with missing replication entry (should fail)
- [ ] Promotion followed by standby connectivity test
- [ ] PGPASSFILE in different locations

### Manual Tests
- [ ] Full cluster setup from scratch
- [ ] Failover with connectivity test
- [ ] Recovery after timeline divergence
- [ ] pg_rewind with authentication
- [ ] pg_basebackup fallback

---

## Migration from v1.6.3 to v1.7.0

### Breaking Changes
None expected - fully backward compatible

### New Features
1. pg_hba.conf validation on startup
2. Post-promotion connectivity test
3. Pre-recovery checks
4. Better recovery logging

### Recommended Actions
1. Review pg_hba.conf on all nodes
2. Add postgres database entry for replicator user
3. Test pg_rewind manually before upgrading
4. Review recovery logs after first failover

---

## Release Checklist

- [ ] Fix pg_rewind PGPASSFILE issue
- [ ] Implement pg_hba.conf validation
- [ ] Implement connectivity test
- [ ] Update all documentation
- [ ] Create comprehensive test suite
- [ ] Update RELEASE_MANAGEMENT.md
- [ ] Update github/ directory with all changes
- [ ] Create RELEASE_v1.7.0.md
- [ ] Test in KVM environment
- [ ] Get user feedback

---

## Known Limitations (Carry-over from v1.6.3)

1. **pg_basebackup Completion**: May exit with code 1 in some edge cases
2. **Replication Slot Recreation**: May need manual recreation after complex recoveries
3. **Manual Intervention**: Some edge cases may require DBA intervention

---

## Future Considerations (v1.8.0+)

1. Support for more than 2 nodes
2. Automatic slot management
3. Monitoring integration (Prometheus/Grafana)
4. Backup integration
5. Point-in-time recovery support
6. Multiple timeline recovery
7. Cascading replication support

---

**Document Created**: 2025-11-05
**Last Updated**: 2025-11-05
**Status**: Planning - Ready for implementation
**Target Version**: 1.7.0
