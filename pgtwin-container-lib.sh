#!/bin/bash
#
# pgtwin Container Library
# Provides seamless PostgreSQL command execution with or without containers
#
# This library provides:
# 1. Automatic image version discovery from registry
# 2. Transparent command routing (bare-metal vs container)
# 3. Function overrides for PostgreSQL commands
#
# Usage in pgtwin:
#   . /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
#   # All PostgreSQL commands now work transparently!

#######################################################################
# Container Image Version Discovery
#######################################################################

# Query openSUSE registry for available PostgreSQL images
# Returns list of tags for postgres container
get_available_postgres_tags() {
    local registry="registry.opensuse.org"
    local repo="devel/bci/tumbleweed/containerfile/opensuse/postgres"
    local container_cmd=$(get_container_cmd 2>/dev/null)

    # Use skopeo to list tags (faster than container runtime)
    if command -v skopeo >/dev/null 2>&1; then
        skopeo list-tags "docker://${registry}/${repo}" 2>/dev/null | \
            grep -oP '"\K[0-9]+\.[0-9]+[^"]*'
    elif [ -n "$container_cmd" ]; then
        # Fallback: try with container runtime
        $container_cmd search --list-tags "${registry}/${repo}" --format "{{.Tag}}" 2>/dev/null
    else
        return 1
    fi
}

# Find latest image tag for a given PostgreSQL major version
# Args: $1 - major version (e.g., "17", "16", "15")
# Returns: full image tag (e.g., "17.6-158.5")
find_latest_image_for_version() {
    local major_version="$1"
    local latest_tag=""

    ocf_log debug "Searching for latest PostgreSQL ${major_version} container image" >&2

    # Get all available tags
    local tags=$(get_available_postgres_tags)

    if [ -z "$tags" ]; then
        ocf_log err "Failed to query registry for PostgreSQL images" >&2
        return 1
    fi

    # Filter tags matching major version and find latest
    # Format: 17.6-158.5, 17.5-157.2, etc.
    latest_tag=$(echo "$tags" | \
        grep "^${major_version}\." | \
        sort -t. -k1,1n -k2,2n -k3,3n | \
        tail -n 1)

    if [ -z "$latest_tag" ]; then
        ocf_log err "No images found for PostgreSQL major version ${major_version}" >&2
        return 1
    fi

    ocf_log info "Found latest PostgreSQL ${major_version} image: ${latest_tag}" >&2
    echo "$latest_tag"
    return 0
}

# Get full container image name for a major version
# Args: $1 - major version (optional, uses OCF_RESKEY_pg_major_version if not specified)
# Returns: full image URL (e.g., "registry.opensuse.org/.../postgres:17.6-158.5")
# Sets: PGTWIN_CONTAINER_IMAGE global variable
get_postgres_container_image() {
    local major_version="${1:-${OCF_RESKEY_pg_major_version}}"

    # If container_image is explicitly set, use it (backward compatibility)
    if [ -n "${OCF_RESKEY_container_image}" ] && [ "${OCF_RESKEY_container_image}" != "auto" ]; then
        PGTWIN_CONTAINER_IMAGE="${OCF_RESKEY_container_image}"
        ocf_log debug "Using explicitly configured image: ${PGTWIN_CONTAINER_IMAGE}" >&2
        return 0
    fi

    # Auto-discover latest image for major version
    if [ -z "$major_version" ]; then
        ocf_log err "No PostgreSQL major version specified" >&2
        return 1
    fi

    local image_tag=$(find_latest_image_for_version "$major_version")
    if [ $? -ne 0 ] || [ -z "$image_tag" ]; then
        ocf_log err "Failed to find image for PostgreSQL ${major_version}" >&2
        return 1
    fi

    PGTWIN_CONTAINER_IMAGE="registry.opensuse.org/devel/bci/tumbleweed/containerfile/opensuse/postgres:${image_tag}"
    ocf_log info "Auto-selected container image: ${PGTWIN_CONTAINER_IMAGE}" >&2
    return 0
}

#######################################################################
# Container Runtime Detection
#######################################################################

