# Release v1.6.5: Container Mode Support

**Release Type:** Minor Feature Release
**Target Date:** TBD
**Status:** Planning
**Strategic Priority:** HIGH - Foundation for guest storage system

---

## Executive Summary

v1.6.5 introduces **container mode support** for the pgtwin OCF resource agent, enabling PostgreSQL HA clusters to run in Podman/Docker containers while maintaining full Pacemaker orchestration capabilities.

**Why Container Mode First:**
1. **Optimal operation mode** for modern cloud-native deployments
2. **Foundation for guest storage system** (Btrfs subvolumes for persistent volumes)
3. **Cleaner separation** between host-managed infrastructure and guest workloads
4. **Enables future features** (container image management, multi-tenant storage, etc.)

---

## Strategic Context

### Container Mode as Foundation

```
v1.6.5: Container Mode Support
    ↓
Future: Guest Storage System
    ├── Btrfs subvolumes as container persistent volumes
    ├── Per-container storage policies (compression, snapshots)
    ├── Container-level backup/restore
    └── Multi-tenant storage isolation

Future: Advanced Features
    ├── Container image lifecycle management
    ├── Blue-green deployments
    ├── Canary testing
    └── Multi-version PostgreSQL support
```

**Key Insight:** Container mode provides the abstraction layer needed for advanced storage features.

---

## Scope of v1.6.5

### In Scope ✅

**1. Container Orchestration**
- Pacemaker directly manages container lifecycle (via podman/docker CLI)
- Container mode auto-detection
- Start/stop/promote/demote operations in containers
- Dual-mode support (VMs + containers, same agent codebase)

**2. Basic Container Operations**
- PostgreSQL running in official postgres:17 container
- Host-managed Btrfs volumes bind-mounted into containers
- Container-aware wrappers for PostgreSQL operations (pg_ctl, psql, etc.)
- Replication setup between containers

**3. Storage Foundation**
- Host Btrfs filesystem with subvolumes
- Container persistent volumes using Btrfs subvolumes
- Volume bind-mounting into containers
- Proper SELinux context handling (:Z flag)

**4. Testing**
- Container mode validation tests
- Failover testing with containers
- Dual-mode compatibility tests
- Documentation and examples

### Out of Scope (Future Releases) ❌

**Deferred to v1.7.0+:**
- LVM cache layer (focus on simple mode for v1.6.5)
- Advanced cache strategies
- Geo-distributed container deployments

**Deferred to v1.8.0+:**
- Custom container image builds
- Init container patterns
- Container image lifecycle management
- Multi-version PostgreSQL support

---

## Container Mode Design Decisions

### Decision 1: Container Runtime ✅ DECIDED

**Selected:** Podman (primary), Docker (secondary support)

**Rationale:**
- Podman: Rootless containers, systemd integration, OCI-compliant
- Docker: Compatibility for users with existing Docker setups
- Both use same CLI interface (mostly compatible)

**Implementation:**
```bash
# Auto-detect container runtime
if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
else
    ocf_log err "No container runtime found (podman or docker required)"
    exit $OCF_ERR_INSTALLED
fi
```

---

### Decision 2: Init Container Pattern ✅ DECIDED

**Selected:** No init container (initdb from host before container start)

**Rationale:**
- Simpler: Less moving parts
- Control: Host has full visibility into initialization
- Compatibility: Works with both VM and container modes
- Pacemaker-friendly: No complex multi-container orchestration

**Implementation:**
```bash
pgsql_start() {
    # If PGDATA doesn't exist or is empty, initialize
    if ! [ -f "$OCF_RESKEY_pgdata/PG_VERSION" ]; then
        ocf_log info "Initializing new PostgreSQL cluster"

        if [ "$PGTWIN_CONTAINER_MODE" = "true" ]; then
            # Run initdb via temporary container
            $CONTAINER_CMD run --rm \
                --volume "${OCF_RESKEY_pgdata_volume}:/var/lib/postgresql/data:Z" \
                postgres:17 \
                initdb --username=postgres --encoding=UTF8 --data-checksums
        else
            # Traditional VM mode
            su - postgres -c "$OCF_RESKEY_initdb -D $OCF_RESKEY_pgdata"
        fi
    fi

    # Start PostgreSQL container
    if [ "$PGTWIN_CONTAINER_MODE" = "true" ]; then
        pgsql_start_container
    else
        pgsql_start_traditional
    fi
}
```

**Alternative considered:** Init container pattern (rejected - too complex for v1.6.5)

---

### Decision 3: Container Image Strategy ✅ DECIDED

