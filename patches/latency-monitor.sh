#!/bin/sh
# latency-monitor.sh
# Group-aware latency monitor for Mihomo proxy groups.
#
# GEMINI (select group):
#   - Tests ONLY proxies that belong to the GEMINI selector
#   - Reads proxy list from Mihomo API — no hardcoding
#   - Switches to the fastest one via PUT /proxies/{group}
#   - Hysteresis: only switches if new proxy is faster by switch_threshold% or more
#   - Runs independently, never touches other groups
#
# PrvtVPN All Auto (url-test group):
#   - Mihomo auto-manages it — we only read and log current selection
#
# Persistent status: saved to /etc/cf-optimizer.status (flash) on each switch.
# On boot, init script restores it to /var/run/ so LuCI shows last known state.
#
# UCI settings:
#   uci set cf_optimizer.main.latency_enabled=1
#   uci set cf_optimizer.main.switch_threshold=20   # % below which we skip switch
#   uci set cf_optimizer.main.gemini_group='🤖 GEMINI'
#   uci set cf_optimizer.main.main_group='PrvtVPN All Auto'
#   uci commit cf_optimizer

LOG_TAG="latency-monitor"
STATUS_FILE="/var/run/latency-monitor.status"
PERSISTENT_STATUS="/etc/cf-optimizer.status"
LOCK_FILE="/var/run/latency-monitor.lock"

# --- UCI config ---
ENABLED=$(uci -q get cf_optimizer.main.latency_enabled)
[ "$ENABLED" != "1" ] && exit 0

MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)
GEMINI_GROUP=$(uci -q get cf_optimizer.main.gemini_group)
MAIN_GROUP=$(uci -q get cf_optimizer.main.main_group)
SWITCH_THRESHOLD=$(uci -q get cf_optimizer.main.switch_threshold)

MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
GEMINI_GROUP="${GEMINI_GROUP:-🤖 GEMINI}"
MAIN_GROUP="${MAIN_GROUP:-PrvtVPN All Auto}"
SWITCH_THRESHOLD="${SWITCH_THRESHOLD:-20}"

# --- Lock ---
if [ -f "$LOCK_FILE" ]; then
    logger -t "$LOG_TAG" "Already running, skipping"
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

AUTH_HEADER=""
[ -n "$MIHOMO_SECRET" ] && AUTH_HEADER="Authorization: Bearer $MIHOMO_SECRET"

# ================================================================
# Helpers
# ================================================================

# URL encode a string — UTF-8 safe (handles emoji, Cyrillic, spaces)
# Uses hexdump -C (busybox-compatible) + awk; no od/xxd needed.
urlencode() {
    printf '%s' "$1" | hexdump -v -C | \
        awk '{ for(i=2;i<=NF;i++) if($i~/^[0-9a-f][0-9a-f]$/) printf "%%%s",toupper($i) } END{printf "\n"}'
}

# GET /proxies/{encoded_path}
mihomo_get() {
    local path="$1"
    if [ -n "$AUTH_HEADER" ]; then
        curl -sf --max-time 8 -H "$AUTH_HEADER" "${MIHOMO_API}${path}" 2>/dev/null
    else
        curl -sf --max-time 8 "${MIHOMO_API}${path}" 2>/dev/null
    fi
}

# PUT /proxies/{encoded_path} with JSON body
mihomo_put() {
    local path="$1"
    local body="$2"
    if [ -n "$AUTH_HEADER" ]; then
        curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "$body" -w "%{http_code}" -o /dev/null \
            --max-time 5 "${MIHOMO_API}${path}" 2>/dev/null
    else
        curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -d "$body" -w "%{http_code}" -o /dev/null \
            --max-time 5 "${MIHOMO_API}${path}" 2>/dev/null
    fi
}

# Test a single proxy latency via Mihomo delay API.
# Mihomo tests the proxy internally — no traffic goes through it,
# the group selection is NOT changed during this call.
# Returns delay in ms, or 9999 on timeout/error.
get_proxy_delay() {
    local proxy_name="$1"
    local timeout_ms="${2:-5000}"
    local test_url="http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204"
    local encoded
    encoded=$(urlencode "$proxy_name")

    local response
    response=$(mihomo_get "/proxies/${encoded}/delay?url=${test_url}&timeout=${timeout_ms}")

    if [ -z "$response" ]; then
        echo 9999
        return
    fi

    # Parse {"delay": 123} — extract number after "delay":
    echo "$response" | awk -F'"delay":' '
        NF > 1 {
            val = $2
            gsub(/[^0-9]/, "", val)
            print val + 0
            exit
        }
        END { if (NR == 0) print 9999 }
    '
}

