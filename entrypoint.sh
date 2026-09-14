#!/bin/bash
set -e

# =============================================================================
# Entrypoint script for Uptime-Kuma with SQLite backup via rclone
# =============================================================================

DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="${DB_PATH:-/app/data/kuma.db}"
DB_CONFIG_PATH="${DATA_DIR}/db-config.json"
UPLOAD_DIR="${DATA_DIR}/upload"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Convert a duration like 30s / 5m / 1h to seconds, falling back to $2.
to_seconds() {
    local value="$1"
    local fallback="$2"

    if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "${value}" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    else
        echo "${fallback}"
    fi
}

# =============================================================================
# Ensure db-config.json exists (required by Uptime-Kuma)
# =============================================================================
ensure_db_config() {
    if [[ ! -f "${DB_CONFIG_PATH}" ]]; then
        log "Creating default db-config.json..."
        cat > "${DB_CONFIG_PATH}" <<EOF
{
    "type": "sqlite",
    "port": 3306,
    "hostname": "",
    "username": "",
    "password": "",
    "dbName": "kuma"
}
EOF
        log "db-config.json created at ${DB_CONFIG_PATH}"
    else
        log "db-config.json already exists"
    fi
}

# =============================================================================
# Check if backup is enabled and configured
# =============================================================================
is_backup_configured() {
    if [[ "${DB_BACKUP_ENABLED}" != "true" ]]; then
        return 1
    fi

    if [[ -z "${AZURE_STORAGE_ACCOUNT}" ]] || [[ -z "${AZURE_STORAGE_KEY}" ]]; then
        log "WARNING: DB_BACKUP_ENABLED=true but Azure credentials not set"
        log "Required: AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_KEY"
        return 1
    fi

    return 0
}

# =============================================================================
# Check if upload sync is enabled and configured
# =============================================================================
is_upload_sync_configured() {
    if [[ "${UPLOAD_SYNC_ENABLED}" != "true" ]]; then
        return 1
    fi

    if [[ -z "${AZURE_STORAGE_ACCOUNT}" ]] || [[ -z "${AZURE_STORAGE_KEY}" ]]; then
        log "WARNING: UPLOAD_SYNC_ENABLED=true but Azure credentials not set"
        return 1
    fi

    return 0
}

# =============================================================================
# Setup rclone for Azure Blob (uses env vars directly)
# =============================================================================
setup_rclone() {
    export RCLONE_AZUREBLOB_ACCOUNT="${AZURE_STORAGE_ACCOUNT}"
    export RCLONE_AZUREBLOB_KEY="${AZURE_STORAGE_KEY}"
}

# =============================================================================
# Restore database backup from Azure Blob Storage
# =============================================================================
restore_database() {
    if ! is_backup_configured; then
        log "Database backup not configured, skipping restore"
        return 0
    fi

    log "Attempting to restore database from Azure Blob Storage..."

    mkdir -p "${DATA_DIR}"
    setup_rclone

    local container="${AZURE_BACKUP_CONTAINER:-kuma-backup}"
    local backup_filename="${AZURE_BACKUP_FILENAME:-kuma.db}"

    # Download backup if database doesn't exist
    if [[ ! -f "${DB_PATH}" ]]; then
        log "Database not found locally, attempting to download from ${container}/${backup_filename}..."

        if rclone copyto ":azureblob:${container}/${backup_filename}" "${DB_PATH}" 2>&1; then
            log "Database restore completed successfully"
            local db_size=$(stat -c%s "${DB_PATH}" 2>/dev/null || stat -f%z "${DB_PATH}" 2>/dev/null || echo "0")
            log "Restored database size: ${db_size} bytes"

            # Verify database integrity
            if sqlite3 "${DB_PATH}" "PRAGMA integrity_check;" | grep -q "ok"; then
                log "Database integrity check passed"
            else
                log "WARNING: Database integrity check failed"
            fi
        else
            log "No existing backup found or restore failed"

            # Fail if configured to do so
            if [[ "${DB_FAIL_ON_RESTORE_ERROR}" == "true" ]]; then
                log "FATAL: DB_FAIL_ON_RESTORE_ERROR=true - refusing to start without database"
                log "This prevents accidentally overwriting the remote backup with an empty database"
                exit 1
            fi

            log "Starting with fresh database (set DB_FAIL_ON_RESTORE_ERROR=true to prevent this)"
        fi
    else
        log "Database already exists at ${DB_PATH}, skipping restore"
    fi
}

# =============================================================================
# Backup database to Azure Blob Storage using sqlite.backup
# =============================================================================
BACKUP_LOCK_DIR="/tmp/kuma-backup.lock"