**Selected:** Use official postgres:17 image (no custom builds for v1.6.5)

**Rationale:**
- Simple: No image build pipeline needed
- Maintained: PostgreSQL team maintains official images
- Updated: Security patches via base image updates
- Standard: Well-known, documented configuration

**Configuration approach:**
```bash
# Configuration via bind-mounted files (not custom image)
$CONTAINER_CMD run -d \
    --name pgtwin-postgres-${NODE} \
    --volume ${PGDATA_VOLUME}:/var/lib/postgresql/data:Z \
    --volume ${CONFIG_DIR}/postgresql.conf:/etc/postgresql/postgresql.conf:ro,Z \
    --volume ${CONFIG_DIR}/.pgpass:/var/lib/postgresql/.pgpass:ro,Z \
    postgres:17 \
    postgres -c config_file=/etc/postgresql/postgresql.conf
```

**Future (v1.8.0+):** Custom image with extensions, monitoring tools, etc.

---

### Decision 4: Systemd Integration ✅ DECIDED

**Selected:** Pacemaker directly manages containers (no systemd intermediary for v1.6.5)

**Rationale:**
- Direct control: Pacemaker has full visibility into container lifecycle
- Simpler: No additional systemd layer
- Proven: Same pattern used by kubernetes, docker-compose, etc.
- OCF standard: Aligns with OCF resource agent patterns

**Implementation:**
```bash
# Pacemaker calls OCF agent directly
pgsql_start() {
    $CONTAINER_CMD run -d --name pgtwin-postgres ...
}

pgsql_stop() {
    $CONTAINER_CMD stop pgtwin-postgres
    $CONTAINER_CMD rm pgtwin-postgres
}

pgsql_monitor() {
    $CONTAINER_CMD inspect pgtwin-postgres --format '{{.State.Running}}'
}
```

**Future consideration (v1.8.0+):** Evaluate systemd integration if benefits emerge

---

### Decision 5: Shared Storage for Containers ✅ DECIDED

**Selected:** Host-managed Btrfs volumes, bind-mounted into containers

**Architecture:**
```
Host (Btrfs filesystem):
/var/lib/pgtwin/
├── @postgres-psql1 (subvolume)
│   ├── data/          → PostgreSQL PGDATA
│   ├── config/        → Configuration files
│   └── archive/       → WAL archive
├── @postgres-psql2 (subvolume)
│   ├── data/
│   ├── config/
│   └── archive/
└── @shared (subvolume, optional)
    └── backups/       → Shared backup storage

Container (bind mounts):
/var/lib/postgresql/data → Host: /var/lib/pgtwin/@postgres-psql1/data
/etc/postgresql/         → Host: /var/lib/pgtwin/@postgres-psql1/config
/var/lib/postgresql/archive → Host: /var/lib/pgtwin/@postgres-psql1/archive
```

**Benefits:**
- Subvolume per container (independent snapshots, quotas)
- Host manages storage (Pacemaker controls lifecycle)
- Containers remain stateless (all state in host volumes)
- Easy backup/restore (host-side operations)

**Future (v1.7.0+):** NFS/Ceph for shared storage across hosts

---

## Implementation Plan

### Phase 1: Container Mode Detection (Week 1)

**Goal:** Agent auto-detects container mode and adjusts behavior

**Tasks:**
- [ ] Add `PGTWIN_CONTAINER_MODE` environment variable detection
- [ ] Add container runtime detection (podman/docker)
- [ ] Update OCF metadata with container mode parameters
- [ ] Add validation for container mode requirements

**Parameters:**
```xml
<parameter name="container_mode" unique="0" required="0">
    <longdesc lang="en">
    Enable container mode. When true, PostgreSQL runs in a container.
    Auto-detected from environment variable PGTWIN_CONTAINER_MODE.
    </longdesc>
    <shortdesc lang="en">Enable container mode</shortdesc>
    <content type="boolean" default="false" />
</parameter>

<parameter name="container_image" unique="0" required="0">
    <longdesc lang="en">
    Container image to use for PostgreSQL.
    Default: postgres:17
    </longdesc>
    <shortdesc lang="en">Container image</shortdesc>
    <content type="string" default="postgres:17" />
</parameter>

<parameter name="container_runtime" unique="0" required="0">
    <longdesc lang="en">
    Container runtime to use (podman or docker).
    Auto-detected if not specified.
    </longdesc>
    <shortdesc lang="en">Container runtime</shortdesc>
    <content type="string" default="auto" />
</parameter>
```

---

### Phase 2: Storage Setup (Week 2)