# Detect and set container runtime (podman or docker)
# Sets: PGTWIN_CONTAINER_RUNTIME global variable
detect_container_runtime() {
    if [ -n "$PGTWIN_CONTAINER_RUNTIME" ]; then
        return 0  # Already detected
    fi

    # Check for podman first (preferred)
    if command -v podman >/dev/null 2>&1; then
        PGTWIN_CONTAINER_RUNTIME="podman"
        ocf_log debug "Detected container runtime: podman" >&2
        return 0
    fi

    # Fallback to docker
    if command -v docker >/dev/null 2>&1; then
        PGTWIN_CONTAINER_RUNTIME="docker"
        ocf_log debug "Detected container runtime: docker" >&2
        return 0
    fi

    # No container runtime found
    ocf_log err "No container runtime found (podman or docker required)" >&2
    return 1
}

# Get container command (podman or docker)
get_container_cmd() {
    if [ -z "$PGTWIN_CONTAINER_RUNTIME" ]; then
        detect_container_runtime || return 1
    fi
    echo "$PGTWIN_CONTAINER_RUNTIME"
}

#######################################################################
# Container Helper Functions
#######################################################################

# Check if we're in container mode
is_container_mode() {
    [ "${OCF_RESKEY_container_mode}" = "true" ] || [ "${OCF_RESKEY_container_mode}" = "yes" ]
    return $?
}

# Get container name (with fallback)
get_container_name() {
    echo "${OCF_RESKEY_container_name:-postgres-ha}"
}

# Check if container exists
pgtwin_container_exists() {
    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1
    $container_cmd container exists "$container_name" 2>/dev/null
    return $?
}

# Check if container is running
pgtwin_container_is_running() {
    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1
    local state=$($container_cmd inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null)
    [ "$state" = "true" ]
    return $?
}

# Get host's postgres UID
# This detects the UID/GID of the postgres user on the host system
# Returns: "UID:GID" format (e.g., "26:26" for openSUSE, "999:999" for RHEL)
# Respects OCF_RESKEY_pguser parameter (defaults to "postgres")
pgtwin_get_host_postgres_uid() {
    local pguser="${OCF_RESKEY_pguser:-postgres}"
    local postgres_uid=$(id -u "$pguser" 2>/dev/null)
    local postgres_gid=$(id -g "$pguser" 2>/dev/null)

    if [ -z "$postgres_uid" ] || [ "$postgres_uid" -eq 0 ] 2>/dev/null; then
        ocf_log err "Failed to detect user '${pguser}' on host system" >&2
        ocf_log err "Please ensure the '${pguser}' user exists on the host" >&2
        ocf_log err "Configured via OCF_RESKEY_pguser parameter (default: postgres)" >&2
        return 1
    fi

    ocf_log info "Detected host '${pguser}' UID:GID = ${postgres_uid}:${postgres_gid}" >&2
    echo "${postgres_uid}:${postgres_gid}"
    return 0
}