backup_database() {
    if ! is_backup_configured; then
        return 0
    fi

    if [[ ! -f "${DB_PATH}" ]]; then
        return 0
    fi

    # The periodic loop and the configuration-change watcher are independent
    # background jobs and can fire at the same moment. Two concurrent runs would
    # write the same temporary file and upload a torn copy, so only one wins.
    #
    # Skipping is reported as a failure on purpose: the caller must not conclude
    # that its data reached Azure. The snapshot taken by the run already in
    # flight may predate the change that triggered this call, so the watcher has
    # to keep its old fingerprint and try again.
    if ! mkdir "${BACKUP_LOCK_DIR}" 2>/dev/null; then
        log "A database backup is already running, skipping this one"
        return 1
    fi

    local status=0
    backup_database_locked || status=$?
    rmdir "${BACKUP_LOCK_DIR}" 2>/dev/null || true
    return "${status}"
}

backup_database_locked() {
    setup_rclone

    local container="${AZURE_BACKUP_CONTAINER:-kuma-backup}"
    local backup_filename="${AZURE_BACKUP_FILENAME:-kuma.db}"
    local temp_backup="/tmp/kuma.db.backup"

    log "Starting database backup..."

    # Use sqlite3 to create a backup (atomic, safe while DB is in use)
    if sqlite3 "${DB_PATH}" ".backup '${temp_backup}'"; then
        if [[ -f "${temp_backup}" ]]; then
            local backup_size=$(stat -c%s "${temp_backup}" 2>/dev/null || stat -f%z "${temp_backup}" 2>/dev/null || echo "0")
            log "Backup file created: ${backup_size} bytes"
            log "Uploading backup to ${container}/${backup_filename}..."
            if rclone copyto "${temp_backup}" ":azureblob:${container}/${backup_filename}" 2>&1; then
                log "Database backup uploaded successfully"
                rm -f "${temp_backup}"
            else
                log "ERROR: Failed to upload backup to Azure"
                rm -f "${temp_backup}"
                return 1
            fi
        fi
    else
        log "ERROR: Failed to create database backup"
        return 1
    fi
}

# =============================================================================
# Restore upload folder from Azure Blob Storage
# =============================================================================
restore_uploads() {
    if ! is_upload_sync_configured; then
        log "Upload sync not configured, skipping restore"
        return 0
    fi

    log "Restoring upload folder from Azure Blob Storage..."
    mkdir -p "${UPLOAD_DIR}"
    setup_rclone

    local container="${AZURE_UPLOAD_CONTAINER:-kuma-uploads}"
    log "Downloading uploads from container: ${container}..."

    if rclone copy ":azureblob:${container}" "${UPLOAD_DIR}/" 2>&1; then
        log "Upload folder restore completed"
    else
        log "No existing uploads found or restore failed - starting fresh"
    fi
}

# =============================================================================
# Sync upload folder to Azure Blob Storage
# =============================================================================
sync_uploads_to_azure() {
    if ! is_upload_sync_configured; then
        return 0
    fi

    mkdir -p "${UPLOAD_DIR}"
    [[ -z "$(ls -A ${UPLOAD_DIR} 2>/dev/null)" ]] && return 0

    setup_rclone
    local container="${AZURE_UPLOAD_CONTAINER:-kuma-uploads}"
    rclone sync "${UPLOAD_DIR}" ":azureblob:${container}" 2>&1 || log "WARNING: Upload sync failed"
}

# =============================================================================
# Background database backup loop (every 5 minutes)
# =============================================================================
start_database_backup_loop() {
    if ! is_backup_configured; then
        log "Database backup disabled or not configured"
        return 0
    fi

    local interval="${DB_BACKUP_INTERVAL:-5m}"
    local seconds
    seconds=$(to_seconds "${interval}" 300)

    log "Starting database backup loop (interval: ${interval} = ${seconds}s)"

    while true; do
        sleep "${seconds}"
        log "Running database backup..."
        # Without the guard, set -e would kill this loop on the first failed
        # upload and silently stop backing up for the life of the container.
        backup_database || log "WARNING: Scheduled backup did not complete, will retry next cycle"
    done &
}

# =============================================================================
# Background upload sync loop
# =============================================================================
start_upload_sync_loop() {
    if ! is_upload_sync_configured; then
        log "Upload sync disabled or not configured"
        return 0
    fi

    local interval="${UPLOAD_SYNC_INTERVAL:-5m}"
    local seconds
    seconds=$(to_seconds "${interval}" 300)

    log "Starting upload sync loop (interval: ${interval} = ${seconds}s)"

    while true; do
        sleep "${seconds}"
        log "Syncing uploads to Azure..."
        sync_uploads_to_azure
    done &
}