**Goal:** Host Btrfs subvolumes for container persistent storage

**Tasks:**
- [ ] Create Btrfs subvolume structure for containers
- [ ] Setup proper permissions (postgres user/group)
- [ ] Configure SELinux contexts for bind mounts
- [ ] Document storage layout

**Setup Script:**
```bash
#!/bin/bash
# setup-container-storage.sh - Initialize Btrfs storage for containers

BTRFS_ROOT="/var/lib/pgtwin"
NODE_NAME="$1"  # psql1 or psql2

# Create Btrfs filesystem if not exists
if ! mountpoint -q "$BTRFS_ROOT"; then
    mkfs.btrfs -L pgtwin /dev/vda
    mkdir -p "$BTRFS_ROOT"
    mount /dev/vda "$BTRFS_ROOT"
fi

# Create subvolumes for this node
btrfs subvolume create "$BTRFS_ROOT/@postgres-${NODE_NAME}"
mkdir -p "$BTRFS_ROOT/@postgres-${NODE_NAME}"/{data,config,archive}

# Set ownership (postgres UID/GID should match between host and container)
chown -R 999:999 "$BTRFS_ROOT/@postgres-${NODE_NAME}"
chmod 700 "$BTRFS_ROOT/@postgres-${NODE_NAME}/data"

# SELinux contexts
chcon -R -t container_file_t "$BTRFS_ROOT/@postgres-${NODE_NAME}"

echo "Container storage initialized: $BTRFS_ROOT/@postgres-${NODE_NAME}"
```

---

### Phase 3: Container Wrapper Functions (Week 3)

**Goal:** Abstract container operations for PostgreSQL commands

**Tasks:**
- [ ] Implement `exec_in_container()` wrapper
- [ ] Wrap all PostgreSQL operations (pg_ctl, psql, pg_basebackup, etc.)
- [ ] Handle stdin/stdout/stderr properly
- [ ] Exit code propagation

**Implementation:**
```bash
#=================================================================
# Container execution wrapper
#=================================================================

exec_in_container() {
    local cmd="$1"
    shift
    local args="$@"

    if [ "$PGTWIN_CONTAINER_MODE" = "true" ]; then
        # Execute command inside running container
        $CONTAINER_CMD exec \
            --user postgres \
            pgtwin-postgres-${OCF_RESKEY_CRM_meta_on_node} \
            $cmd $args
    else
        # Traditional VM mode - execute directly
        su - postgres -c "$cmd $args"
    fi
}

#=================================================================
# PostgreSQL operation wrappers (use exec_in_container)
#=================================================================

pgsql_ctl() {
    local action="$1"
    shift

    exec_in_container pg_ctl \
        -D /var/lib/postgresql/data \
        $action "$@"
}

pgsql_query() {
    local query="$1"

    exec_in_container psql \
        -U postgres \
        -t -c "$query"
}

pgsql_is_primary() {
    local result
    result=$(pgsql_query "SELECT pg_is_in_recovery();")

    if [ "$result" = "f" ]; then
        return 0  # Primary
    else
        return 1  # Standby
    fi
}

pgsql_basebackup() {
    local dest_host="$1"
    local dest_dir="$2"

    # Note: pg_basebackup runs in SOURCE container
    exec_in_container pg_basebackup \
        -h "$dest_host" \
        -D "$dest_dir" \
        -U replicator \
        -v -P --wal-method=stream
}
```

---

### Phase 4: Container Lifecycle (Week 4)

**Goal:** Start/stop/monitor PostgreSQL containers

**Tasks:**
- [ ] Implement `pgsql_start_container()`
- [ ] Implement `pgsql_stop_container()`
- [ ] Implement `pgsql_monitor_container()`
- [ ] Handle container restarts and failures
- [ ] Network configuration for replication

