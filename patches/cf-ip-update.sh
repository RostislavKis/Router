#!/bin/sh
# cf-ip-update.sh
# Block 1: Автоматический поиск лучшего Cloudflare edge IP для Mihomo.
#
# Режим работы:
#   - Щадящий: последовательные тесты, sleep между запросами
#   - Обновляет прокси только если новый IP быстрее на THRESHOLD%
#   - Graceful hot-reload Mihomo (PUT /configs, force=false — без дропа соединений)
#   - Не перезапускает SSClash
#
# Настройка через UCI: uci set cf_optimizer.main.KEY=VALUE
#
# Вручную: /usr/local/bin/cf-ip-update.sh

LOG_TAG="cf-ip-update"
STATUS_FILE="/var/run/cf-optimizer.status"
LOCK_FILE="/var/run/cf-ip-update.lock"

# --- Читаем конфиг из UCI ---
ENABLED=$(uci -q get cf_optimizer.main.ip_updater_enabled)
[ "$ENABLED" != "1" ] && exit 0

WORKER_URL=$(uci -q get cf_optimizer.main.worker_url)
REGIONS=$(uci -q get cf_optimizer.main.regions)
PROXY_NAME=$(uci -q get cf_optimizer.main.proxy_name)
MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)
CONFIG_FILE=$(uci -q get cf_optimizer.main.mihomo_config)
THRESHOLD=$(uci -q get cf_optimizer.main.update_threshold)
LIMIT=$(uci -q get cf_optimizer.main.limit_per_region)

# Значения по умолчанию
WORKER_URL="${WORKER_URL:-https://YOUR_WORKER.workers.dev}"
REGIONS="${REGIONS:-FI,DE,NL}"
PROXY_NAME="${PROXY_NAME:-YOUR_PROXY_NAME}"
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
CONFIG_FILE="${CONFIG_FILE:-/opt/clash/config.yaml}"
THRESHOLD="${THRESHOLD:-20}"
LIMIT="${LIMIT:-10}"

# --- Защита от параллельного запуска ---
if [ -f "$LOCK_FILE" ]; then
    logger -t "$LOG_TAG" "Already running, skipping"
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

logger -t "$LOG_TAG" "Starting IP update (regions: $REGIONS, limit: $LIMIT)"

# --- Заголовок авторизации для Mihomo API ---
AUTH_HEADER=""
[ -n "$MIHOMO_SECRET" ] && AUTH_HEADER="Authorization: Bearer $MIHOMO_SECRET"

# --- Получаем текущий IP прокси (для сравнения) ---
CURRENT_TIME=99999
if [ -f "$STATUS_FILE" ]; then
    CURRENT_TIME=$(grep '^CURRENT_PING=' "$STATUS_FILE" | cut -d= -f2)
    CURRENT_TIME="${CURRENT_TIME:-99999}"
fi

# --- Шаг 1: Получить список IP от Worker API ---
logger -t "$LOG_TAG" "Fetching CF edge IPs from Worker API..."

