#!/bin/sh
# sni-scan.sh
# Block 2: Поиск оптимального SNI для прокси через реальный туннель Mihomo.
#
# Тест идёт через Mihomo SOCKS5 — результат честный,
# т.к. трафик проходит через само прокси-соединение.
#
# Настройка через UCI: uci set cf_optimizer.main.KEY=VALUE

LOG_TAG="sni-scan"
STATUS_FILE="/var/run/cf-optimizer.status"
LOCK_FILE="/var/run/sni-scan.lock"

# --- Читаем конфиг из UCI ---
ENABLED=$(uci -q get cf_optimizer.main.sni_scanner_enabled)
[ "$ENABLED" != "1" ] && exit 0

PROXY_NAME=$(uci -q get cf_optimizer.main.proxy_name)
MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)
MIHOMO_SOCKS=$(uci -q get cf_optimizer.main.mihomo_socks)
CONFIG_FILE=$(uci -q get cf_optimizer.main.mihomo_config)

PROXY_NAME="${PROXY_NAME:-YOUR_PROXY_NAME}"
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
MIHOMO_SOCKS="${MIHOMO_SOCKS:-127.0.0.1:7891}"
CONFIG_FILE="${CONFIG_FILE:-/opt/clash/config.yaml}"

# --- Защита от параллельного запуска (PID-based stale detection) ---
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        logger -t "$LOG_TAG" "Already running (PID=$lock_pid), skipping"
        exit 0
    fi
    logger -t "$LOG_TAG" "Stale lock found (PID=${lock_pid:-?} dead), removing"
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

logger -t "$LOG_TAG" "Starting SNI scan via Mihomo SOCKS5 ($MIHOMO_SOCKS)"

AUTH_HEADER=""
[ -n "$MIHOMO_SECRET" ] && AUTH_HEADER="Authorization: Bearer $MIHOMO_SECRET"

# --- Список SNI для тестирования ---
# Популярные домены за Cloudflare CDN
SNI_LIST="
cloudflare.com
cdn.cloudflare.com
workers.dev
pages.dev
cloudflaressl.com
"

# --- Тестируем каждый SNI через Mihomo SOCKS5 ---
BEST_SNI=""
BEST_TIME=99999

for SNI in $SNI_LIST; do
    [ -z "$SNI" ] && continue

    # Обновляем SNI в прокси через Mihomo API
    if [ -n "$AUTH_HEADER" ]; then
        curl -sf -X PATCH "${MIHOMO_API}/proxies/${PROXY_NAME}" \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "{\"sni\": \"${SNI}\"}" > /dev/null 2>&1
    else
        curl -sf -X PATCH "${MIHOMO_API}/proxies/${PROXY_NAME}" \
            -H "Content-Type: application/json" \
            -d "{\"sni\": \"${SNI}\"}" > /dev/null 2>&1
    fi

    # Небольшая пауза для применения
    sleep 0.5

    # Тест через реальный туннель Mihomo (SOCKS5)
    T=$(curl -sf -o /dev/null -w "%{time_connect}" \
        --socks5 "$MIHOMO_SOCKS" \
        --connect-timeout 4 \
        --max-time 5 \
        "https://cp.cloudflare.com/generate_204" 2>/dev/null \
        | awk '{printf "%d", $1 * 1000}')

    [ -z "$T" ] && T=99999

    logger -t "$LOG_TAG" "  SNI ${SNI}: ${T}ms"

    if [ "$T" -lt "$BEST_TIME" ] 2>/dev/null; then
        BEST_TIME=$T
        BEST_SNI=$SNI
    fi

    # Пауза между тестами (щадящий режим)
    sleep 1
done

if [ -z "$BEST_SNI" ] || [ "$BEST_TIME" -ge 9000 ] 2>/dev/null; then
    logger -t "$LOG_TAG" "No working SNI found, keeping current"
    exit 0
fi

logger -t "$LOG_TAG" "Best SNI: $BEST_SNI (${BEST_TIME}ms)"

# --- Применяем лучший SNI через awk в config.yaml ---
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.sni.bak"

    awk -v name="$PROXY_NAME" -v sni="$BEST_SNI" '
        /^  - name:/ {
            in_target = (index($0, name) > 0)
        }
        in_target && /^    sni:/ {
            print "    sni: " sni
            next
        }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

    if [ -s "${CONFIG_FILE}.tmp" ]; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        rm -f "${CONFIG_FILE}.tmp"
    fi

    # Graceful hot-reload
    RELOAD_BODY="{\"path\": \"${CONFIG_FILE}\"}"
    if [ -n "$AUTH_HEADER" ]; then
        curl -sf -X PUT "${MIHOMO_API}/configs?force=false" \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "$RELOAD_BODY" > /dev/null 2>&1
    else
        curl -sf -X PUT "${MIHOMO_API}/configs?force=false" \
            -H "Content-Type: application/json" \
            -d "$RELOAD_BODY" > /dev/null 2>&1
    fi

    logger -t "$LOG_TAG" "Config updated: sni → $BEST_SNI"
fi

# --- Обновляем статус ---
if [ -f "$STATUS_FILE" ]; then
    sed -i "s/^CURRENT_SNI=.*/CURRENT_SNI=$BEST_SNI/" "$STATUS_FILE" 2>/dev/null \
        || echo "CURRENT_SNI=$BEST_SNI" >> "$STATUS_FILE"
else
    echo "CURRENT_SNI=$BEST_SNI" > "$STATUS_FILE"
fi

logger -t "$LOG_TAG" "Done."
