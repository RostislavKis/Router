#!/bin/sh
# geo-update.sh
# Downloads fresh Mihomo geo databases and hot-reloads config.
#
# Files updated:
#   geoip.dat, geosite.dat, country.mmdb  (MetaCubeX latest release)
#
# UCI settings:
#   uci set cf_optimizer.main.geo_update_enabled=1
#   uci set cf_optimizer.main.mihomo_config=/opt/clash/config.yaml
#   uci commit cf_optimizer
#
# Run weekly from cron (Sunday 04:00):
#   0 4 * * 0 /usr/local/bin/geo-update.sh >> /var/log/geo-update.log 2>&1

LOG_TAG="geo-update"

ENABLED=$(uci -q get cf_optimizer.main.geo_update_enabled)
[ "$ENABLED" != "1" ] && exit 0

MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)
MIHOMO_CONFIG=$(uci -q get cf_optimizer.main.mihomo_config)

MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
MIHOMO_CONFIG="${MIHOMO_CONFIG:-/opt/clash/config.yaml}"

# Geo files live alongside config.yaml
MIHOMO_DATA=$(dirname "$MIHOMO_CONFIG")

AUTH_HEADER=""
[ -n "$MIHOMO_SECRET" ] && AUTH_HEADER="Authorization: Bearer $MIHOMO_SECRET"

logger -t "$LOG_TAG" "Starting geo database update (data dir: ${MIHOMO_DATA})"

# ----------------------------------------------------------------
# Download with retry (3 attempts)
# ----------------------------------------------------------------
download_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"

    if curl -sL --max-time 120 --retry 3 --retry-delay 10 -o "$tmp" "$url" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            mv "$tmp" "$dest"
            logger -t "$LOG_TAG" "OK: $(basename "$dest") ($(wc -c < "$dest") bytes)"
            return 0
        fi
    fi
    rm -f "$tmp"
    logger -t "$LOG_TAG" "FAIL: $(basename "$dest")"
    return 1
}

GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"

updated=0
download_file "$GEOIP_URL"   "${MIHOMO_DATA}/geoip.dat"   && updated=1
download_file "$GEOSITE_URL" "${MIHOMO_DATA}/geosite.dat" && updated=1
download_file "$MMDB_URL"    "${MIHOMO_DATA}/country.mmdb"

# ----------------------------------------------------------------
# Restart Mihomo to load new geo databases (API hot-reload does not
# reload geo data — it is parsed only at startup).
# cf-optimizer restarts afterwards to resume latency-monitor and Xray.
# ----------------------------------------------------------------
if [ "$updated" = "1" ]; then
    logger -t "$LOG_TAG" "Restarting Mihomo to apply new geo databases"
    /etc/init.d/clash restart 2>/dev/null || true
    sleep 15
    /etc/init.d/cf-optimizer restart 2>/dev/null || true
    logger -t "$LOG_TAG" "Mihomo restarted, cf-optimizer resumed"
fi

logger -t "$LOG_TAG" "Geo update complete"
