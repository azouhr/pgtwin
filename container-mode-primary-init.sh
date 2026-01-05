#!/bin/bash
#
# Container Mode Primary Node Initialization
# Performs all Part 1 setup steps via temporary container
#
# Usage: sudo ./container-mode-primary-init.sh
#

set -e

# Configuration
PG_IMAGE="registry.opensuse.org/devel/bci/tumbleweed/containerfile/opensuse/postgres:17"
PGDATA="/var/lib/pgsql/data"
CONTAINER_NAME="postgres-init-temp"
CONTAINER_USER="pgcontainer"     # User for container mode (will match postgres UID)
REPLICATION_USER="replicator"
REPLICATION_PASSWORD="changeme"  # CHANGE THIS!
NODE1_IP="192.168.122.60"        # CHANGE THIS!
NODE2_IP="192.168.122.120"       # CHANGE THIS!

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if postgres user exists (for bare-metal compatibility)
    if ! id postgres >/dev/null 2>&1; then
        log_warn "postgres user does not exist - creating it"
        groupadd -r postgres
        useradd -r -g postgres -d /var/lib/pgsql -s /bin/bash -c "PostgreSQL Server" postgres
    fi

    POSTGRES_UID=$(id -u postgres)
    POSTGRES_GID=$(id -g postgres)
    log_info "postgres user found: UID=${POSTGRES_UID} GID=${POSTGRES_GID}"

    # Check if container user exists, create with SAME UID as postgres
    if ! id "$CONTAINER_USER" >/dev/null 2>&1; then
        log_info "Creating container user '$CONTAINER_USER' with UID=${POSTGRES_UID}"
        groupadd -g "$POSTGRES_GID" "$CONTAINER_USER" 2>/dev/null || true
        useradd -u "$POSTGRES_UID" -g "$POSTGRES_GID" -d /var/lib/pgsql -s /bin/bash -c "PostgreSQL Container" "$CONTAINER_USER"
    else
        # Verify container user has same UID as postgres
        CONTAINER_UID=$(id -u "$CONTAINER_USER")
        if [ "$CONTAINER_UID" -ne "$POSTGRES_UID" ]; then
            log_error "Container user '$CONTAINER_USER' has wrong UID: ${CONTAINER_UID} (expected ${POSTGRES_UID})"
            log_error "Remove and recreate: sudo userdel $CONTAINER_USER"
            exit 1
        fi
    fi
    log_info "Container user '$CONTAINER_USER': UID=${POSTGRES_UID} GID=${POSTGRES_GID}"

    # Check container runtime
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    else
        log_error "Neither podman nor docker found"
        exit 1
    fi
    log_info "Container runtime: ${CONTAINER_CMD}"

    # Ensure parent directory exists and is owned by postgres
    PGDATA_PARENT=$(dirname "$PGDATA")
    if [ ! -d "$PGDATA_PARENT" ]; then
        log_info "Creating parent directory: $PGDATA_PARENT"
        mkdir -p "$PGDATA_PARENT"
        chown postgres:postgres "$PGDATA_PARENT"
        chmod 755 "$PGDATA_PARENT"
    else
        # Fix ownership if directory exists but has wrong owner
        CURRENT_OWNER=$(stat -c '%U' "$PGDATA_PARENT" 2>/dev/null)
        if [ "$CURRENT_OWNER" != "postgres" ]; then
            log_warn "Fixing ownership of $PGDATA_PARENT (was: $CURRENT_OWNER)"
            chown postgres:postgres "$PGDATA_PARENT"
        fi
    fi

    # Check if PGDATA directory exists and is owned by postgres
    if [ ! -d "$PGDATA" ]; then
        log_info "Creating PGDATA directory: $PGDATA"
        mkdir -p "$PGDATA"
        chown postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
    fi

    # Check if PGDATA is empty or if reinitializing
    if [ -f "$PGDATA/PG_VERSION" ]; then
        log_warn "PGDATA appears to already be initialized (PG_VERSION exists)"
        read -p "Continue anyway? This will NOT reinitialize. (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Pull container image
pull_image() {
    log_info "Pulling PostgreSQL container image..."
    $CONTAINER_CMD pull "$PG_IMAGE"
}

# Create and start temporary container
start_container() {
    log_info "Creating temporary container: $CONTAINER_NAME"

    # Remove old container if exists
    if $CONTAINER_CMD ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Removing existing container: $CONTAINER_NAME"
        $CONTAINER_CMD stop "$CONTAINER_NAME" 2>/dev/null || true
        $CONTAINER_CMD rm "$CONTAINER_NAME" 2>/dev/null || true
    fi

    # Run container as the host's postgres/pgcontainer UID
    # This matches file ownership and avoids permission issues
    log_info "Starting container with UID=${POSTGRES_UID}, GID=${POSTGRES_GID}"

    $CONTAINER_CMD run -d \
        --name "$CONTAINER_NAME" \
        --user "${POSTGRES_UID}:${POSTGRES_GID}" \
        --network host \
        --mount type=bind,source=${PGDATA},destination=${PGDATA},relabel=private \
        -e PGDATA="${PGDATA}" \
        -e HOME="/var/lib/pgsql" \
        "$PG_IMAGE" \
        tail -f /dev/null

    log_info "Container started successfully"
}

