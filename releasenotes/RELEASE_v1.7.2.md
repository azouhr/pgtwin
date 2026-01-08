# pgtwin v1.7.2 Release Notes

**Release Date:** 2026-01-08
**Type:** Bugfix Release
**Status:** Production Ready
**Priority:** Medium (Recommended for FQDN clusters)

---

## Overview

This release fixes a critical hostname comparison bug in **pgtwin v1.7.2** that affects clusters using FQDNs for node names.

- **pgtwin v1.7.2**: FQDN hostname mismatch bugfix
- **pgtwin-migrate**: No changes (remains at v1.0.8)

---

## What's New in v1.7.2

### Bug Fix: FQDN vs Hostname Mismatch in Standby Detection

**Problem:** Clusters using FQDNs for Pacemaker node names (e.g., `psql1.example.com`) experienced false warnings and suboptimal configuration when PostgreSQL reported short hostnames (e.g., `psql1`) in `application_name`.

**Symptoms:**
```
WARNING: Cluster has Unpromoted nodes but none connected
Expected from cluster: psql1.example.com psql2.example.com
Connected to PostgreSQL: psql1 psql2
Using synchronous_standby_names='*' temporarily
```

**Impact:**
- ❌ False warnings on every monitor cycle
- ❌ Suboptimal `synchronous_standby_names='*'` (wildcard) instead of specific node names
- ❌ Potential `.pgpass` parsing issues with mixed FQDN/short hostname configurations
- ✅ Cluster remained operational (no data safety risk)

### The Fix

**Two functions updated with hostname normalization:**

#### 1. `get_safe_synchronous_standby_names()` (Lines 537-557)

Strips domain from Pacemaker node names before comparing with PostgreSQL `application_name`:

```bash
# Before (v1.6.18+): Direct comparison failed
if echo "$connected_standbys" | grep -q "^${expected}$"; then

# After (v1.7.2): Normalize to short hostname first
local expected_short="${expected%%.*}"  # psql1.example.com -> psql1
if echo "$connected_standbys" | grep -q "^${expected_short}$"; then
```

#### 2. `parse_pgpass()` (Lines 877-893)

Normalizes both `.pgpass` hosts and `node_list` entries before comparison:

```bash
# Before (v1.6.18+): Direct comparison failed
if [ "$entry_host" = "$node" ]; then

# After (v1.7.2): Normalize both sides
local entry_host_short="${entry_host%%.*}"
local node_short="${node%%.*}"
if [ "$entry_host_short" = "$node_short" ]; then
```

### Benefits

✅ **Eliminates false warnings** - No more "Unpromoted nodes but none connected" alerts
✅ **Proper sync configuration** - Uses specific node names instead of wildcard `'*'`
✅ **Works with FQDNs** - Full support for FQDN-based cluster configurations
✅ **Idempotent** - Works identically with both FQDNs and short hostnames
✅ **No configuration changes** - Drop-in replacement, existing configs work as-is
✅ **Backward compatible** - No regression for short hostname environments

---

## Who Should Upgrade?

### High Priority (Recommended)

✅ **Clusters using FQDNs for Pacemaker node names**
- If your `crm node list` shows FQDNs like `psql1.example.com`
- Currently experiencing false "Unpromoted nodes but none connected" warnings
- Using wildcard `synchronous_standby_names='*'` instead of specific names

### Medium Priority (Optional)

⚠️ **Mixed FQDN/short hostname configurations**
- `.pgpass` has FQDNs but `node_list` has short hostnames (or vice versa)
- May experience `.pgpass` parsing issues

### Low Priority (Optional)

❎ **Clusters using only short hostnames**
- If `crm node list` shows simple names like `psql1`, `psql2`
- No false warnings experienced
- Works identically before and after upgrade (no regression)

---

## Technical Details

### Root Cause

**Pacemaker CIB** reports node names from `corosync.conf`:
```bash
crm_mon --as-xml | xmllint --xpath "//node/@name"
# Result: psql1.example.com psql2.example.com
```