# =============================================================================
# Fingerprint of the configuration the user edits from the UI
# =============================================================================
# Watching the database file's mtime would be useless: Uptime-Kuma writes
# heartbeats and stats continuously, so the file is always "just modified".
# Dumping only the configuration tables isolates what an operator actually
# changes (monitors, notifications, status pages, maintenance, settings) from
# that background write traffic. The tables are tiny, so this stays cheap even
# when polled every 30 seconds.
config_fingerprint() {
    # Never touch a missing database: sqlite3 would create an empty file and the
    # next restart would then skip the restore from Azure.
    [[ -f "${DB_PATH}" ]] || return 0

    # The dump is captured first and its exit status checked before hashing:
    # piping straight into md5sum would hash a truncated dump just as happily as
    # a complete one and hide sqlite3's failure, producing a fingerprint that
    # looks like a configuration change.
    local dump
    if ! dump=$(sqlite3 "${DB_PATH}" \
        ".dump monitor" \
        ".dump monitor_tag" \
        ".dump tag" \
        ".dump monitor_group" \
        ".dump group" \
        ".dump notification" \
        ".dump monitor_notification" \
        ".dump status_page" \
        ".dump status_page_cname" \
        ".dump incident" \
        ".dump maintenance" \
        ".dump monitor_maintenance" \
        ".dump maintenance_status_page" \
        ".dump proxy" \
        ".dump docker_host" \
        ".dump remote_browser" \
        ".dump api_key" \
        ".dump user" \
        ".dump setting" \
        2>/dev/null); then
        return 0
    fi

    printf '%s' "${dump}" | md5sum | cut -d' ' -f1
}

# =============================================================================
# Background backup triggered by configuration changes
# =============================================================================
# The periodic loop alone forces a trade-off: a long DB_BACKUP_INTERVAL (1h in
# production) keeps the upload volume low but can lose an hour of work, while a
# short one uploads the whole database all night for nothing. This watcher gets
# both: the periodic loop keeps covering heartbeat history, and an edit made
# from the UI reaches Azure within one check interval.
start_config_change_backup_loop() {
    if ! is_backup_configured; then
        return 0
    fi

    if [[ "${DB_CONFIG_WATCH_ENABLED:-true}" != "true" ]]; then
        log "Configuration-change backup watcher disabled"
        return 0
    fi

    local check_seconds
    local min_seconds
    check_seconds=$(to_seconds "${DB_CONFIG_WATCH_INTERVAL:-30s}" 30)
    min_seconds=$(to_seconds "${DB_CONFIG_WATCH_MIN_INTERVAL:-60s}" 60)

    log "Starting configuration-change backup watcher (check every ${check_seconds}s, min ${min_seconds}s between backups)"

    (
        last_fingerprint=$(config_fingerprint)
        last_backup=0

        while true; do
            sleep "${check_seconds}"

            current=$(config_fingerprint)

            # An empty fingerprint means the database could not be read at all
            # (missing file, or sqlite3 failed); treat it as "no information",
            # not as a change.
            if [[ -z "${current}" || "${current}" == "${last_fingerprint}" ]]; then
                continue
            fi

            now=$(date +%s)

            # Debounce: while someone edits several monitors in a row, back up at
            # most once per min_seconds. The fingerprint is deliberately left
            # untouched so the pending change is picked up on a later tick.
            if (( now - last_backup < min_seconds )); then
                continue
            fi

            log "Configuration change detected, running database backup..."
            if backup_database; then
                last_fingerprint="${current}"
                last_backup="${now}"
            else
                log "WARNING: Configuration-change backup did not complete, will retry"
            fi
        done
    ) &
}

# =============================================================================
# Validate oauth2-proxy / Keycloak configuration
# =============================================================================
validate_external_auth_config() {
    if [[ "${KUMA_EXTERNAL_AUTH:-true}" != "true" ]]; then
        return 0
    fi

    local missing=0
    local required_vars=(
        OAUTH2_PROXY_OIDC_ISSUER_URL
        OAUTH2_PROXY_CLIENT_ID
        OAUTH2_PROXY_CLIENT_SECRET
        OAUTH2_PROXY_COOKIE_SECRET
        OAUTH2_PROXY_REDIRECT_URL
    )

    for var_name in "${required_vars[@]}"; do
        if [[ -z "${!var_name:-}" ]]; then
            log "FATAL: ${var_name} is required when KUMA_EXTERNAL_AUTH=true"
            missing=1
        fi
    done

    if [[ "${missing}" -ne 0 ]]; then
        log "Example issuer: https://keycloak.example/realms/my-realm"
        log "Recommended redirect URL: https://<public-host>/oauth2/callback"
        exit 1
    fi
}

# =============================================================================
# Process management
# =============================================================================
KUMA_PID=""
OAUTH2_PROXY_PID=""