# Initialize PostgreSQL database
initialize_database() {
    log_info "Initializing PostgreSQL database..."

    if [ -f "$PGDATA/PG_VERSION" ]; then
        log_warn "Database already initialized, skipping initdb"
        return
    fi

    $CONTAINER_CMD exec "$CONTAINER_NAME" initdb -D "$PGDATA"
    log_info "Database initialized"
}

# Create postgresql.custom.conf
create_custom_config() {
    log_info "Creating postgresql.custom.conf..."

    cat > /tmp/postgresql.custom.conf << 'CUSTOMCONF'
# HA CRITICAL SETTINGS
restart_after_crash = off              # CRITICAL: Must be 'off' for Pacemaker
wal_level = replica                    # REQUIRED for physical replication
max_wal_senders = 16                   # REQUIRED (minimum: 2)
max_replication_slots = 16             # REQUIRED (match wal_senders)
hot_standby = on                       # Allows read queries on standby

# PRODUCTION TIMEOUTS (v1.5 standards)
wal_sender_timeout = 30000             # 30 seconds (prevents false disconnections)
max_standby_streaming_delay = 60000    # 60 seconds (bounds replication lag)
max_standby_archive_delay = 60000      # 60 seconds (bounds replication lag)

# NETWORK & CONNECTION
port = 5432                            # PostgreSQL listening port (change if running multiple instances)
listen_addresses = '*'                 # Or specific IPs: 'localhost,192.168.122.60'

# REPLICATION
synchronous_commit = on                # For zero data loss (sync replication)
synchronous_standby_names = '*'        # Match any standby

# ARCHIVE (optional - for PITR)
archive_mode = off                     # Enable if you need point-in-time recovery
# archive_command = 'rsync -a %p /archive/%f || /bin/true'  # Must have error handling!

# LOGGING
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_replication_commands = on
CUSTOMCONF

    # Copy to PGDATA
    cp /tmp/postgresql.custom.conf "${PGDATA}/postgresql.custom.conf"
    chown postgres:postgres "${PGDATA}/postgresql.custom.conf"

    log_info "Custom configuration created"
}

# Update postgresql.conf to include custom config
update_main_config() {
    log_info "Updating postgresql.conf to include custom config..."

    if grep -q "include.*postgresql.custom.conf" "${PGDATA}/postgresql.conf"; then
        log_warn "postgresql.conf already includes custom config"
    else
        echo "" >> "${PGDATA}/postgresql.conf"
        echo "include = 'postgresql.custom.conf'" >> "${PGDATA}/postgresql.conf"
        log_info "Added include directive to postgresql.conf"
    fi
}

# Configure pg_hba.conf
configure_pg_hba() {
    log_info "Configuring pg_hba.conf..."

    cat > "${PGDATA}/pg_hba.conf" << PGHBACONF
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication connections from cluster network
host    replication     ${REPLICATION_USER}      ${NODE1_IP}/32          scram-sha-256
host    replication     ${REPLICATION_USER}      ${NODE2_IP}/32          scram-sha-256

# postgres database access for pg_rewind (required for auto-recovery)
host    postgres        ${REPLICATION_USER}      ${NODE1_IP}/32          scram-sha-256
host    postgres        ${REPLICATION_USER}      ${NODE2_IP}/32          scram-sha-256

# Application connections
host    all             all             192.168.122.0/24        scram-sha-256
PGHBACONF

    chown postgres:postgres "${PGDATA}/pg_hba.conf"
    log_info "pg_hba.conf configured"
}

# Temporarily disable synchronous_standby_names for startup
disable_sync_for_startup() {
    log_info "Temporarily disabling synchronous_standby_names for startup..."

    cp -a "${PGDATA}/postgresql.custom.conf" "${PGDATA}/postgresql.custom.conf.backup"
    sed -i "s/^synchronous_standby_names = .*/synchronous_standby_names = ''/" "${PGDATA}/postgresql.custom.conf"

    log_info "Synchronous replication disabled temporarily"
}

# Start PostgreSQL
start_postgresql() {
    log_info "Starting PostgreSQL..."

    $CONTAINER_CMD exec "$CONTAINER_NAME" pg_ctl -D "$PGDATA" -l "${PGDATA}/pg.log" start
    sleep 3

    # Verify it's running
    if $CONTAINER_CMD exec "$CONTAINER_NAME" pg_isready -q; then
        log_info "PostgreSQL started successfully"
    else
        log_error "PostgreSQL failed to start"
        log_error "Check logs: cat ${PGDATA}/pg.log"
        exit 1
    fi
}