**Start Function:**
```bash
pgsql_start_container() {
    local rc
    local container_name="pgtwin-postgres-${OCF_RESKEY_CRM_meta_on_node}"

    ocf_log info "Starting PostgreSQL container: $container_name"

    #=================================================================
    # Check if container already exists
    #=================================================================

    if $CONTAINER_CMD inspect "$container_name" >/dev/null 2>&1; then
        ocf_log info "Container exists, checking state"

        local state
        state=$($CONTAINER_CMD inspect "$container_name" --format '{{.State.Status}}')

        if [ "$state" = "running" ]; then
            ocf_log info "Container already running"
            return $OCF_SUCCESS
        else
            ocf_log info "Removing stopped container"
            $CONTAINER_CMD rm "$container_name"
        fi
    fi

    #=================================================================
    # Start new container
    #=================================================================

    $CONTAINER_CMD run -d \
        --name "$container_name" \
        --hostname "${OCF_RESKEY_CRM_meta_on_node}" \
        --network host \
        --volume "/var/lib/pgtwin/@postgres-${OCF_RESKEY_CRM_meta_on_node}/data:/var/lib/postgresql/data:Z" \
        --volume "/var/lib/pgtwin/@postgres-${OCF_RESKEY_CRM_meta_on_node}/config:/etc/postgresql:ro,Z" \
        --env POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
        ${OCF_RESKEY_container_image} \
        postgres \
            -c config_file=/etc/postgresql/postgresql.conf

    rc=$?

    if [ $rc -ne 0 ]; then
        ocf_log err "Failed to start container"
        return $OCF_ERR_GENERIC
    fi

    #=================================================================
    # Wait for PostgreSQL to be ready
    #=================================================================

    local timeout=60
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if pgsql_query "SELECT 1;" >/dev/null 2>&1; then
            ocf_log info "PostgreSQL ready in container"
            return $OCF_SUCCESS
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    ocf_log err "PostgreSQL failed to start within ${timeout} seconds"
    return $OCF_ERR_GENERIC
}
```

**Stop Function:**
```bash
pgsql_stop_container() {
    local container_name="pgtwin-postgres-${OCF_RESKEY_CRM_meta_on_node}"

    ocf_log info "Stopping PostgreSQL container: $container_name"

    # Graceful shutdown via pg_ctl (inside container)
    pgsql_ctl stop -m fast || ocf_log warn "Graceful stop failed"

    # Stop container (if still running)
    $CONTAINER_CMD stop -t 30 "$container_name" 2>/dev/null || true

    # Remove container
    $CONTAINER_CMD rm "$container_name" 2>/dev/null || true

    return $OCF_SUCCESS
}
```

**Monitor Function:**
```bash
pgsql_monitor_container() {
    local container_name="pgtwin-postgres-${OCF_RESKEY_CRM_meta_on_node}"

    # Check container is running
    if ! $CONTAINER_CMD inspect "$container_name" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        ocf_log info "Container not running"
        return $OCF_NOT_RUNNING
    fi

    # Check PostgreSQL is responding
    if ! pgsql_query "SELECT 1;" >/dev/null 2>&1; then
        ocf_log err "PostgreSQL not responding in container"
        return $OCF_ERR_GENERIC
    fi

    # Check role (Master/Slave)
    if pgsql_is_primary; then
        ocf_log debug "Monitor: PostgreSQL is primary"
        return $OCF_RUNNING_MASTER
    else
        ocf_log debug "Monitor: PostgreSQL is standby"
        return $OCF_SUCCESS
    fi
}
```

---

### Phase 5: Replication Setup (Week 5)

**Goal:** Configure replication between containers

**Tasks:**
- [ ] Network connectivity between containers (host network mode)
- [ ] Replication user setup
- [ ] .pgpass configuration
- [ ] primary_conninfo in containers
- [ ] Replication slot creation

**Network Configuration:**
- Use `--network host` mode (containers share host network namespace)
- PostgreSQL listens on host's IP address
- Replication works same as VM mode (IP-based)

**Challenge:** Container name resolution
- Containers use host networking (no Docker DNS)
- Use IP addresses for replication connections
- Or use host's /etc/hosts for name resolution

---

### Phase 6: Testing (Week 6)

**Goal:** Comprehensive testing of container mode

**Test Scenarios:**
- [ ] Container start/stop/restart
- [ ] Failover (primary container failure)
- [ ] Switchover (planned failover)
- [ ] Split-brain prevention
- [ ] Replication (container → container)
- [ ] pg_basebackup in container mode
- [ ] pg_rewind in container mode
- [ ] Dual-mode compatibility (VM agent unchanged)

**Test Script:**
```bash
#!/bin/bash
# test-container-mode.sh

export PGTWIN_CONTAINER_MODE=true

# Test 1: Start containers on both nodes
crm resource start postgres-clone

# Test 2: Verify containers running
podman ps | grep pgtwin-postgres

# Test 3: Verify replication
sudo podman exec pgtwin-postgres-psql1 psql -U postgres -c \
    "SELECT * FROM pg_stat_replication;"

# Test 4: Failover test
crm node standby psql1
# Wait for failover
# Verify psql2 promoted

# Test 5: Return psql1 as standby
crm node online psql1
# Verify psql1 rejoins as standby

# Test 6: Dual-mode test (ensure VM mode still works)
unset PGTWIN_CONTAINER_MODE
# Run VM mode tests
```