terminate_services() {
    trap - TERM INT

    if [[ -n "${OAUTH2_PROXY_PID}" ]] && kill -0 "${OAUTH2_PROXY_PID}" 2>/dev/null; then
        kill -TERM "${OAUTH2_PROXY_PID}" 2>/dev/null || true
    fi

    if [[ -n "${KUMA_PID}" ]] && kill -0 "${KUMA_PID}" 2>/dev/null; then
        kill -TERM "${KUMA_PID}" 2>/dev/null || true
    fi
}

trap terminate_services TERM INT

# =============================================================================
# Start Uptime-Kuma with SQLite backup and optional Keycloak/OIDC protection
# =============================================================================
start_kuma() {
    log "Starting Uptime-Kuma with SQLite backup..."

    mkdir -p "${DATA_DIR}"
    mkdir -p "${UPLOAD_DIR}"

    restore_database
    restore_uploads
    ensure_db_config

    # A container killed mid-backup leaves the lock behind in its writable layer,
    # which would block every backup after a plain `docker restart`.
    rmdir "${BACKUP_LOCK_DIR}" 2>/dev/null || true

    if is_backup_configured && [[ -f "${DB_PATH}" ]]; then
        log "Running initial database backup..."
        backup_database || log "WARNING: Initial backup failed, will retry in next cycle"
    fi

    start_database_backup_loop
    start_config_change_backup_loop
    start_upload_sync_loop

    if [[ "${KUMA_EXTERNAL_AUTH:-true}" != "true" ]]; then
        log "External authentication disabled; exposing Uptime-Kuma directly on :3001"
        export UPTIME_KUMA_HOST="${UPTIME_KUMA_DIRECT_HOST:-0.0.0.0}"
        export UPTIME_KUMA_PORT="${UPTIME_KUMA_DIRECT_PORT:-3001}"
        exec node /app/server/server.js
    fi

    validate_external_auth_config

    # Security boundary: Kuma must not be reachable directly from outside the container.
    export UPTIME_KUMA_HOST="${KUMA_INTERNAL_HOST:-127.0.0.1}"
    export UPTIME_KUMA_PORT="${KUMA_INTERNAL_PORT:-3002}"

    log "Starting internal Uptime-Kuma on ${UPTIME_KUMA_HOST}:${UPTIME_KUMA_PORT}"
    node /app/server/server.js &
    KUMA_PID=$!

    log "Starting oauth2-proxy on :3001 with provider ${OAUTH2_PROXY_PROVIDER:-keycloak-oidc}"
    /usr/local/bin/oauth2-proxy &
    OAUTH2_PROXY_PID=$!

    # Exit the container if either critical process exits.
    set +e
    wait -n "${KUMA_PID}" "${OAUTH2_PROXY_PID}"
    local status=$?
    set -e

    if ! kill -0 "${KUMA_PID}" 2>/dev/null; then
        log "ERROR: Uptime-Kuma exited"
    fi
    if ! kill -0 "${OAUTH2_PROXY_PID}" 2>/dev/null; then
        log "ERROR: oauth2-proxy exited"
    fi

    terminate_services
    wait "${KUMA_PID}" 2>/dev/null || true
    wait "${OAUTH2_PROXY_PID}" 2>/dev/null || true
    exit "${status}"
}

# =============================================================================
# Main entrypoint
# =============================================================================
main() {
    log "============================================="
    log "Uptime-Kuma with SQLite Backup + Keycloak/OIDC"
    log "============================================="
    log "Uptime-Kuma version: ${UPTIME_KUMA_VERSION:-unknown}"
    log "Data directory: ${DATA_DIR}"
    log "Database path: ${DB_PATH}"
    log "External authentication: ${KUMA_EXTERNAL_AUTH:-true}"
    log "============================================="

    if is_backup_configured; then
        log "Database backup is enabled and configured"
        log "Azure Storage Account: ${AZURE_STORAGE_ACCOUNT}"
        log "Azure Container: ${AZURE_BACKUP_CONTAINER:-kuma-backup}"
        log "Backup Interval: ${DB_BACKUP_INTERVAL:-5m}"
        if [[ "${DB_CONFIG_WATCH_ENABLED:-true}" == "true" ]]; then
            log "Config-change backup: every ${DB_CONFIG_WATCH_INTERVAL:-30s}, min gap ${DB_CONFIG_WATCH_MIN_INTERVAL:-60s}"
        else
            log "Config-change backup: disabled"
        fi
    else
        log "Database backup is disabled or not configured"
    fi

    if is_upload_sync_configured; then
        log "Upload sync is enabled and configured"
        log "Azure Storage Account: ${AZURE_STORAGE_ACCOUNT}"
        log "Azure Container: ${AZURE_UPLOAD_CONTAINER:-kuma-uploads}"
        log "Sync Interval: ${UPLOAD_SYNC_INTERVAL:-5m}"
    else
        log "Upload sync is disabled or not configured"
    fi

    log "============================================="

    start_kuma
}

main "$@"