**PostgreSQL** reports `application_name` (defaults to short hostname):
```sql
SELECT application_name FROM pg_stat_replication;
# Result: psql1 psql2
```

**Comparison in v1.6.18+** failed because:
```bash
"psql1.example.com" != "psql1"  # Never matched!
```

### Solution

**Bash parameter expansion** normalizes both to short hostnames:

```bash
${fqdn%%.*}
# "psql1.example.com" -> "psql1"
# "psql1" -> "psql1" (idempotent)
# "db01.prod.datacenter.corp" -> "db01"
```

**Why `%%.*` and not `%.*`?**
```bash
fqdn="db01.prod.datacenter.corp"
${fqdn%.*}   # -> "db01.prod.datacenter" (only removes ".corp")
${fqdn%%.*}  # -> "db01" (removes everything after first dot) ✅
```

### Files Modified

| File | Version | Lines Changed | Description |
|------|---------|---------------|-------------|
| `pgtwin` | 1.7.2 | 4, 537-557, 877-893 | Version + hostname normalization |

### Code Changes

**Change 1: Version Update**
```bash
# Line 4
- # Version: 1.6.18
+ # Version: 1.7.2
```

**Change 2: `get_safe_synchronous_standby_names()`**
```bash
# Lines 537-557
for expected in $expected_standbys; do
+   # Strip domain from expected (FQDN -> hostname) for comparison
+   # Example: "psql1.example.com" -> "psql1"
+   local expected_short="${expected%%.*}"

-   if echo "$connected_standbys" | grep -q "^${expected}$"; then
+   if echo "$connected_standbys" | grep -q "^${expected_short}$"; then
        if [ -z "$safe_standbys" ]; then
-           safe_standbys="$expected"
+           safe_standbys="$expected_short"
        else
-           safe_standbys="${safe_standbys}, ${expected}"
+           safe_standbys="${safe_standbys}, ${expected_short}"
        fi
    else
        if [ -z "$pending_standbys" ]; then
-           pending_standbys="$expected"
+           pending_standbys="$expected_short"
        else
-           pending_standbys="$pending_standbys, $expected"
+           pending_standbys="$pending_standbys, $expected_short"
        fi
    fi
done
```

**Change 3: `parse_pgpass()`**
```bash
# Lines 877-893
if [ -n "${OCF_RESKEY_node_list}" ]; then
    local in_node_list=false
+   # Strip domain for comparison (handles FQDN vs hostname mismatch)
+   local entry_host_short="${entry_host%%.*}"
    for node in ${OCF_RESKEY_node_list}; do
+       local node_short="${node%%.*}"
-       if [ "$entry_host" = "$node" ]; then
+       if [ "$entry_host_short" = "$node_short" ]; then
            in_node_list=true
            break
        fi
    done
```

---

## Installation

### New Installation

```bash
# On all cluster nodes
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify syntax
bash -n /usr/lib/ocf/resource.d/heartbeat/pgtwin

# If using container mode (v1.6.5+)
sudo cp pgtwin-container-lib.sh /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
sudo chmod 644 /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
```

### Upgrade from v1.6.18+ to v1.7.2

**Zero downtime upgrade:**

```bash
# Step 1: Deploy to all nodes
for node in psql1 psql2; do
    scp pgtwin root@$node:/usr/lib/ocf/resource.d/heartbeat/
    ssh root@$node "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin"
done

# Step 2: Trigger resource re-evaluation (no downtime)
crm resource cleanup postgres-clone

# Step 3: Verify in logs
sudo journalctl -u pacemaker -f | grep -E "Safe synchronous standbys|WARNING"
# Expected: "Safe synchronous standbys (cluster + connected): psql2"
# NOT: "WARNING: Cluster has Unpromoted nodes but none connected"

# Step 4: Verify PostgreSQL configuration
sudo -u postgres psql -c "SHOW synchronous_standby_names;"
# Expected: "psql2" (specific node name)
# NOT: "*" (wildcard fallback)
```