IP_LIST=$(curl -sf --max-time 15 \
    "${WORKER_URL}?api=1&region=${REGIONS}&format=line&limit=${LIMIT}" \
    2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$')

if [ -z "$IP_LIST" ]; then
    logger -t "$LOG_TAG" "ERROR: Failed to fetch IP list from Worker API"
    exit 1
fi

IP_COUNT=$(echo "$IP_LIST" | wc -l)
logger -t "$LOG_TAG" "Got $IP_COUNT IPs to test"

# --- Шаг 2: TCP-тест каждого IP (щадящий режим) ---
BEST_IP=""
BEST_PORT=""
BEST_TIME=99999

for ENTRY in $IP_LIST; do
    IP=$(echo "$ENTRY" | cut -d: -f1)
    PORT=$(echo "$ENTRY" | cut -d: -f2)

    # TCP ping: время соединения в мс (--connect-timeout 3 — щадящий режим)
    T=$(curl -sf -o /dev/null -w "%{time_connect}" \
        --connect-timeout 3 \
        --max-time 4 \
        -k "https://${IP}:${PORT}" 2>/dev/null \
        | awk '{printf "%d", $1 * 1000}')

    [ -z "$T" ] && T=99999

    logger -t "$LOG_TAG" "  ${IP}:${PORT} → ${T}ms"

    if [ "$T" -lt "$BEST_TIME" ] 2>/dev/null; then
        BEST_TIME=$T
        BEST_IP=$IP
        BEST_PORT=$PORT
    fi

    # Щадящий режим: пауза между тестами
    sleep 0.5
done

if [ -z "$BEST_IP" ] || [ "$BEST_TIME" -ge 9000 ] 2>/dev/null; then
    logger -t "$LOG_TAG" "ERROR: No reachable CF IP found"
    exit 1
fi

logger -t "$LOG_TAG" "Best IP: ${BEST_IP}:${BEST_PORT} (${BEST_TIME}ms)"

# --- Шаг 3: Проверяем порог улучшения ---
if [ "$CURRENT_TIME" -lt 9000 ] 2>/dev/null; then
    # Считаем: стоит ли обновлять (нужно улучшение >= THRESHOLD%)
    MIN_IMPROVEMENT=$(( CURRENT_TIME * (100 - THRESHOLD) / 100 ))
    if [ "$BEST_TIME" -ge "$MIN_IMPROVEMENT" ] && [ "$CURRENT_TIME" -lt "$BEST_TIME" ]; then
        logger -t "$LOG_TAG" "Current IP ($CURRENT_TIME ms) is already within threshold. Skipping update."
        # Обновляем статус без смены IP
        sed -i "s/^LAST_CHECK=.*/LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')/" "$STATUS_FILE" 2>/dev/null
        exit 0
    fi
fi

# --- Шаг 4: Обновляем server в config.yaml ---
if [ ! -f "$CONFIG_FILE" ]; then
    logger -t "$LOG_TAG" "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Backup
cp "$CONFIG_FILE" "${CONFIG_FILE}.cf-optimizer.bak"

# Awk-замена server и port под нужным proxy name (точное совпадение)
awk -v name="$PROXY_NAME" -v server="$BEST_IP" -v port="$BEST_PORT" '
    /^  - name:/ {
        in_target = (index($0, name) > 0)
    }
    in_target && /^    server:/ {
        print "    server: " server
        next
    }
    in_target && /^    port:/ && port != "" {
        print "    port: " port
        next
    }
    { print }
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

# Проверяем что файл не пустой перед заменой
if [ -s "${CONFIG_FILE}.tmp" ]; then
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    logger -t "$LOG_TAG" "Config updated: server → ${BEST_IP}:${BEST_PORT}"
else
    logger -t "$LOG_TAG" "ERROR: awk produced empty output, keeping original"
    rm -f "${CONFIG_FILE}.tmp"
    exit 1
fi

# --- Шаг 5: Graceful hot-reload Mihomo (без дропа соединений) ---
RELOAD_BODY="{\"path\": \"${CONFIG_FILE}\"}"

if [ -n "$AUTH_HEADER" ]; then
    RELOAD_RESULT=$(curl -sf -X PUT "${MIHOMO_API}/configs?force=false" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "$RELOAD_BODY" \
        -w "%{http_code}" -o /dev/null 2>/dev/null)
else
    RELOAD_RESULT=$(curl -sf -X PUT "${MIHOMO_API}/configs?force=false" \
        -H "Content-Type: application/json" \
        -d "$RELOAD_BODY" \
        -w "%{http_code}" -o /dev/null 2>/dev/null)
fi

if [ "$RELOAD_RESULT" = "204" ] || [ "$RELOAD_RESULT" = "200" ]; then
    logger -t "$LOG_TAG" "Mihomo hot-reload: OK (${RELOAD_RESULT})"
else
    logger -t "$LOG_TAG" "WARNING: Mihomo reload returned ${RELOAD_RESULT}"
fi

# --- Шаг 6: Записываем статус ---
cat > "$STATUS_FILE" << EOF
LAST_UPDATE=$(date '+%Y-%m-%d %H:%M:%S')
LAST_CHECK=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_IP=$BEST_IP
CURRENT_PORT=$BEST_PORT
CURRENT_PING=$BEST_TIME
IP_UPDATER=active
EOF

logger -t "$LOG_TAG" "Done. ${BEST_IP}:${BEST_PORT} (${BEST_TIME}ms)"
