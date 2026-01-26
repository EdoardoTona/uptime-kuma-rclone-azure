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
backup_database() {
    if ! is_backup_configured; then
        return 0
    fi

    if [[ ! -f "${DB_PATH}" ]]; then
        return 0
    fi

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
    # Convert interval to seconds
    local seconds
    if [[ "${interval}" =~ ^([0-9]+)s$ ]]; then
        seconds="${BASH_REMATCH[1]}"
    elif [[ "${interval}" =~ ^([0-9]+)m$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 60))
    elif [[ "${interval}" =~ ^([0-9]+)h$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 3600))
    else
        seconds=300  # default 5 minutes
    fi

    log "Starting database backup loop (interval: ${interval} = ${seconds}s)"

    while true; do
        sleep "${seconds}"
        log "Running database backup..."
        backup_database
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
    # Convert interval to seconds
    local seconds
    if [[ "${interval}" =~ ^([0-9]+)s$ ]]; then
        seconds="${BASH_REMATCH[1]}"
    elif [[ "${interval}" =~ ^([0-9]+)m$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 60))
    elif [[ "${interval}" =~ ^([0-9]+)h$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 3600))
    else
        seconds=300  # default 5 minutes
    fi

    log "Starting upload sync loop (interval: ${interval} = ${seconds}s)"

    while true; do
        sleep "${seconds}"
        log "Syncing uploads to Azure..."
        sync_uploads_to_azure
    done &
}

# =============================================================================
# Start Uptime-Kuma with SQLite backup
# =============================================================================
start_kuma() {
    log "Starting Uptime-Kuma with SQLite backup..."

    # Ensure data directory exists
    mkdir -p "${DATA_DIR}"
    mkdir -p "${UPLOAD_DIR}"

    # Restore database if configured
    restore_database

    # Restore uploads from Azure
    restore_uploads

    # Ensure db-config.json exists (required by Uptime-Kuma on first start)
    ensure_db_config

    # Run initial backup if database exists (to ensure remote is in sync)
    if is_backup_configured && [[ -f "${DB_PATH}" ]]; then
        log "Running initial database backup..."
        backup_database || log "WARNING: Initial backup failed, will retry in next cycle"
    fi

    # Start background database backup loop
    start_database_backup_loop

    # Start background upload sync loop
    start_upload_sync_loop

    log "Starting Uptime-Kuma..."

    # Start Uptime-Kuma
    exec node /app/server/server.js
}

# =============================================================================
# Main entrypoint
# =============================================================================
main() {
    log "============================================="
    log "Uptime-Kuma with SQLite Backup"
    log "============================================="
    log "Uptime-Kuma version: ${UPTIME_KUMA_VERSION:-unknown}"
    log "Data directory: ${DATA_DIR}"
    log "Database path: ${DB_PATH}"
    log "============================================="

    if is_backup_configured; then
        log "Database backup is enabled and configured"
        log "Azure Storage Account: ${AZURE_STORAGE_ACCOUNT}"
        log "Azure Container: ${AZURE_BACKUP_CONTAINER:-kuma-backup}"
        log "Backup Interval: ${DB_BACKUP_INTERVAL:-5m}"
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

# Run main function
main "$@"