---

### Phase 7: Documentation (Week 7)

**Goal:** Complete documentation for container mode

**Deliverables:**
- [ ] Container mode setup guide
- [ ] Migration guide (VM → container)
- [ ] Troubleshooting guide
- [ ] Performance comparison (VM vs container)
- [ ] Best practices

---

## File Changes

### New Files

```
/home/claude/postgresHA/
├── RELEASE_v1.6.5_CONTAINER_MODE.md (this file)
├── docs/
│   ├── CONTAINER_MODE_SETUP.md
│   ├── CONTAINER_MODE_MIGRATION.md
│   └── CONTAINER_MODE_TROUBLESHOOTING.md
├── scripts/
│   ├── setup-container-storage.sh
│   └── test-container-mode.sh
└── examples/
    ├── container-mode-cluster.crm
    └── docker-compose.yml (reference)
```

### Modified Files

```
pgtwin (OCF agent)
├── Add container mode detection
├── Add container wrapper functions
├── Add container lifecycle operations
└── Update metadata with container parameters

CLAUDE.md
├── Update version to 1.6.5
└── Add container mode documentation

DESIGN_DECISIONS_CONSOLIDATED.md
├── Move container mode from "deferred" to "v1.6.5"
└── Update implementation roadmap

DESIGN_CONTAINER_MODE.md
├── Mark decisions as DECIDED
└── Update status to "in progress for v1.6.5"
```

---

## Success Criteria

### Functional Requirements ✅

- [ ] PostgreSQL starts in container via Pacemaker
- [ ] Replication works between containers
- [ ] Failover works (automatic and manual)
- [ ] All OCF actions work (start/stop/promote/demote/monitor)
- [ ] Dual-mode support (same agent, VM or container)

### Performance Requirements ✅

- [ ] Container overhead < 5% vs VM mode
- [ ] Failover time comparable to VM mode
- [ ] Replication lag comparable to VM mode

### Reliability Requirements ✅

- [ ] 100+ failover tests pass
- [ ] Split-brain prevention works
- [ ] STONITH integration works
- [ ] No data loss scenarios

### Documentation Requirements ✅

- [ ] Setup guide complete
- [ ] Migration guide complete
- [ ] Troubleshooting guide complete
- [ ] All examples tested and working

---

## Timeline

**Target:** 7 weeks from start

| Week | Phase | Deliverable |
|------|-------|-------------|
| 1 | Container detection | Mode switching works |
| 2 | Storage setup | Btrfs subvolumes ready |
| 3 | Wrapper functions | PostgreSQL commands work in containers |
| 4 | Lifecycle | Start/stop/monitor working |
| 5 | Replication | Containers replicate |
| 6 | Testing | All tests pass |
| 7 | Documentation | Docs complete, release ready |

---

## Risk Assessment

### High Risk ⚠️

**Network configuration complexity**
- Mitigation: Use host network mode (simpler, proven)
- Fallback: Document DNS/host resolution requirements

**SELinux context issues**
- Mitigation: Use :Z flag on all bind mounts
- Fallback: Document SELinux permissive mode for troubleshooting

### Medium Risk ⚠️

**Container runtime differences (Podman vs Docker)**
- Mitigation: Test both runtimes
- Fallback: Document known differences

**UID/GID mapping**
- Mitigation: Use standard postgres UID (999) in container and host
- Fallback: Document user namespace configuration

### Low Risk ✓

**Performance overhead**
- Mitigation: Containers have minimal overhead with host networking
- Fallback: Performance benchmarking during testing phase

---

## Future Enhancements (v1.7.0+)

Building on v1.6.5 container foundation:

**v1.7.0: Guest Storage System**
- Btrfs subvolumes as first-class persistent volumes
- Per-container storage policies
- Container-level snapshots and backups
- Storage quotas per container

**v1.8.0: Advanced Container Features**
- Custom container images with extensions
- Container image lifecycle management
- Blue-green deployments
- Multi-version PostgreSQL support

**v1.9.0: Multi-Tenant Storage**
- Multiple PostgreSQL containers per host
- Storage isolation between tenants
- Shared backup storage
- Quota management

---

## Conclusion

v1.6.5 container mode support is the **strategic foundation** for future guest storage innovations. By implementing container orchestration now, we enable:

1. **Clean abstraction** for guest workloads
2. **Flexible storage** via Btrfs subvolumes
3. **Future-ready architecture** for cloud-native features
4. **Dual-mode flexibility** (VMs + containers)

**Next Step:** Begin Phase 1 implementation (container mode detection).