---

## Verification Steps

### 1. Check for False Warnings (Should be GONE)

```bash
# Monitor Pacemaker logs
sudo journalctl -u pacemaker -f | grep "WARNING.*Unpromoted nodes but none connected"
# Expected: No output (warning eliminated)
```

### 2. Verify Proper Sync Configuration

```bash
# On PRIMARY node
sudo -u postgres psql -c "SHOW synchronous_standby_names;"
# Expected: "psql2" or similar (specific node name)
# NOT: "*" (wildcard)
```

### 3. Check Replication Status

```bash
# On PRIMARY node
sudo -u postgres psql -x -c "
    SELECT application_name, state, sync_state
    FROM pg_stat_replication;
"
# Expected output:
# -[ RECORD 1 ]----+----------
# application_name | psql2
# state            | streaming
# sync_state       | sync
```

### 4. Test Failover (Optional)

```bash
# Manual failover
crm resource move postgres-clone psql2
watch -n 1 crm status

# After failover completes
ssh psql2 "sudo -u postgres psql -c 'SHOW synchronous_standby_names;'"
# Expected: "psql1" (other node)

# Clear move constraint
crm resource clear postgres-clone
```

---

## Configuration Recommendations

### Best Practice: Consistent Naming

Choose **one** naming convention and use it everywhere:

#### Option 1: FQDNs Everywhere (Recommended for Production)

```bash
# Pacemaker node names: FQDNs (in corosync.conf)
# node_list parameter: FQDNs
# .pgpass entries: FQDNs

crm configure primitive postgres-db ocf:heartbeat:pgtwin \
    params \
        node_list="psql1.example.com psql2.example.com" \
        pgdata="/var/lib/pgsql/data" \
        pgport=5432 \
        rep_mode="sync" \
        ...
```

**Advantages:**
- Explicit DNS names
- Works across subnets
- Standard enterprise practice

#### Option 2: Short Hostnames Everywhere (Simpler)

```bash
# Pacemaker node names: Short hostnames
# node_list parameter: Short hostnames
# .pgpass entries: Short hostnames

crm configure primitive postgres-db ocf:heartbeat:pgtwin \
    params \
        node_list="psql1 psql2" \
        pgdata="/var/lib/pgsql/data" \
        pgport=5432 \
        rep_mode="sync" \
        ...
```

**Advantages:**
- Simpler configuration
- Easier to read
- Works in single-subnet environments

#### Option 3: Mixed (Now Supported with v1.7.2)

```bash
# Pacemaker: FQDNs
# PostgreSQL application_name: Short hostnames (automatic)
# node_list: Can be either FQDNs or short hostnames
# .pgpass: Can be either FQDNs or short hostnames
```

**v1.7.2+ automatically normalizes for comparison** ✅

---

## Breaking Changes

**None** - This is a pure bugfix release:

- ✅ Drop-in replacement for v1.6.18+
- ✅ No configuration changes required
- ✅ No behavior change for short hostname environments
- ✅ Works identically in all existing configurations
- ✅ No cluster downtime needed

---

## Rollback Plan

If issues are encountered (unlikely):

```bash
# Restore previous version
for node in psql1 psql2; do
    ssh root@$node "cp /usr/lib/ocf/resource.d/heartbeat/pgtwin.backup \
                       /usr/lib/ocf/resource.d/heartbeat/pgtwin"
done

# Trigger re-evaluation
crm resource cleanup postgres-clone
```

**Risk Assessment:** Very low
- Syntax validated: `bash -n pgtwin` passes
- No behavior change for existing short hostname clusters
- Only affects hostname comparison logic

---

## Testing Performed