# Create replication user
create_replication_user() {
    log_info "Creating replication user: ${REPLICATION_USER}..."

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "CREATE USER ${REPLICATION_USER} WITH REPLICATION PASSWORD '${REPLICATION_PASSWORD}';"

    # Grant necessary privileges for pg_rewind
    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "GRANT pg_read_all_data TO ${REPLICATION_USER};"

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "GRANT EXECUTE ON FUNCTION pg_ls_dir(text, boolean, boolean) TO ${REPLICATION_USER};"

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "GRANT EXECUTE ON FUNCTION pg_stat_file(text, boolean) TO ${REPLICATION_USER};"

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "GRANT EXECUTE ON FUNCTION pg_read_binary_file(text) TO ${REPLICATION_USER};"

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "GRANT EXECUTE ON FUNCTION pg_read_binary_file(text, bigint, bigint, boolean) TO ${REPLICATION_USER};"

    log_info "Replication user created with necessary privileges"
}

# Create replication slot
create_replication_slot() {
    log_info "Creating replication slot: ha_slot..."

    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c \
        "SELECT pg_create_physical_replication_slot('ha_slot');"

    log_info "Replication slot created"
}

# Restore synchronous_standby_names
restore_sync_config() {
    log_info "Restoring synchronous_standby_names configuration..."

    mv "${PGDATA}/postgresql.custom.conf.backup" "${PGDATA}/postgresql.custom.conf"

    # Reload configuration
    $CONTAINER_CMD exec "$CONTAINER_NAME" psql -U postgres -c "SELECT pg_reload_conf();"

    log_info "Configuration restored"
}

# Stop PostgreSQL
stop_postgresql() {
    log_info "Stopping PostgreSQL..."

    $CONTAINER_CMD exec "$CONTAINER_NAME" pg_ctl -D "$PGDATA" stop

    log_info "PostgreSQL stopped"
}

# Clean up container
cleanup_container() {
    log_info "Removing temporary container..."

    $CONTAINER_CMD stop "$CONTAINER_NAME" 2>/dev/null || true
    $CONTAINER_CMD rm "$CONTAINER_NAME" 2>/dev/null || true

    log_info "Container removed"
}

# Create .pgpass file
create_pgpass() {
    log_info "Creating .pgpass file..."

    PGPASS_FILE="/var/lib/pgsql/.pgpass"

    cat > "$PGPASS_FILE" << PGPASSEOF
# Replication credentials for cluster
# Format: hostname:port:database:username:password
*:5432:replication:${REPLICATION_USER}:${REPLICATION_PASSWORD}
*:5432:postgres:${REPLICATION_USER}:${REPLICATION_PASSWORD}
PGPASSEOF

    chown postgres:postgres "$PGPASS_FILE"
    chmod 600 "$PGPASS_FILE"

    log_info ".pgpass file created"
}

# Print summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}✓ Primary Node Initialization Complete${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Configuration Summary:"
    echo "  • PGDATA: ${PGDATA}"
    echo "  • Container User: ${CONTAINER_USER} (UID=${POSTGRES_UID})"
    echo "  • Replication User: ${REPLICATION_USER}"
    echo "  • Replication Slot: ha_slot"
    echo "  • PostgreSQL Port: 5432"
    echo ""
    echo "Next Steps:"
    echo "  1. Copy .pgpass file to standby node:"
    echo "     scp /var/lib/pgsql/.pgpass root@node2:/var/lib/pgsql/"
    echo ""
    echo "  2. On standby node (container mode):"
    echo "     • Create postgres user: useradd -r -g postgres postgres"
    echo "     • Create pgcontainer user: useradd -u ${POSTGRES_UID} -g postgres pgcontainer"
    echo "     • Create /var/lib/pgsql/data directory owned by postgres"
    echo "     • Ensure .pgpass file has correct permissions (600)"
    echo ""
    echo "  3. Configure Pacemaker cluster (Part 2 of QUICKSTART)"
    echo "     • Use container_mode=\"true\" parameter"
    echo "     • Use pguser=\"${CONTAINER_USER}\" parameter  ← IMPORTANT!"
    echo "     • The standby will auto-initialize on first start"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Main execution
main() {
    log_info "Starting Container Mode Primary Node Initialization"
    log_info "Image: ${PG_IMAGE}"
    log_info "PGDATA: ${PGDATA}"
    echo ""

    log_warn "Please review configuration at the top of this script:"
    log_warn "  - REPLICATION_PASSWORD"
    log_warn "  - NODE1_IP and NODE2_IP"
    echo ""
    read -p "Continue with initialization? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi

    check_prerequisites
    pull_image
    start_container

    initialize_database
    create_custom_config
    update_main_config
    configure_pg_hba
    disable_sync_for_startup
    start_postgresql

    create_replication_user
    create_replication_slot

    restore_sync_config
    stop_postgresql
    cleanup_container

    create_pgpass

    print_summary

    log_info "Initialization complete!"
}

# Run main function
main "$@"