# Check and verify PGDATA ownership matches host's postgres user
# Validates that PGDATA is owned by the host's postgres user
# Args: $1 - postgres UID:GID from host (optional, will auto-detect if not provided)
pgtwin_check_pgdata_ownership() {
    local host_uid_gid="${1}"

    # Auto-detect UID:GID if not provided
    if [ -z "$host_uid_gid" ]; then
        host_uid_gid=$(pgtwin_get_host_postgres_uid) || return 1
    fi

    local expected_uid=$(echo "$host_uid_gid" | cut -d: -f1)
    local expected_gid=$(echo "$host_uid_gid" | cut -d: -f2)

    # Check current ownership
    local pgdata_path="${PGDATA:-/var/lib/pgsql/data}"
    local pgdata_parent=$(dirname "$pgdata_path")

    # Get current ownership of PGDATA (if it exists)
    if [ -d "$pgdata_path" ]; then
        local current_uid=$(stat -c '%u' "$pgdata_path" 2>/dev/null)
        local current_gid=$(stat -c '%g' "$pgdata_path" 2>/dev/null)

        # Check if ownership matches
        if [ "$current_uid" != "$expected_uid" ] || [ "$current_gid" != "$expected_gid" ]; then
            local pguser="${OCF_RESKEY_pguser:-postgres}"
            ocf_log warn "========================================================" >&2
            ocf_log warn "  PGDATA OWNERSHIP MISMATCH DETECTED" >&2
            ocf_log warn "========================================================" >&2
            ocf_log warn "  Current PGDATA UID:GID: ${current_uid}:${current_gid}" >&2
            ocf_log warn "  Expected (host ${pguser}): ${expected_uid}:${expected_gid}" >&2
            ocf_log warn "--------------------------------------------------------" >&2
            ocf_log warn "  PGDATA should be owned by the host's '${pguser}' user." >&2
            ocf_log warn "" >&2
            ocf_log warn "  FIX:" >&2
            ocf_log warn "    chown -R ${pguser}:${pguser} ${pgdata_path}" >&2
            ocf_log warn "========================================================" >&2

            return 1
        fi
    fi

    # Check parent directory ownership
    local parent_uid=$(stat -c '%u' "$pgdata_parent" 2>/dev/null)
    local parent_gid=$(stat -c '%g' "$pgdata_parent" 2>/dev/null)

    if [ "$parent_uid" != "$expected_uid" ] || [ "$parent_gid" != "$expected_gid" ]; then
        local pguser="${OCF_RESKEY_pguser:-postgres}"
        ocf_log warn "Parent directory ${pgdata_parent} has incorrect ownership" >&2
        ocf_log warn "Expected ${expected_uid}:${expected_gid}, got ${parent_uid}:${parent_gid}" >&2
        ocf_log warn "Run: chown ${pguser}:${pguser} ${pgdata_parent}" >&2
        return 1
    fi

    local pguser="${OCF_RESKEY_pguser:-postgres}"
    ocf_log info "✓ PGDATA ownership correct (${pguser} ${expected_uid}:${expected_gid})" >&2
    return 0
}

# Startup safety check: Validate PGDATA ownership
# This operational precaution catches misconfigurations early:
# - Manual ownership changes
# - Migration from systems with different postgres UID
# - Restored backups from different systems
# - Accidental chown operations
pgtwin_startup_ownership_validation() {
    ocf_log info "=== Startup Safety Check: Validating PGDATA Ownership ===" >&2

    # Detect host's postgres UID:GID (container will run as this user)
    local host_postgres_uid_gid=$(pgtwin_get_host_postgres_uid) || {
        ocf_log err "STARTUP CHECK FAILED: Cannot detect host postgres user" >&2
        ocf_log err "Ensure postgres user exists on host system" >&2
        return 1
    }

    local expected_uid=$(echo "$host_postgres_uid_gid" | cut -d: -f1)
    local expected_gid=$(echo "$host_postgres_uid_gid" | cut -d: -f2)

    local pguser="${OCF_RESKEY_pguser:-postgres}"
    ocf_log info "Container will run as: ${pguser} (UID:GID ${expected_uid}:${expected_gid})" >&2

    # Validate PGDATA ownership
    if ! pgtwin_check_pgdata_ownership "$host_postgres_uid_gid"; then
        ocf_log err "==================================================" >&2
        ocf_log err "  STARTUP CHECK FAILED: OWNERSHIP MISMATCH" >&2
        ocf_log err "==================================================" >&2
        ocf_log err "Container cannot start with mismatched ownership." >&2
        ocf_log err "This protects against permission errors and data corruption." >&2
        ocf_log err "" >&2
        ocf_log err "Common causes:" >&2
        ocf_log err "  - Manual chown on PGDATA directory" >&2
        ocf_log err "  - Restored backup from different system" >&2
        ocf_log err "  - Migration with wrong UID mapping" >&2
        ocf_log err "==================================================" >&2
        return 1
    fi

    ocf_log info "✓ Startup validation passed: Ownership correct" >&2
    return 0
}

