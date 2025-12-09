# pgtwin - Operational Maintenance Guide

**Version**: 1.6.6
**Last Updated**: 2025-12-03
**Audience**: PostgreSQL DBAs and System Administrators

---

## 🆕 What's New in v1.6.6

**Automatic Standby Initialization**: pgtwin now automatically initializes standby nodes with empty PGDATA directories. No manual `pg_basebackup` required!

**Simply**:
1. Empty the data directory (or mount new disk)
2. Bring node online with `crm node online`
3. pgtwin automatically discovers primary, runs pg_basebackup, and starts PostgreSQL

See [FEATURE_AUTO_INITIALIZATION.md](FEATURE_AUTO_INITIALIZATION.md) for complete details.

---

## Table of Contents

1. [Replacing Data Disks](#1-replacing-data-disks)
2. [Upgrading PostgreSQL Versions](#2-upgrading-postgresql-versions)
3. [Replacing SBD Device](#3-replacing-sbd-device)
4. [General Maintenance Best Practices](#4-general-maintenance-best-practices)

---

## Overview

This guide covers critical maintenance operations for production pgtwin clusters:

- **Data disk replacement**: Migrating PostgreSQL data to new storage (SIMPLIFIED in v1.6.6!)
- **PostgreSQL upgrades**: Minor and major version updates
- **SBD replacement**: Changing STONITH fencing device

All procedures are designed to minimize or eliminate downtime.

---

## 1. Replacing Data Disks

### Scenario

You need to replace the data disk for PostgreSQL on one or both nodes due to:
- Storage hardware replacement
- Capacity upgrade
- Performance improvement
- Disk health issues

### Difficulty: ⭐ Easy (⭐⭐ in v1.6.5 and earlier)

### Prerequisites

- New disk installed and formatted on target node
- Sufficient disk space on new disk (at least 2× current data size)
- Cluster is healthy with both nodes online
- Replication is working
- **NEW in v1.6.6**: `.pgpass` file configured with replication credentials

---

### Procedure: Single Node Replacement - v1.6.6 (SIMPLIFIED ✨)

This is the **recommended** procedure for v1.6.6 and later. It leverages automatic standby initialization.

**Steps**: 3 commands
**Manual work**: < 1 minute
**Total time**: 5-60 minutes (automatic, basebackup duration)

```bash
# Step 1: Put Node in Standby Mode
crm node standby psql2

# Verify only one node is running PostgreSQL
crm status

# Step 2: Mount New Disk
# Format and mount the new disk at /var/lib/pgsql/data
# (adjust device path as needed)
ssh root@psql2
sudo mkfs.ext4 -L pgdata-new /dev/sdc1
sudo mount /dev/sdc1 /var/lib/pgsql/data

# Update /etc/fstab for persistence
sudo blkid /dev/sdc1  # Get UUID
sudo vi /etc/fstab    # Add entry: UUID=<uuid>  /var/lib/pgsql/data  ext4  defaults  0  2

# Verify .pgpass exists (should be on separate volume)
ls -l /var/lib/pgsql/.pgpass

# Step 3: Bring Node Back Online
crm node online psql2

# pgtwin automatically:
# ✅ Detects empty PGDATA
# ✅ Discovers primary node (psql1)
# ✅ Gets replication credentials from .pgpass
# ✅ Checks disk space
# ✅ Runs pg_basebackup in background
# ✅ Finalizes standby configuration
# ✅ Starts PostgreSQL when ready

# Monitor automatic initialization progress
sudo journalctl -u pacemaker -f
# OR
tail -f /var/lib/pgsql/data/.basebackup.log

# Verify replication after completion
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
```

**That's it!** No manual pg_basebackup needed.

**Time breakdown**:
- Commands: < 1 minute
- Automatic basebackup: 5-60 minutes (depends on database size)
- Total operator time: < 1 minute

---

### Procedure: Single Node Replacement - v1.6.5 and Earlier (Legacy)

This procedure replaces one node's data disk at a time without cluster downtime.

#### Step 1: Prepare New Disk

```bash
# On the node where you're replacing the disk (e.g., psql2)

# Format the new disk (adjust device path as needed)
sudo mkfs.ext4 -L pgdata-new /dev/sdc1

# Create temporary mount point
sudo mkdir -p /mnt/pgdata-new

# Mount the new disk
sudo mount /dev/sdc1 /mnt/pgdata-new

# Set ownership
sudo chown postgres:postgres /mnt/pgdata-new
sudo chmod 700 /mnt/pgdata-new
```

#### Step 2: Put Node in Standby Mode

```bash
# Put the node in standby (stops PostgreSQL on that node)
crm node standby psql2

# Verify only one node is running PostgreSQL
crm status
```

#### Step 3: Copy Data to New Disk Using pg_basebackup

```bash
# On the node with the new disk (psql2)

# Remove old data directory if it exists
sudo rm -rf /mnt/pgdata-new/*

# Run pg_basebackup from the primary to the new disk
# This uses the existing replication user and slot
# The -R flag creates standby.signal and basic postgresql.auto.conf
sudo -u postgres pg_basebackup \
    -h psql1 \
    -U replicator \
    -D /mnt/pgdata-new \
    -X stream \
    -P \
    -R \
    -S ha_slot

# Verify standby.signal was created
ls -l /mnt/pgdata-new/standby.signal

# NOTE: The pgtwin resource agent will automatically finalize the standby
# configuration when the node comes back online. It will ensure:
# - Correct application_name (cluster-specific)
# - Correct replication user
# - Correct passfile location
# - Correct primary_conninfo settings
# No manual configuration fixes are needed after pg_basebackup.
```

#### Step 4: Replace Old Disk with New Disk

```bash
# Unmount new disk
sudo umount /mnt/pgdata-new

# Backup old fstab entry
sudo cp /etc/fstab /etc/fstab.backup

# Update /etc/fstab to use new disk
# Replace old disk entry with new disk UUID/label
# Example:
# Old: UUID=old-uuid  /var/lib/pgsql/data  ext4  defaults  0  2
# New: UUID=new-uuid  /var/lib/pgsql/data  ext4  defaults  0  2

# You can find the UUID with:
sudo blkid /dev/sdc1

# Edit fstab
sudo vi /etc/fstab

# Unmount old disk (if mounted)
sudo umount /var/lib/pgsql/data || true

# Mount new disk at the correct location
sudo mount /var/lib/pgsql/data

# Verify it's the new disk
df -h /var/lib/pgsql/data
ls -l /var/lib/pgsql/data/standby.signal
```

#### Step 5: Bring Node Back Online

```bash
# Bring the node back online
crm node online psql2

# Monitor cluster status
crm_mon

# Verify replication is working
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
```

#### Step 6: Verify and Test

```bash
# On primary, verify replication to the replaced node
sudo -u postgres psql -c "
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication;"

# Test failover to the replaced node
crm resource move postgres-clone psql2

# Wait for failover to complete
crm_mon

# Verify new primary is on the replaced disk
ssh root@psql2 "df -h /var/lib/pgsql/data"

# Verify data is intact
sudo -u postgres psql -c "SELECT count(*) FROM <your_test_table>;"

# Move back to original primary
crm resource clear postgres-clone
```

#### Step 7: Repeat for Other Node (Optional)

If you need to replace both nodes' disks, repeat Steps 1-6 for the other node.

### Procedure: Both Nodes Replacement (Planned Downtime)

If you need to replace both nodes simultaneously or prefer a simpler procedure with planned downtime:

```bash
# 1. Put cluster in maintenance mode
crm configure property maintenance-mode=true

# 2. Stop PostgreSQL on both nodes
crm resource stop postgres-clone

# 3. On each node:
#    - Mount new disk at temporary location
#    - Copy data: rsync -av /var/lib/pgsql/data/ /mnt/pgdata-new/
#    - Update fstab
#    - Unmount old disk, mount new disk

# 4. Exit maintenance mode
crm configure property maintenance-mode=false

# 5. Start cluster
crm resource start postgres-clone
```

---

## 2. Upgrading PostgreSQL Versions

### Scenario

You need to upgrade PostgreSQL to a newer version:
- **Minor upgrade**: 17.0 → 17.2 (same major version)
- **Major upgrade**: 17.x → 18.x (different major version)

### Minor Version Upgrade

**Difficulty**: ⭐ Easy
**Downtime**: Rolling upgrade (zero downtime) or brief downtime

Minor version upgrades are binary compatible and don't require data directory changes.

#### Option A: Rolling Upgrade (Zero Downtime)

```bash
# Step 1: Upgrade packages on standby node first (psql2)
ssh root@psql2

# Put node in standby mode
crm node standby psql2

# Upgrade PostgreSQL packages
sudo zypper update postgresql17 postgresql17-server postgresql17-contrib

# Or on RHEL/CentOS:
sudo dnf update postgresql17 postgresql17-server postgresql17-contrib

# Bring node back online (Pacemaker will start PostgreSQL)
crm node online psql2

# Verify PostgreSQL version
sudo -u postgres psql -c "SELECT version();"

# Step 2: Upgrade primary node (psql1)
# Trigger manual failover to psql2
crm resource move postgres-clone psql2

# Wait for failover
crm_mon

# Put psql1 in standby
crm node standby psql1

# Upgrade packages on psql1
ssh root@psql1
sudo zypper update postgresql17 postgresql17-server postgresql17-contrib

# Bring psql1 back online
crm node online psql1

# Clear the move constraint
crm resource clear postgres-clone

# Step 3: Verify both nodes are on new version
ssh root@psql1 "sudo -u postgres psql -c 'SELECT version();'"
ssh root@psql2 "sudo -u postgres psql -c 'SELECT version();'"
```

#### Option B: Cluster Downtime Upgrade (Simpler)

```bash
# Stop cluster
crm resource stop postgres-clone

# Upgrade on both nodes
ssh root@psql1 "sudo zypper update postgresql17"
ssh root@psql2 "sudo zypper update postgresql17"

# Start cluster
crm resource start postgres-clone

# Verify
crm_mon
```

### Major Version Upgrade

**Difficulty**: ⭐⭐⭐ Complex
**Downtime**: Required (or complex logical replication setup)

Major version upgrades require data directory transformation using `pg_upgrade` or logical replication.

#### Option A: pg_upgrade (Faster, Requires Downtime)

**Estimated Downtime**: 15 minutes - 2 hours (depends on database size and disk speed)

```bash
# Prerequisites:
# - Install new PostgreSQL version alongside old version
# - Backup everything before starting
# - Test in development first

# Step 1: Stop cluster completely
crm resource stop postgres-clone

# Step 2: Install new PostgreSQL version on both nodes
ssh root@psql1
sudo zypper install postgresql18 postgresql18-server postgresql18-contrib

ssh root@psql2
sudo zypper install postgresql18 postgresql18-server postgresql18-contrib

# Step 3: Upgrade primary node (psql1)
ssh root@psql1

# Create new data directory
sudo mkdir -p /var/lib/pgsql/data-18
sudo chown postgres:postgres /var/lib/pgsql/data-18

# Initialize new database cluster
sudo -u postgres /usr/bin/initdb -D /var/lib/pgsql/data-18

# Copy configuration files from old cluster
sudo cp /var/lib/pgsql/data/postgresql.custom.conf /var/lib/pgsql/data-18/
sudo cp /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data-18/

# Run pg_upgrade
sudo -u postgres /usr/bin/pg_upgrade \
    --old-bindir=/usr/bin \
    --new-bindir=/usr/bin \
    --old-datadir=/var/lib/pgsql/data \
    --new-datadir=/var/lib/pgsql/data-18 \
    --check

# If check passes, run the actual upgrade
sudo -u postgres /usr/bin/pg_upgrade \
    --old-bindir=/usr/bin \
    --new-bindir=/usr/bin \
    --old-datadir=/var/lib/pgsql/data \
    --new-datadir=/var/lib/pgsql/data-18

# Backup old data and swap directories
sudo mv /var/lib/pgsql/data /var/lib/pgsql/data-17.backup
sudo mv /var/lib/pgsql/data-18 /var/lib/pgsql/data

# Step 4: Recreate standby (psql2) with pg_basebackup
ssh root@psql2

# Backup and remove old data
sudo mv /var/lib/pgsql/data /var/lib/pgsql/data-17.backup
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data

# Start PostgreSQL on primary temporarily
ssh root@psql1
sudo -u postgres /usr/bin/pg_ctl -D /var/lib/pgsql/data start

# On standby, run pg_basebackup
ssh root@psql2
sudo -u postgres pg_basebackup \
    -h psql1 \
    -U replicator \
    -D /var/lib/pgsql/data \
    -X stream \
    -P \
    -R \
    -S ha_slot

# NOTE: The -R flag creates basic standby configuration
# The pgtwin resource agent will automatically finalize the configuration
# when the cluster starts (application_name, passfile, etc.)

# Stop PostgreSQL on primary
ssh root@psql1
sudo -u postgres /usr/bin/pg_ctl -D /var/lib/pgsql/data stop

# Step 5: Update Pacemaker configuration if needed
# The pgdata path should remain the same, so no config changes needed

# Step 6: Start cluster
crm resource start postgres-clone

# Step 7: Verify
crm_mon
sudo -u postgres psql -c "SELECT version();"

# Step 8: Run post-upgrade optimization (on primary)
sudo -u postgres /var/lib/pgsql/analyze_new_cluster.sh

# Step 9: After verification, remove old data
# Wait at least 24-48 hours before removing!
sudo rm -rf /var/lib/pgsql/data-17.backup
```

#### Option B: Logical Replication (Zero Downtime, More Complex)

This approach uses PostgreSQL logical replication to create a parallel cluster running the new version.

**Complexity**: ⭐⭐⭐⭐ Very Complex
**Downtime**: Near-zero (brief switchover)

```bash
# High-level steps (detailed procedure requires separate document):

# 1. Set up new PostgreSQL 18 cluster on different servers/VMs
# 2. Configure logical replication from old cluster to new cluster
# 3. Let replication catch up (monitor lag)
# 4. During maintenance window:
#    - Stop writes to old cluster
#    - Wait for replication to fully catch up
#    - Switch application connection to new cluster
#    - Verify data integrity
#    - Decommission old cluster

# This approach requires:
# - Additional hardware/VMs for parallel cluster
# - Logical replication configuration
# - Application downtime for connection switch
# - Extensive testing
```

**Recommendation**: For most pgtwin clusters, use **pg_upgrade with planned downtime**. It's simpler, faster, and less error-prone than logical replication.

---

## 3. Replacing SBD Device

### Scenario

You need to replace the shared SBD device due to:
- Storage replacement
- Moving to different storage backend
- Hardware failure
- Storage reorganization

### Difficulty: ⭐⭐⭐ Complex

### Important Safety Notes

⚠️ **WARNING**: Improper SBD replacement can lead to:
- Loss of fencing capability (split-brain risk)
- Cluster instability
- Accidental node fencing

✅ **Best Practice**: Use the multi-device approach described below.

### Option A: Multi-Device SBD (Recommended, Zero Downtime)

SBD supports multiple devices simultaneously. Use this feature to add the new device before removing the old one.

#### Prerequisites

- New shared disk accessible from both nodes
- SBD tools installed on both nodes
- Cluster is healthy

#### Procedure

```bash
# Step 1: Initialize new SBD device (on one node)
ssh root@psql1

# Initialize the new shared disk
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 create

# Verify initialization
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 dump

# Step 2: Verify accessibility from both nodes
ssh root@psql2 "sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 dump"

# Step 3: Add new device to SBD configuration (on both nodes)

# On psql1:
ssh root@psql1

# Backup current SBD config
sudo cp /etc/sysconfig/sbd /etc/sysconfig/sbd.backup

# Edit SBD configuration
sudo vi /etc/sysconfig/sbd

# Change from:
# SBD_DEVICE="/dev/disk/by-path/virtio-pci-0000:08:00.0"
# To (note the semicolon separator):
# SBD_DEVICE="/dev/disk/by-path/virtio-pci-0000:08:00.0;/dev/disk/by-path/virtio-pci-0000:09:00.0"

# Repeat on psql2:
ssh root@psql2
sudo cp /etc/sysconfig/sbd /etc/sysconfig/sbd.backup
sudo vi /etc/sysconfig/sbd
# Make the same change

# Step 4: Restart SBD service on both nodes (one at a time)

# On psql2 (standby first):
ssh root@psql2
sudo systemctl restart sbd
sudo systemctl status sbd

# Verify SBD is using both devices
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:08:00.0 list
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 list

# On psql1 (primary):
ssh root@psql1
sudo systemctl restart sbd
sudo systemctl status sbd

# Step 5: Verify both devices are active
# Check cluster recognizes both devices
sudo crm status

# Monitor cluster logs for any SBD warnings
sudo journalctl -u sbd -f

# Step 6: Test fencing with both devices (OPTIONAL but recommended)
# This is a destructive test - only run in test environment
# sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 message psql2 test

# Step 7: Remove old SBD device from configuration

# On both nodes, edit /etc/sysconfig/sbd
# Change from:
# SBD_DEVICE="/dev/disk/by-path/virtio-pci-0000:08:00.0;/dev/disk/by-path/virtio-pci-0000:09:00.0"
# To:
# SBD_DEVICE="/dev/disk/by-path/virtio-pci-0000:09:00.0"

ssh root@psql2
sudo vi /etc/sysconfig/sbd
sudo systemctl restart sbd

ssh root@psql1
sudo vi /etc/sysconfig/sbd
sudo systemctl restart sbd

# Step 8: Verify cluster is stable with only new device
sudo crm status
sudo systemctl status sbd

# Step 9: Update Pacemaker STONITH resource (if device path changed)
sudo crm configure edit

# Find the stonith resource and update the device path:
# primitive stonith-sbd stonith:fence_sbd \
#     params \
#         devices="/dev/disk/by-path/virtio-pci-0000:09:00.0" \
#         pcmk_delay_max=30s

# Commit changes
sudo crm configure commit
```

### Option B: Direct Replacement (Requires Brief Downtime)

If you can't use multi-device SBD, use this procedure with planned downtime.

**Downtime**: 5-15 minutes

```bash
# Step 1: Put cluster in maintenance mode
crm configure property maintenance-mode=true

# Step 2: Disable STONITH temporarily
crm configure property stonith-enabled=false

# Step 3: Stop SBD on both nodes
ssh root@psql1 "sudo systemctl stop sbd"
ssh root@psql2 "sudo systemctl stop sbd"

# Step 4: Initialize new SBD device
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 create
sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 dump

# Verify from second node
ssh root@psql2 "sudo sbd -d /dev/disk/by-path/virtio-pci-0000:09:00.0 dump"

# Step 5: Update SBD configuration on both nodes
ssh root@psql1
sudo vi /etc/sysconfig/sbd
# Update SBD_DEVICE to new path

ssh root@psql2
sudo vi /etc/sysconfig/sbd
# Update SBD_DEVICE to new path

# Step 6: Start SBD on both nodes
ssh root@psql1 "sudo systemctl start sbd && sudo systemctl status sbd"
ssh root@psql2 "sudo systemctl start sbd && sudo systemctl status sbd"

# Step 7: Update Pacemaker STONITH resource
sudo crm configure edit
# Update device path in stonith-sbd resource

# Step 8: Re-enable STONITH
crm configure property stonith-enabled=true

# Step 9: Exit maintenance mode
crm configure property maintenance-mode=false

# Step 10: Verify cluster
crm status
sudo journalctl -u sbd -f
```

### Option C: Switch to Different Fencing Mechanism (Advanced)

If you're moving away from SBD entirely (e.g., to IPMI fencing in bare metal or libvirt fencing in VMs):

```bash
# This requires:
# 1. Configure new fencing device (fence_ipmilan, fence_xvm, fence_virsh, etc.)
# 2. Test new fencing mechanism
# 3. Add new STONITH resource to Pacemaker
# 4. Remove SBD STONITH resource
# 5. Disable SBD service

# Example for fence_virsh (KVM VMs):

# Step 1: Install fence agents
sudo zypper install fence-agents-virsh

# Step 2: Configure new STONITH resource
sudo crm configure primitive stonith-psql1 stonith:fence_virsh \
    params \
        ipaddr="192.168.122.1" \
        login="root" \
        port="pgtwin1" \
        pcmk_host_map="psql1:pgtwin1" \
    op monitor interval="60s"

sudo crm configure primitive stonith-psql2 stonith:fence_virsh \
    params \
        ipaddr="192.168.122.1" \
        login="root" \
        port="pgtwin2" \
        pcmk_host_map="psql2:pgtwin2" \
    op monitor interval="60s"

# Step 3: Test new fencing
sudo stonith_admin --fence psql2 --test

# Step 4: Remove old SBD STONITH resource
sudo crm configure delete stonith-sbd

# Step 5: Disable SBD service
ssh root@psql1 "sudo systemctl disable --now sbd"
ssh root@psql2 "sudo systemctl disable --now sbd"
```

---

## 4. General Maintenance Best Practices

### Pre-Maintenance Checklist

Before performing any major maintenance:

```bash
# 1. Verify cluster is healthy
crm status
crm_mon -1Afr

# 2. Check replication status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# 3. Check disk space on both nodes
df -h /var/lib/pgsql/data

# 4. Backup critical configuration files
sudo tar czf /root/cluster-config-backup-$(date +%Y%m%d).tar.gz \
    /etc/corosync/corosync.conf \
    /etc/sysconfig/sbd \
    /var/lib/pacemaker/cib.xml \
    /var/lib/pgsql/data/postgresql.conf \
    /var/lib/pgsql/data/postgresql.custom.conf \
    /var/lib/pgsql/data/pg_hba.conf \
    /var/lib/pgsql/.pgpass

# 5. Backup PostgreSQL data (if critical)
sudo -u postgres pg_basebackup -D /backup/pgdata-$(date +%Y%m%d) -Ft -z

# 6. Document current state
crm configure show > /root/crm-config-$(date +%Y%m%d).txt
sudo -u postgres psql -c "\l" > /root/databases-$(date +%Y%m%d).txt

# 7. Notify stakeholders of maintenance window
```

### Post-Maintenance Verification

After any maintenance operation:

```bash
# 1. Verify cluster status
crm status
crm_mon -1Afr

# 2. Verify PostgreSQL replication
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# 3. Verify synchronous replication (if using rep_mode=sync)
sudo -u postgres psql -c "SELECT sync_state FROM pg_stat_replication;"
# Should show: sync_state | sync

# 4. Check PostgreSQL logs for errors
sudo tail -100 /var/lib/pgsql/data/log/postgresql-*.log

# 5. Check Pacemaker logs
sudo journalctl -u pacemaker -n 100

# 6. Test failover (in test environment)
crm resource move postgres-clone psql2
# Wait for failover
crm_mon
# Test database connectivity
# Move back
crm resource clear postgres-clone

# 7. Verify VIP is working
ping 192.168.122.20
psql -h 192.168.122.20 -U postgres -c "SELECT inet_server_addr();"

# 8. Check data integrity
# Run application-specific health checks
# Verify row counts in critical tables
```

### Emergency Rollback Procedures

If maintenance goes wrong:

```bash
# For data disk replacement:
# - Unmount new disk
# - Mount old disk (if not destroyed)
# - Bring node online

# For PostgreSQL upgrade:
# - Stop cluster
# - Restore old data directory from backup
# - Downgrade packages
# - Start cluster

# For SBD replacement:
# - Restore /etc/sysconfig/sbd from backup
# - Restart SBD service
# - Revert Pacemaker STONITH configuration

# General emergency recovery:
# 1. Put cluster in maintenance mode
crm configure property maintenance-mode=true

# 2. Stop all resources manually
crm resource stop postgres-clone

# 3. Fix the issue

# 4. Start resources manually
crm resource start postgres-clone

# 5. Exit maintenance mode
crm configure property maintenance-mode=false
```

### Maintenance Windows

**Recommended Approach**:
- **Data disk replacement**: Rolling maintenance (zero downtime)
- **Minor PostgreSQL upgrade**: Rolling or brief downtime (5-10 minutes)
- **Major PostgreSQL upgrade**: Planned downtime (1-3 hours depending on size)
- **SBD replacement**: Multi-device (zero downtime) or brief downtime (10-15 minutes)

---

## Troubleshooting Maintenance Issues

### Data Disk Replacement Issues

**Issue**: pg_basebackup fails with "permission denied"
```bash
# Fix: Check .pgpass file permissions
ls -l /var/lib/pgsql/.pgpass  # Should be 600
sudo chmod 600 /var/lib/pgsql/.pgpass
```

**Issue**: Node won't start after disk replacement
```bash
# Check ownership and permissions
sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data
```

### PostgreSQL Upgrade Issues

**Issue**: pg_upgrade fails with "incompatible versions"
```bash
# Ensure old and new binaries are correct
/usr/bin/postgres --version  # Should show old version
/usr/bin/postgres-18 --version  # Should show new version
```

**Issue**: Cluster won't start after upgrade
```bash
# Check PostgreSQL logs
sudo tail -100 /var/lib/pgsql/data/log/postgresql-*.log

# Verify postgresql.conf compatibility
# Some parameters change between major versions
```

### SBD Replacement Issues

**Issue**: SBD service fails to start
```bash
# Check device accessibility
sudo sbd -d /dev/disk/by-path/... dump

# Check device permissions
ls -l /dev/disk/by-path/...

# Check SBD logs
sudo journalctl -u sbd -n 100
```

**Issue**: Cluster logs "SBD timeout" errors
```bash
# Increase SBD timeouts in /etc/sysconfig/sbd
SBD_WATCHDOG_TIMEOUT=15  # Increase if needed
sudo systemctl restart sbd
```

---

## Summary

| Operation | Difficulty | Downtime | Recommendation |
|-----------|-----------|----------|----------------|
| Data disk replacement | ⭐ Easy | Zero (rolling) | Use pg_basebackup method |
| Minor PG upgrade | ⭐ Easy | Zero or brief | Rolling upgrade preferred |
| Major PG upgrade | ⭐⭐⭐ Complex | Required (1-3h) | Use pg_upgrade with testing |
| SBD replacement | ⭐⭐⭐ Complex | Zero (multi-device) | Use multi-device approach |

---

## Additional Resources

- **pgtwin Documentation**: README.md, QUICKSTART.md
- **PostgreSQL Upgrade Guide**: https://www.postgresql.org/docs/current/upgrading.html
- **Pacemaker Administration**: https://clusterlabs.org/pacemaker/doc/
- **SBD Documentation**: https://github.com/ClusterLabs/sbd

---

**Questions or Issues?**
- GitHub: https://github.com/azouhr/pgtwin/issues
- Manual Recovery Guide: MANUAL_RECOVERY_GUIDE.md
