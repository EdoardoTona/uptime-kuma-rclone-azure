# =============================================================================
# Uptime-Kuma with SQLite backup to Azure Blob Storage via rclone
# =============================================================================

# Build arguments with defaults
ARG UPTIME_KUMA_VERSION=2.0.2

# =============================================================================
# Stage 1: Download and prepare rclone
# =============================================================================
FROM alpine:3.19 AS tools

RUN apk add --no-cache wget unzip && \
    # Download rclone
    wget -q "https://downloads.rclone.org/rclone-current-linux-amd64.zip" -O /tmp/rclone.zip && \
    unzip -q /tmp/rclone.zip -d /tmp && \
    mv /tmp/rclone-*/rclone /usr/local/bin/rclone && \
    chmod +x /usr/local/bin/rclone

# =============================================================================
# Stage 2: Final image based on official Uptime-Kuma
# =============================================================================
FROM louislam/uptime-kuma:${UPTIME_KUMA_VERSION:-2.0.2}

ARG UPTIME_KUMA_VERSION

# Labels
LABEL org.opencontainers.image.title="Uptime-Kuma with SQLite Backup"
LABEL org.opencontainers.image.description="Uptime-Kuma with SQLite backup to Azure Blob Storage via rclone"
LABEL org.opencontainers.image.version="${UPTIME_KUMA_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/YOUR_USERNAME/uptime-kuma-litestream"

# Environment variables
ENV UPTIME_KUMA_VERSION=${UPTIME_KUMA_VERSION}
ENV DATA_DIR=/app/data
ENV DB_PATH=/app/data/kuma.db

# Azure Blob Storage configuration (to be set at runtime)
ENV AZURE_STORAGE_ACCOUNT=""
ENV AZURE_STORAGE_KEY=""

# Database backup configuration
ENV DB_BACKUP_ENABLED=true
ENV DB_BACKUP_INTERVAL=5m
ENV DB_FAIL_ON_RESTORE_ERROR=false
ENV AZURE_BACKUP_CONTAINER=kuma-backup
ENV AZURE_BACKUP_FILENAME=kuma.db

# Upload sync configuration
ENV UPLOAD_SYNC_ENABLED=true
ENV UPLOAD_SYNC_INTERVAL=5m
ENV AZURE_UPLOAD_CONTAINER=kuma-uploads

# Install sqlite3 for backup functionality
USER root
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 && rm -rf /var/lib/apt/lists/*

# Copy rclone binary from tools stage
COPY --from=tools /usr/local/bin/rclone /usr/local/bin/rclone

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Ensure data directory exists
RUN mkdir -p ${DATA_DIR}

# Expose default Uptime-Kuma port
EXPOSE 3001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -s http://localhost:3001/ || exit 1

# Use custom entrypoint
ENTRYPOINT ["/entrypoint.sh"]