# Fix the postgres user UID:GID in container to match host system
# Container images ship with postgres user at a default UID (e.g., 499)
# This function modifies the container's /etc/passwd and /etc/group to use
# the host system's postgres UID:GID instead.
#
# This approach is cleaner than using --user flag because:
# - No duplicate user entries in /etc/passwd
# - No confusion about usernames
# - PostgreSQL runs as "postgres" user in both container and host
#
# Returns: 0 on success, 1 on failure (non-fatal)
pgtwin_fix_container_user_id() {
    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1
    local pguser="${OCF_RESKEY_pguser:-postgres}"

    # Skip if container not running
    if ! pgtwin_container_is_running; then
        ocf_log debug "Container not running, skipping user ID fix" >&2
        return 0
    fi

    # Get host UID:GID for postgres user
    local host_uid=$(id -u "$pguser" 2>/dev/null)
    local host_gid=$(id -g "$pguser" 2>/dev/null)

    if [ -z "$host_uid" ] || [ -z "$host_gid" ]; then
        ocf_log warn "Cannot determine UID:GID for user '${pguser}' on host" >&2
        return 1
    fi

    # Get current postgres UID:GID in container
    local container_uid=$($container_cmd exec "$container_name" sh -c "id -u postgres 2>/dev/null || echo 0")
    local container_gid=$($container_cmd exec "$container_name" sh -c "id -g postgres 2>/dev/null || echo 0")

    # If already matches, nothing to do
    if [ "$container_uid" = "$host_uid" ] && [ "$container_gid" = "$host_gid" ]; then
        ocf_log debug "Container postgres UID:GID already correct: ${container_uid}:${container_gid}" >&2
        return 0
    fi

    ocf_log info "Fixing container postgres UID:GID: ${container_uid}:${container_gid} → ${host_uid}:${host_gid}" >&2

    # Modify /etc/group to change postgres GID
    $container_cmd exec "$container_name" sh -c "
        sed -i 's/^postgres:x:${container_gid}:/postgres:x:${host_gid}:/' /etc/group
    " >&2

    if [ $? -ne 0 ]; then
        ocf_log warn "Failed to update /etc/group in container" >&2
        return 1
    fi

    # Modify /etc/passwd to change postgres UID:GID
    $container_cmd exec "$container_name" sh -c "
        sed -i 's/^postgres:x:${container_uid}:${container_gid}:/postgres:x:${host_uid}:${host_gid}:/' /etc/passwd
    " >&2

    if [ $? -ne 0 ]; then
        ocf_log warn "Failed to update /etc/passwd in container" >&2
        return 1
    fi

    # Determine PGHOME from pguser (postgres → /var/lib/pgsql, postgres1 → /var/lib/pgsql1, etc.)
    local pghome
    if [ "$pguser" = "postgres" ]; then
        pghome="/var/lib/pgsql"
    else
        pghome="/var/lib/${pguser}"
    fi

    # Fix ownership of PGHOME - critical for postgres user to traverse into directory
    ocf_log info "Fixing ownership of PGHOME (${pghome})..." >&2
    $container_cmd exec "$container_name" sh -c "
        chown ${host_uid}:${host_gid} ${pghome} 2>/dev/null || true
    " >&2

    # Fix ownership of /run/postgresql directory.
    # This handles the pid file and must be accessible by postgres database
    log_info "Fixing ownership of /run/postgresql..."
    $CONTAINER_CMD exec "$CONTAINER_NAME" sh -c "
        chown ${POSTGRES_UID}:${POSTGRES_GID} /run/postgresql 2>/dev/null || true
    "

    # Restart container for UID:GID changes to take full effect
    ocf_log info "Restarting container to apply UID:GID changes..." >&2
    $container_cmd stop "$container_name" >/dev/null 2>&1
    $container_cmd start "$container_name" >/dev/null 2>&1

    # Verify the fix
    local new_uid=$($container_cmd exec "$container_name" sh -c "id -u postgres 2>/dev/null")
    local new_gid=$($container_cmd exec "$container_name" sh -c "id -g postgres 2>/dev/null")

    if [ "$new_uid" = "$host_uid" ] && [ "$new_gid" = "$host_gid" ]; then
        ocf_log info "✓ Container postgres UID:GID fixed: ${new_uid}:${new_gid}" >&2
        return 0
    else
        ocf_log warn "Container postgres UID:GID is ${new_uid}:${new_gid} (expected ${host_uid}:${host_gid})" >&2
        ocf_log warn "This may cause permission issues with PGDATA" >&2
        return 1
    fi
}