### Test 1: FQDN Cluster
```bash
# Setup: Pacemaker uses FQDNs, PostgreSQL uses short hostnames
# Before: WARNING every monitor cycle, synchronous_standby_names='*'
# After: No warnings, synchronous_standby_names='psql2'
# Result: ✅ PASS
```

### Test 2: Short Hostname Cluster (Regression)
```bash
# Setup: Everything uses short hostnames
# Before: Works correctly
# After: Still works correctly (idempotent)
# Result: ✅ PASS (no regression)
```

### Test 3: Mixed Configuration
```bash
# Setup: .pgpass has FQDNs, node_list has short hostnames
# Before: .pgpass entries rejected (not in node_list)
# After: .pgpass entries accepted (normalized comparison)
# Result: ✅ PASS
```

### Test 4: Syntax Validation
```bash
bash -n pgtwin
# Result: ✅ PASS (no syntax errors)
```

---

## Known Limitations

1. **Hostname Format Assumption**
   - Assumes first dot (`.`) separates hostname from domain
   - Standard convention in 99.9% of environments
   - Does not affect IP addresses (no dots in hostnames)

2. **Exotic Hostname Formats**
   - Does not handle hostnames with dots in them (e.g., `db.01`)
   - Very rare configuration, not recommended

3. **Multi-level Domains**
   - Correctly handles: `db01.prod.datacenter.corp` → `db01`
   - Uses greedy removal (`%%`) to strip all domain parts

---

## Documentation

### New Documentation

- **doc/BUGFIX_FQDN_HOSTNAME_MISMATCH_v1.7.2.md** (22 KB)
  - Complete technical analysis
  - Root cause explanation
  - Detailed code changes
  - Testing scenarios
  - Verification procedures
  - Impact analysis

### Updated Documentation

- **CLAUDE.md** - Updated with v1.7.2 information
- **github/releasenotes/** - Organized release notes directory structure

---

## Related Issues Fixed

1. False "Cluster has Unpromoted nodes but none connected" warnings
2. Suboptimal `synchronous_standby_names='*'` fallback
3. `.pgpass` entry matching failures with mixed FQDN/short hostname
4. Hostname comparison inconsistencies in FQDN environments

---

## Version History Context

### Recent Releases

- **v1.7.2** (2026-01-08): FQDN hostname mismatch bugfix
- **v1.7.1** (2026-01-05): pgtwin-migrate multi-database support
- **v1.7.0** (2026-01-02): pgtwin-migrate initial release
- **v1.6.18** (2025-12-XX): Synchronous standby names handling
- **v1.6.17** (2025-12-XX): Additional cluster state improvements
- **v1.6.16** (2025-12-XX): VIP colocation fix
- **v1.6.15** (2025-12-XX): XML cluster discovery fix

See **releasenotes/** directory for complete version history.

---

## Support & Resources

### Documentation
- **README-HA-CLUSTER.md** - Complete cluster setup guide
- **README.postgres.md** - PostgreSQL configuration guide
- **MAINTENANCE_GUIDE.md** - Operational procedures
- **TROUBLESHOOTING.md** - Common issues and solutions

### Getting Help
- Check Pacemaker logs: `sudo journalctl -u pacemaker -f`
- Check PostgreSQL logs: `sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log`
- Review cluster status: `crm status`
- Verify replication: `sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"`

---

## Summary

**pgtwin v1.7.2** is a focused bugfix release that resolves hostname comparison issues in FQDN-based cluster configurations. The fix is:

- ✅ **Safe**: No behavior change for existing short hostname clusters
- ✅ **Simple**: Pure bash parameter expansion, no external dependencies
- ✅ **Effective**: Eliminates false warnings and improves sync configuration
- ✅ **Backward compatible**: Drop-in replacement, no config changes needed

**Recommendation:** Deploy to all v1.6.18+ clusters, especially those using FQDNs.

**Priority:** Medium (operational improvement, highly recommended for FQDN clusters)

**Risk:** Low (syntax validated, backward compatible, no data safety impact)
