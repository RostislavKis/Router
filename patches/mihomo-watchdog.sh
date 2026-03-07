#!/bin/sh
# mihomo-watchdog.sh
# Monitors Mihomo health and restarts /etc/init.d/clash if unresponsive.
#
# Checks:
#   1. GET /version — basic API health
#   2. GET /proxies — proxy list reachable
#
# Restart policy: 2 consecutive failures → restart clash service.
# Does NOT change any proxy selections (GEMINI/Main stay untouched).
#
# UCI settings:
#   uci set cf_optimizer.main.watchdog_enabled=1
#   uci commit cf_optimizer
#
# Cron (every 10 min):
#   */10 * * * * /usr/local/bin/mihomo-watchdog.sh >> /var/log/mihomo-watchdog.log 2>&1

LOG_TAG="mihomo-watchdog"
STATUS_FILE="/var/run/mihomo-watchdog.status"
FAIL_FILE="/var/run/mihomo-watchdog.fails"

ENABLED=$(uci -q get cf_optimizer.main.watchdog_enabled)
[ "$ENABLED" != "1" ] && exit 0

MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"

AUTH_HEADER=""
[ -n "$MIHOMO_SECRET" ] && AUTH_HEADER="Authorization: Bearer $MIHOMO_SECRET"

# ----------------------------------------------------------------
# Check 1: API version endpoint
# ----------------------------------------------------------------
check_api() {
    if [ -n "$AUTH_HEADER" ]; then
        curl -sf --max-time 5 -H "$AUTH_HEADER" "${MIHOMO_API}/version" >/dev/null 2>&1
    else
        curl -sf --max-time 5 "${MIHOMO_API}/version" >/dev/null 2>&1
    fi
}

# ----------------------------------------------------------------
# Check 2: Proxy list endpoint (confirms Mihomo is fully loaded)
# ----------------------------------------------------------------
check_proxies() {
    local resp
    if [ -n "$AUTH_HEADER" ]; then
        resp=$(curl -sf --max-time 8 -H "$AUTH_HEADER" \
            "${MIHOMO_API}/proxies" 2>/dev/null | head -c 50)
    else
        resp=$(curl -sf --max-time 8 "${MIHOMO_API}/proxies" 2>/dev/null | head -c 50)
    fi
    [ -n "$resp" ]
}

# ----------------------------------------------------------------
# Main logic
# ----------------------------------------------------------------
NOW=$(date '+%Y-%m-%d %H:%M:%S')

if check_api && check_proxies; then
    # Healthy — clear fail counter
    logger -t "$LOG_TAG" "Mihomo healthy"
    rm -f "$FAIL_FILE"
    {
        echo "WATCHDOG_LAST_CHECK=${NOW}"
        echo "WATCHDOG_STATUS=healthy"
        echo "WATCHDOG_FAILS=0"
    } > "$STATUS_FILE"
    exit 0
fi

# Not healthy — increment fail counter
fails=0
[ -f "$FAIL_FILE" ] && fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
fails=$((fails + 1))
echo "$fails" > "$FAIL_FILE"

logger -t "$LOG_TAG" "WARNING: Mihomo not responding (fail #${fails}/2)"
{
    echo "WATCHDOG_LAST_CHECK=${NOW}"
    echo "WATCHDOG_STATUS=warning"
    echo "WATCHDOG_FAILS=${fails}"
} > "$STATUS_FILE"

# Restart after 2 consecutive failures
if [ "$fails" -ge 2 ]; then
    logger -t "$LOG_TAG" "ERROR: Mihomo unresponsive x2 — restarting clash service"
    {
        echo "WATCHDOG_LAST_CHECK=${NOW}"
        echo "WATCHDOG_STATUS=restarting"
        echo "WATCHDOG_FAILS=${fails}"
    } > "$STATUS_FILE"

    /etc/init.d/clash restart 2>/dev/null || true

    # Wait up to 30s for recovery
    i=0
    while [ $i -lt 6 ]; do
        sleep 5
        i=$((i + 1))
        check_api && break
    done

    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    if check_api; then
        logger -t "$LOG_TAG" "Mihomo recovered after restart"
        rm -f "$FAIL_FILE"
        {
            echo "WATCHDOG_LAST_CHECK=${NOW}"
            echo "WATCHDOG_STATUS=recovered"
            echo "WATCHDOG_FAILS=0"
        } > "$STATUS_FILE"
    else
        logger -t "$LOG_TAG" "ERROR: Mihomo still not responding after restart"
        {
            echo "WATCHDOG_LAST_CHECK=${NOW}"
            echo "WATCHDOG_STATUS=failed"
            echo "WATCHDOG_FAILS=${fails}"
        } > "$STATUS_FILE"
    fi
fi