# Ensure container exists and is running
# Creates and starts container if needed
pgtwin_ensure_container_running() {
    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1

    # Get image (auto-discover if needed)
    if [ -z "$PGTWIN_CONTAINER_IMAGE" ]; then
        get_postgres_container_image || return 1
    fi

    # OPERATIONAL PRECAUTION: Validate ownership on every startup
    # This catches misconfigurations before they cause runtime failures
    pgtwin_startup_ownership_validation || {
        ocf_log err "Cannot start container: Startup validation failed" >&2
        return 1
    }

    # Create container if it doesn't exist
    if ! pgtwin_container_exists; then
        ocf_log info "Creating PostgreSQL container: ${container_name}" >&2

        # Pull image if not present
        if ! $container_cmd image exists "$PGTWIN_CONTAINER_IMAGE" 2>/dev/null; then
            ocf_log info "Pulling container image: ${PGTWIN_CONTAINER_IMAGE}" >&2
            $container_cmd pull "$PGTWIN_CONTAINER_IMAGE" >&2 || {
                ocf_log err "Failed to pull container image" >&2
                return 1
            }
        fi

        # Create container with persistent storage
        # SECURITY: Container postgres user UID:GID is modified after startup
        # via pgtwin_fix_container_user_id() to match host's postgres UID:GID
        # This ensures:
        # - No file ownership changes needed (files stay owned by postgres)
        # - No duplicate user entries in /etc/passwd
        # - Same security boundary as bare-metal PostgreSQL
        # - Clean username resolution (always "postgres")
        #
        # Mount data directory and .pgpass file:
        # - /var/lib/pgsql/data (PGDATA)
        # - /var/lib/pgsql/.pgpass (authentication credentials)

        # Note: Container image has VOLUME /var/lib/pgsql/data directive
        # We must explicitly mount data directory to override the VOLUME
        #
        # Container runs as postgres user (not --user flag!)
        # The postgres UID:GID will be fixed after container starts
        # to match the host system via pgtwin_fix_container_user_id()
        $container_cmd create \
            --name "$container_name" \
            --network host \
            --security-opt label=disable \
            --mount type=bind,source=/var/lib/pgsql/data,destination=/var/lib/pgsql/data,relabel=private \
            --mount type=bind,source=/var/lib/pgsql/.pgpass,destination=/var/lib/pgsql/.pgpass,relabel=private,readonly \
            -e PGDATA="/var/lib/pgsql/data" \
            "$PGTWIN_CONTAINER_IMAGE" \
            tail -f /dev/null >&2 || {
            ocf_log err "Failed to create container" >&2
            return 1
        }
    fi

    # Start container if not running
    if ! pgtwin_container_is_running; then
        ocf_log debug "Starting container: ${container_name}" >&2
        $container_cmd start "$container_name" >&2 || {
            ocf_log err "Failed to start container" >&2
            return 1
        }
    fi

    # Fix container postgres user UID:GID to match host system
    pgtwin_fix_container_user_id || {
        ocf_log warn "Failed to fix container user ID (non-fatal, continuing)" >&2
    }

    return 0
}

# Execute command in container
pgtwin_container_exec() {
    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1

    if ! pgtwin_container_is_running; then
        ocf_log err "Cannot execute command: container not running"
        return 1
    fi

    $container_cmd exec "$container_name" "$@"
    return $?
}

#######################################################################
# Portable Binary Path Resolution
# Finds binaries using PATH lookup instead of hardcoded paths
#######################################################################

