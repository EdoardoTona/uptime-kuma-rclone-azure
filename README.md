# Uptime-Kuma with SQLite Backup

Docker image for [Uptime-Kuma](https://github.com/louislam/uptime-kuma) with SQLite backup to Azure Blob Storage via rclone.

## Features

- Based on official Uptime-Kuma image
- Automatic SQLite backup to Azure Blob Storage every 5 minutes (configurable)
- Uses `sqlite3 .backup` for safe, atomic backups while DB is in use
- Automatic database restore on container startup
- **Upload folder sync** to Azure Blob Storage (icons, images)
- Configurable via environment variables

## Quick Start

```yaml
version: "3.8"

services:
  uptime-kuma:
    image: ghcr.io/EdoardoTona/uptime-kuma-litestream:latest
    container_name: uptime-kuma
    ports:
      - "3001:3001"
    environment:
      # Azure Blob Storage configuration
      - AZURE_STORAGE_ACCOUNT=your_storage_account
      - AZURE_STORAGE_KEY=your_storage_key
      # Database backup settings
      - DB_BACKUP_ENABLED=true
      - DB_BACKUP_INTERVAL=5m
      - DB_FAIL_ON_RESTORE_ERROR=false
      - AZURE_BACKUP_CONTAINER=kuma-backup
      # Upload sync settings
      - UPLOAD_SYNC_ENABLED=true
      - UPLOAD_SYNC_INTERVAL=5m
      - AZURE_UPLOAD_CONTAINER=kuma-uploads
    volumes:
      # Optional: persist data locally as backup
      - uptime-kuma-data:/app/data
    restart: unless-stopped

volumes:
  uptime-kuma-data:
```

## Environment Variables

### Required

| Variable                | Description                      |
| ----------------------- | -------------------------------- |
| `AZURE_STORAGE_ACCOUNT` | Azure Storage account name       |
| `AZURE_STORAGE_KEY`     | Azure Storage account access key |

### Database Backup

| Variable                   | Default       | Description                                            |
| -------------------------- | ------------- | ------------------------------------------------------ |
| `DB_BACKUP_ENABLED`        | `true`        | Enable/disable database backup                         |
| `DB_BACKUP_INTERVAL`       | `5m`          | How often to backup (e.g., 5m, 1h, 30s)                |
| `DB_FAIL_ON_RESTORE_ERROR` | `false`       | Exit if restore fails (prevents overwriting remote DB) |
| `AZURE_BACKUP_CONTAINER`   | `kuma-backup` | Azure Blob container for database backup               |
| `AZURE_BACKUP_FILENAME`    | `kuma.db`     | Filename for the backup in Azure                       |

### Upload Sync

| Variable                 | Default        | Description                                |
| ------------------------ | -------------- | ------------------------------------------ |
| `UPLOAD_SYNC_ENABLED`    | `true`         | Enable/disable upload folder sync          |
| `UPLOAD_SYNC_INTERVAL`   | `5m`           | How often to sync uploads to Azure         |
| `AZURE_UPLOAD_CONTAINER` | `kuma-uploads` | Azure Blob container for uploads (icons)   |

## Azure Setup

1. Create an Azure Storage Account
2. Create two Blob Containers:
   - `kuma-backup` - for database backups
   - `kuma-uploads` - for uploaded icons/images
3. Get the Access Key from "Access keys" in the Storage Account settings

## How It Works

1. On container startup, the entrypoint script checks if backup is configured
2. If the database doesn't exist locally, it's restored from Azure Blob Storage
3. It restores the upload folder (icons/images) from Azure
4. An initial backup is created to ensure remote is in sync
5. Uptime-Kuma starts
6. Background processes run every 5 minutes (configurable):
   - Database backup using `sqlite3 .backup` (atomic, safe while DB is in use)
   - Upload folder sync to Azure
7. On container restart, both database and uploads are restored from Azure

## Building Locally

```bash
# Build with default versions
docker build -t uptime-kuma-litestream .

# Build with specific version
docker build \
  --build-arg UPTIME_KUMA_VERSION=2.0.2 \
  -t uptime-kuma-litestream .
```

## GitHub Container Registry

This image is automatically built and published to GitHub Container Registry on:

- Push to `main` branch
- Tagged releases (e.g., `v1.0.0`)
- Manual workflow dispatch

### Pull the image

```bash
docker pull ghcr.io/EdoardoTona/uptime-kuma-litestream:latest
```

### Available Tags

- `latest` - Latest build from main branch
- `kuma-2.0.2` - Tagged with Uptime-Kuma version
- `v1.0.0` - Semantic version tags
- `sha-xxxxxx` - Git commit SHA
