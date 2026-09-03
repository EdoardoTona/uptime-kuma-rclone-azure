# =============================================================================
# Uptime-Kuma + Keycloak/OIDC via oauth2-proxy
# SQLite backup to Azure Blob Storage via rclone
# =============================================================================

ARG UPTIME_KUMA_VERSION=2.5.3
ARG OAUTH2_PROXY_VERSION=7.15.4

# =============================================================================
# Stage 1: Download and prepare rclone
# =============================================================================
FROM alpine:3.19 AS tools

RUN apk add --no-cache wget unzip && \
    wget -q "https://downloads.rclone.org/rclone-current-linux-amd64.zip" -O /tmp/rclone.zip && \
    unzip -q /tmp/rclone.zip -d /tmp && \
    mv /tmp/rclone-*/rclone /usr/local/bin/rclone && \
    chmod +x /usr/local/bin/rclone

# =============================================================================
# Stage 2: Get oauth2-proxy binary (multi-arch image)
# =============================================================================
ARG OAUTH2_PROXY_VERSION
FROM quay.io/oauth2-proxy/oauth2-proxy:v${OAUTH2_PROXY_VERSION} AS oauth2proxy

# =============================================================================
# Stage 3: Final image based on official Uptime-Kuma
# =============================================================================
ARG UPTIME_KUMA_VERSION
FROM louislam/uptime-kuma:${UPTIME_KUMA_VERSION}

ARG UPTIME_KUMA_VERSION
ARG OAUTH2_PROXY_VERSION

LABEL org.opencontainers.image.title="Uptime-Kuma with Keycloak and SQLite Backup"
LABEL org.opencontainers.image.description="Uptime-Kuma protected by Keycloak/OIDC via oauth2-proxy, with SQLite backup to Azure Blob Storage via rclone"
LABEL org.opencontainers.image.version="${UPTIME_KUMA_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/YOUR_USERNAME/uptime-kuma-litestream"

# =============================================================================
# Uptime-Kuma / data
# =============================================================================
ENV UPTIME_KUMA_VERSION=${UPTIME_KUMA_VERSION} \
    DATA_DIR=/app/data \
    DB_PATH=/app/data/kuma.db

# Azure Blob Storage configuration (set secrets at runtime)
ENV AZURE_STORAGE_ACCOUNT="" \
    AZURE_STORAGE_KEY=""

# Database backup configuration
ENV DB_BACKUP_ENABLED=true \
    DB_BACKUP_INTERVAL=5m \
    DB_FAIL_ON_RESTORE_ERROR=false \
    AZURE_BACKUP_CONTAINER=kuma-backup \
    AZURE_BACKUP_FILENAME=kuma.db

# Upload sync configuration
ENV UPLOAD_SYNC_ENABLED=true \
    UPLOAD_SYNC_INTERVAL=5m \
    AZURE_UPLOAD_CONTAINER=kuma-uploads

# =============================================================================
# External authentication
# =============================================================================
# When enabled:
#   - Uptime-Kuma only listens on 127.0.0.1:3002
#   - oauth2-proxy listens on :3001
#   - Kuma's built-in authentication is bypassed at runtime (DB is untouched)
#
# Required runtime secrets/config:
#   OAUTH2_PROXY_OIDC_ISSUER_URL=https://keycloak.example/realms/<realm>
#   OAUTH2_PROXY_CLIENT_ID=<client-id>
#   OAUTH2_PROXY_CLIENT_SECRET=<client-secret>
#   OAUTH2_PROXY_COOKIE_SECRET=<persistent random secret>
# Recommended:
#   OAUTH2_PROXY_REDIRECT_URL=https://status.example.com/oauth2/callback
# Optional Keycloak authorization:
#   OAUTH2_PROXY_ALLOWED_ROLES=<realm-role> or <client-id>:<client-role>
ENV KUMA_EXTERNAL_AUTH=true \
    KUMA_INTERNAL_HOST=127.0.0.1 \
    KUMA_INTERNAL_PORT=3002 \
    OAUTH2_PROXY_PROVIDER=keycloak-oidc \
    OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:3001 \
    OAUTH2_PROXY_UPSTREAMS=http://127.0.0.1:3002/ \
    OAUTH2_PROXY_EMAIL_DOMAINS=* \
    OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true \
    OAUTH2_PROXY_PROXY_WEBSOCKETS=true \
    OAUTH2_PROXY_COOKIE_SECURE=true \
    OAUTH2_PROXY_COOKIE_HTTPONLY=true \
    OAUTH2_PROXY_COOKIE_SAMESITE=lax \
    OAUTH2_PROXY_COOKIE_NAME=__Host-uptime_kuma \
    OAUTH2_PROXY_SKIP_AUTH_ROUTES="GET=^/$,GET=^/status(/.*)?$,GET=^/status-page$,GET=^/api/status-page(/.*)?$,GET=^/api/entry-page$,GET=^/assets(/.*)?$,GET=^/upload(/.*)?$,GET=^/(icon\\.svg|apple-touch-icon\\.png|manifest\\.json|favicon\\.ico|robots\\.txt)$"

USER root

# sqlite3: online-safe backup; curl: health check; ca-certificates: Keycloak TLS
RUN apt-get update && \
    apt-get install -y --no-install-recommends sqlite3 curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=tools /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=oauth2proxy /bin/oauth2-proxy /usr/local/bin/oauth2-proxy

# Patch Settings.get() so external authentication can disable Kuma auth and
# trust forwarded headers without persisting those changes in kuma.db.
# Build fails deliberately if the expected 2.5.3 source marker changes.
RUN node -e 'const fs=require("fs"); const f="/app/server/settings.js"; let s=fs.readFileSync(f,"utf8"); const m="    static async get(key) {\n"; const r="    static async get(key) {\n        // Image-level external authentication override.\n        // oauth2-proxy is the security boundary; never expose Kuma internal port.\n        if (process.env.KUMA_EXTERNAL_AUTH === \"true\") {\n            if (key === \"disableAuth\" || key === \"trustProxy\") {\n                return true;\n            }\n        }\n"; if (!s.includes(m)) throw new Error("Unable to patch /app/server/settings.js: expected marker not found"); fs.writeFileSync(f,s.replace(m,r));'

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p ${DATA_DIR}

# Only oauth2-proxy is externally exposed. Kuma itself stays on localhost:3002.
EXPOSE 3001

# Check the correct service topology in both proxy and direct modes.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD if [ "${KUMA_EXTERNAL_AUTH}" = "true" ]; then \
            curl -fsS http://127.0.0.1:3001/ping >/dev/null && \
            curl -fsS http://127.0.0.1:3002/setup-database-info >/dev/null; \
        else \
            curl -fsS http://127.0.0.1:3001/setup-database-info >/dev/null; \
        fi || exit 1

ENTRYPOINT ["/entrypoint.sh"]