# Find binary location using PATH lookup
# Args: $1 - binary name (e.g., "runuser", "pg_ctl")
# Returns: full path to binary or empty if not found
find_binary() {
    local binary="$1"
    local result

    # Ensure PATH includes common system directories
    # This handles cases where /usr/sbin is not in PATH
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

    result=$(command -v "$binary" 2>/dev/null)
    echo "$result"
    [ -n "$result" ]
}

# Get binary path for container execution
# Args: $1 - binary name
# Returns: path to use inside container
get_container_binary_path() {
    local binary="$1"

    # Query inside the container for binary location
    # This works regardless of OS differences between host and container
    local path=$(pgtwin_container_exec sh -c "command -v $binary 2>/dev/null")

    if [ -n "$path" ]; then
        echo "$path"
        return 0
    fi

    # Fallback: try common locations if command -v fails
    for try_path in /usr/bin/$binary /usr/sbin/$binary /bin/$binary /sbin/$binary; do
        if pgtwin_container_exec test -x "$try_path" 2>/dev/null; then
            echo "$try_path"
            return 0
        fi
    done

    ocf_log err "Binary '$binary' not found in container" >&2
    return 1
}

#######################################################################
# Seamless PostgreSQL Command Wrappers
# These override standard commands and work with or without containers
#######################################################################

# Wrapper for runuser that works in both modes
# Usage: pgtwin_runuser -u postgres -- command args...
pgtwin_runuser() {
    local runuser_bin

    if is_container_mode; then
        # Execute runuser inside the container
        # Use PATH lookup to find it regardless of OS differences
        runuser_bin=$(get_container_binary_path "runuser")
        if [ -z "$runuser_bin" ]; then
            ocf_log err "runuser not found in container" >&2
            return 1
        fi
        pgtwin_container_exec "$runuser_bin" "$@"
    else
        # Bare-metal mode: find runuser using PATH lookup
        runuser_bin=$(find_binary "runuser")
        if [ -z "$runuser_bin" ]; then
            ocf_log err "runuser not found on system" >&2
            return 1
        fi
        "$runuser_bin" "$@"
    fi
    return $?
}

# Function override for runuser - seamless container support
# This makes existing pgtwin code work without modifications
runuser() {
    pgtwin_runuser "$@"
}

# Generic wrapper for PostgreSQL binaries
# Args: $1 - binary name, $2... - arguments to pass
pgtwin_pg_binary() {
    local binary="$1"
    shift
    local binary_path

    if is_container_mode; then
        pgtwin_ensure_container_running || return 1
        binary_path=$(get_container_binary_path "$binary")
        if [ -z "$binary_path" ]; then
            ocf_log err "$binary not found in container" >&2
            return 1
        fi
        pgtwin_container_exec "$binary_path" "$@"
    else
        binary_path=$(find_binary "$binary")
        if [ -z "$binary_path" ]; then
            ocf_log err "$binary not found on system" >&2
            return 1
        fi
        "$binary_path" "$@"
    fi
    return $?
}

# Wrapper for pg_ctl
# Completely transparent - works exactly like pg_ctl
pg_ctl() {
    pgtwin_pg_binary "pg_ctl" "$@"
}

# Wrapper for psql
# Completely transparent - works exactly like psql
psql() {
    pgtwin_pg_binary "psql" "$@"
}

# Wrapper for pg_basebackup
pg_basebackup() {
    pgtwin_pg_binary "pg_basebackup" "$@"
}

# Wrapper for pg_rewind
pg_rewind() {
    pgtwin_pg_binary "pg_rewind" "$@"
}

# Wrapper for pg_controldata
pg_controldata() {
    pgtwin_pg_binary "pg_controldata" "$@"
}

# Wrapper for pg_isready
pg_isready() {
    pgtwin_pg_binary "pg_isready" "$@"
}

# Wrapper for initdb
initdb() {
    pgtwin_pg_binary "initdb" "$@"
}

#######################################################################
# Container Lifecycle Management Functions
#######################################################################