# Get all proxy names in a group from Mihomo API.
# Works by parsing the "all" JSON array from /proxies/{group}.
get_group_proxies() {
    local group_name="$1"
    local encoded
    encoded=$(urlencode "$group_name")

    local info
    info=$(mihomo_get "/proxies/${encoded}")
    [ -z "$info" ] && return 1

    # Extract the "all":["name1","name2",...] array
    echo "$info" | awk '
        BEGIN { RS=""; FS="" }
        {
            if (match($0, /"all":\[[^]]*\]/)) {
                chunk = substr($0, RSTART, RLENGTH)
                sub(/"all":\[/, "", chunk)
                sub(/\].*/, "", chunk)
                n = split(chunk, parts, /","/)
                for (i = 1; i <= n; i++) {
                    name = parts[i]
                    gsub(/^[[:space:]]*"?/, "", name)
                    gsub(/"?[[:space:]]*$/, "", name)
                    if (length(name) > 0) print name
                }
            }
        }
    '
}

# Get the currently active ("now") proxy in a group
get_group_current() {
    local group_name="$1"
    local encoded
    encoded=$(urlencode "$group_name")

    local info
    info=$(mihomo_get "/proxies/${encoded}")
    [ -z "$info" ] && return 1

    echo "$info" | awk -F'"now":"' '
        NF > 1 {
            val = $2
            sub(/".*/, "", val)
            print val
            exit
        }
    '
}

# Switch the active proxy in a SELECT group
switch_group() {
    local group_name="$1"
    local proxy_name="$2"
    local encoded_group
    encoded_group=$(urlencode "$group_name")

    local escaped
    escaped=$(printf '%s' "$proxy_name" | sed 's/\\/\\\\/g; s/"/\\"/g')

    mihomo_put "/proxies/${encoded_group}" "{\"name\": \"${escaped}\"}"
}

# ================================================================
# BLOCK A: GEMINI group — test & switch with hysteresis
# ================================================================
# Hysteresis prevents unnecessary proxy switches for Gemini/NotebookLM.
# A switch happens only when the best proxy is faster than the current
# proxy by at least SWITCH_THRESHOLD percent.
# Example: current=150ms, threshold=20% → switch only if best < 120ms.
# ================================================================
optimize_gemini() {
    logger -t "$LOG_TAG" "=== GEMINI group: ${GEMINI_GROUP} (threshold=${SWITCH_THRESHOLD}%) ==="

    # Get proxy list from Mihomo API (not hardcoded)
    local proxies
    proxies=$(get_group_proxies "$GEMINI_GROUP")

    if [ -z "$proxies" ]; then
        logger -t "$LOG_TAG" "GEMINI: failed to get proxy list from Mihomo API"
        echo "GEMINI_STATUS=api_error" >> "$STATUS_FILE"
        return 1
    fi

    # Read current active proxy before testing
    local current_proxy
    current_proxy=$(get_group_current "$GEMINI_GROUP")
    logger -t "$LOG_TAG" "GEMINI: current='${current_proxy:-none}'"

    local proxy_count
    proxy_count=$(echo "$proxies" | wc -l)
    logger -t "$LOG_TAG" "GEMINI: testing ${proxy_count} proxies"

    local best_proxy=""
    local best_delay=9999
    local current_delay=9999
    local tested=0

    while IFS= read -r proxy; do
        [ -z "$proxy" ] && continue

        local delay
        delay=$(get_proxy_delay "$proxy" 5000)
        tested=$((tested + 1))

        logger -t "$LOG_TAG" "  [GEMINI] $(printf '%-50s' "$proxy") ${delay}ms"

        # Track current proxy delay separately
        [ "$proxy" = "$current_proxy" ] && current_delay=$delay

        if [ "$delay" -lt "$best_delay" ] 2>/dev/null; then
            best_delay=$delay
            best_proxy=$proxy
        fi

        sleep 1
    done << PROXYEOF
$proxies
PROXYEOF

    logger -t "$LOG_TAG" "GEMINI: tested=${tested}, best='${best_proxy}'(${best_delay}ms), current='${current_proxy}'(${current_delay}ms)"

    if [ -z "$best_proxy" ] || [ "$best_delay" -ge 9000 ] 2>/dev/null; then
        logger -t "$LOG_TAG" "GEMINI: no reachable proxy found (all timed out)"
        echo "GEMINI_STATUS=all_timeout" >> "$STATUS_FILE"
        return
    fi

    if [ "$best_proxy" = "$current_proxy" ]; then
        # Already on the best proxy — no switch needed
        logger -t "$LOG_TAG" "GEMINI: already optimal, keeping '${best_proxy}' (${best_delay}ms)"
        {
            echo "GEMINI_PROXY=${best_proxy}"
            echo "GEMINI_DELAY=${best_delay}ms"
            echo "GEMINI_STATUS=ok"
        } >> "$STATUS_FILE"
        return
    fi

    # Hysteresis check: only switch if best is faster by >= SWITCH_THRESHOLD%
    # threshold_delay = current_delay * (100 - threshold) / 100
    local threshold_delay
    if [ "$current_delay" -lt 9000 ] 2>/dev/null; then
        threshold_delay=$(awk "BEGIN { printf \"%d\", $current_delay * (100 - $SWITCH_THRESHOLD) / 100 }")
        logger -t "$LOG_TAG" "GEMINI: switch threshold = ${threshold_delay}ms (${SWITCH_THRESHOLD}% below ${current_delay}ms)"
    else
        # Current proxy is unreachable — always switch to best
        threshold_delay=9999
        logger -t "$LOG_TAG" "GEMINI: current proxy unreachable, switching unconditionally"
    fi

    if [ "$best_delay" -lt "$threshold_delay" ] 2>/dev/null; then
        local saved=$((current_delay - best_delay))
        local api_result
        api_result=$(switch_group "$GEMINI_GROUP" "$best_proxy")
        logger -t "$LOG_TAG" "GEMINI: switched '${current_proxy}'→'${best_proxy}' (-${saved}ms) [API: ${api_result}]"
        {
            echo "GEMINI_PROXY=${best_proxy}"
            echo "GEMINI_DELAY=${best_delay}ms"
            echo "GEMINI_STATUS=ok"
            echo "GEMINI_SWITCHED=1"
        } >> "$STATUS_FILE"
        # Persist to flash only on actual switch
        cp "$STATUS_FILE" "$PERSISTENT_STATUS" 2>/dev/null || true
    else
        # Improvement below threshold — keep current proxy
        logger -t "$LOG_TAG" "GEMINI: keeping '${current_proxy}' (${current_delay}ms) — '${best_proxy}' (${best_delay}ms) not ${SWITCH_THRESHOLD}%+ better"
        {
            echo "GEMINI_PROXY=${current_proxy:-${best_proxy}}"
            echo "GEMINI_DELAY=${current_delay}ms"
            echo "GEMINI_STATUS=ok"
        } >> "$STATUS_FILE"
    fi
}

# ================================================================
# BLOCK B: PrvtVPN All Auto — read-only (url-test, self-managed)
# ================================================================
check_main() {
    logger -t "$LOG_TAG" "=== Main group: ${MAIN_GROUP} (url-test, read-only) ==="

    local current
    current=$(get_group_current "$MAIN_GROUP")

    if [ -z "$current" ]; then
        logger -t "$LOG_TAG" "Main: failed to read current proxy"
        return
    fi

    local delay
    delay=$(get_proxy_delay "$current" 5000)

    logger -t "$LOG_TAG" "Main: currently '${current}' (${delay}ms)"

    {
        echo "MAIN_PROXY=${current}"
        echo "MAIN_DELAY=${delay}ms"
    } >> "$STATUS_FILE"
}

# ================================================================
# Run
# ================================================================
logger -t "$LOG_TAG" "Starting latency monitor (threshold=${SWITCH_THRESHOLD}%)"

{
    echo "LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')"
} > "$STATUS_FILE"

optimize_gemini
check_main

logger -t "$LOG_TAG" "Done."
