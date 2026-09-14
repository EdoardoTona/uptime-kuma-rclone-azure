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

# Extra backup triggered by configuration changes, on top of DB_BACKUP_INTERVAL.
# The entrypoint fingerprints the config tables (monitors, notifications, status
# pages, maintenance, settings) and backs up as soon as they change, so an edit
# made from the UI is not exposed to a whole DB_BACKUP_INTERVAL of data loss.
# Heartbeat traffic does not move the fingerprint, so an idle instance still
# uploads only on the periodic schedule.
ENV DB_CONFIG_WATCH_ENABLED=true \
    DB_CONFIG_WATCH_INTERVAL=30s \
    DB_CONFIG_WATCH_MIN_INTERVAL=60s

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
    OAUTH2_PROXY_SKIP_AUTH_ROUTES="GET=^/$,GET=^/status(/.*)?$,GET=^/status-page$,GET=^/api/status-page(/.*)?$,GET=^/api/entry-page$,GET=^/api/push(/.*)?$,GET=^/assets(/.*)?$,GET=^/upload(/.*)?$,GET=^/(icon\\.svg|apple-touch-icon\\.png|manifest\\.json|favicon\\.ico|robots\\.txt)$"

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

# Patch UptimeCalculator so a failed stat INSERT cannot poison the process.
#
# Problem (upstream, present in 2.5.x): getDailyStatBean/getHourlyStatBean/
# getMinutelyStatBean cache the last bean and short-circuit on the timestamp
# alone, without re-reading the DB. R.store() assigns the row id to that very
# object, so when an INSERT fails the cached bean keeps id = 0 and every later
# update() of the same bucket retries the same doomed INSERT until the process
# restarts. Since the whole /api/push handler is wrapped in a try/catch that
# answers 404, one failed INSERT turns every subsequent push into a 404 and the
# monitor goes down for good.
#
# How the INSERT fails in the first place: update() is called both by the
# monitor beat loop and by the /api/push HTTP handler. For a push monitor these
# two run concurrently, so at a bucket rollover both can miss the row, both
# dispense a new bean, and the second store() hits
# "UNIQUE constraint failed: stat_daily.monitor_id, stat_daily.timestamp".
# Any other transient write failure (e.g. SQLITE_BUSY) has the same effect.
#
# The fix: only trust the cached bean once it has actually been persisted
# (id != 0). After a failed INSERT the next update() re-reads the row, finds the
# one already written by the concurrent writer, and UPDATEs it instead — the
# calculator heals itself. In the normal path store() sets the id on the cached
# object right away, so this costs no extra query. It does not remove the race
# itself: one heartbeat can still be lost per collision, it just stops being
# permanent.
#
# Build fails deliberately if the expected 2.5.3 source marker changes.
RUN node -e 'const fs=require("fs"); const f="/app/server/uptime-calculator.js"; let s=fs.readFileSync(f,"utf8"); for (const k of ["lastDailyStatBean","lastHourlyStatBean","lastMinutelyStatBean"]) { const m=`if (this.${k} && this.${k}.timestamp === timestamp) {`; const r=`if (this.${k} && this.${k}.id && this.${k}.timestamp === timestamp) {`; if (!s.includes(m)) throw new Error("Unable to patch /app/server/uptime-calculator.js: expected marker not found for " + k); s=s.split(m).join(r); } fs.writeFileSync(f,s);'

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