# Start PostgreSQL container
# This is called by pgtwin's start action
pgtwin_container_start() {
    if ! is_container_mode; then
        return 0  # Nothing to do in bare-metal mode
    fi

    ocf_log info "Starting PostgreSQL in container mode"
    pgtwin_ensure_container_running
    return $?
}

# Stop PostgreSQL container
# This is called by pgtwin's stop action
pgtwin_container_stop() {
    if ! is_container_mode; then
        return 0  # Nothing to do in bare-metal mode
    fi

    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1

    if ! pgtwin_container_is_running; then
        ocf_log debug "Container already stopped"
        return 0
    fi

    ocf_log info "Stopping PostgreSQL container: ${container_name}"
    $container_cmd stop -t 60 "$container_name" || {
        ocf_log warn "Failed to stop container gracefully, forcing..."
        $container_cmd kill "$container_name"
    }

    return 0
}

# Clean up container (optional - for maintenance)
pgtwin_container_cleanup() {
    if ! is_container_mode; then
        return 0
    fi

    local container_name=$(get_container_name)
    local container_cmd=$(get_container_cmd) || return 1

    if pgtwin_container_exists; then
        ocf_log info "Removing container: ${container_name}"
        $container_cmd rm -f "$container_name" >/dev/null 2>&1
    fi

    return 0
}

#######################################################################
# Utility Functions
#######################################################################

# Get PostgreSQL version from running instance
pgtwin_get_pg_version() {
    local version_output

    if is_container_mode; then
        local postgres_bin=$(get_container_binary_path "postgres")
        version_output=$(pgtwin_container_exec "$postgres_bin" --version 2>/dev/null)
    else
        local postgres_bin=$(find_binary "postgres")
        version_output=$("$postgres_bin" --version 2>/dev/null)
    fi

    echo "$version_output" | grep -oP '\d+\.\d+' | head -n 1
}

# Get PostgreSQL major version
pgtwin_get_pg_major_version() {
    local full_version=$(pgtwin_get_pg_version)
    echo "$full_version" | cut -d. -f1
}

# Display container mode information (for debugging)
pgtwin_container_info() {
    ocf_log info "=== Container Mode Information ==="
    ocf_log info "Container mode: ${OCF_RESKEY_container_mode:-false}"
    ocf_log info "Container name: $(get_container_name)"
    ocf_log info "PG major version: ${OCF_RESKEY_pg_major_version:-not set}"

    if [ -n "$PGTWIN_CONTAINER_IMAGE" ]; then
        ocf_log info "Container image: ${PGTWIN_CONTAINER_IMAGE}"
    elif [ -n "${OCF_RESKEY_container_image}" ]; then
        ocf_log info "Container image: ${OCF_RESKEY_container_image}"
    fi

    if is_container_mode; then
        if pgtwin_container_exists; then
            ocf_log info "Container exists: yes"
            ocf_log info "Container running: $(pgtwin_container_is_running && echo yes || echo no)"
        else
            ocf_log info "Container exists: no"
        fi
    fi
}

#######################################################################
# Initialization
#######################################################################

# Auto-discover container image if in container mode and major version is set
if is_container_mode && [ -n "${OCF_RESKEY_pg_major_version}" ]; then
    get_postgres_container_image >/dev/null 2>&1 || true
fi

# Export functions for use in pgtwin
export -f detect_container_runtime
export -f get_container_cmd
export -f is_container_mode
export -f get_container_name
export -f pgtwin_container_exists
export -f pgtwin_container_is_running
export -f pgtwin_get_host_postgres_uid
export -f pgtwin_check_pgdata_ownership
export -f pgtwin_startup_ownership_validation
export -f pgtwin_ensure_container_running
export -f pgtwin_container_exec
export -f pgtwin_container_start
export -f pgtwin_container_stop
export -f pgtwin_container_cleanup
export -f pgtwin_get_pg_version
export -f pgtwin_get_pg_major_version
export -f pgtwin_container_info
export -f get_postgres_container_image

# Auto-detect container runtime if in container mode
if is_container_mode; then
    detect_container_runtime >/dev/null 2>&1 || true
fi

ocf_log debug "pgtwin-container-lib loaded successfully"
