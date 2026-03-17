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
MIHOMO_SOCKS=$(uci -q get cf_optimizer.main.mihomo_socks)
MIHOMO_SOCKS="${MIHOMO_SOCKS:-127.0.0.1:7891}"

# --- Lock ---
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
# Test Gemini web accessibility through the currently active GEMINI proxy.
# Call AFTER switch_group + sleep 2 to let Mihomo update routing.
#
# Logic: HEAD gemini.google.com → check HTTP status + Location header
#   - Datacenter VPN IP → HTTP 200 directly (no consent redirect) → ACCESSIBLE
#   - EU residential IP → 302 → consent.google.com?gl=XX (non-RU/BY/KZ) → ACCESSIBLE
#   - Russian/CIS IP   → 302 → consent.google.com?gl=RU/BY/KZ → BLOCKED
#   - Geo-banned IP    → 302 to non-consent URL or 4xx → BLOCKED
#   - Timeout          → proxy down → BLOCKED
#
# Port 7891 = socks-port (IPv4 0.0.0.0:7891).
# Port 7890 = mixed-port, creates IPv6 socket (:::7890), inaccessible with disable_ipv6=1.
# Direct curl via TPROXY does not work for router-originated traffic (OUTPUT chain skips fwmark).
#
# Returns: 0 = Gemini accessible, 1 = blocked or unreachable
# ================================================================
gemini_access_ok() {
    local response proxy_auth http_code location gl_code
    proxy_auth=$(awk '
        /^authentication:/ { in_auth=1; next }
        in_auth && /^  - "/ { sub(/^  - "/, ""); sub(/".*/, ""); print; exit }
        in_auth && !/^  / { exit }
    ' /opt/clash/config.yaml 2>/dev/null)
    if [ -n "$proxy_auth" ]; then
        response=$(curl -s --max-time 8 \
            --socks5 "127.0.0.1:7891" \
            --proxy-user "$proxy_auth" \
            -I -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            "https://gemini.google.com/" 2>/dev/null)
    else
        response=$(curl -s --max-time 8 \
            --socks5 "127.0.0.1:7891" \
            -I -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            "https://gemini.google.com/" 2>/dev/null)
    fi
    [ -z "$response" ] && return 1

    # Extract HTTP status code from first response line
    http_code=$(echo "$response" | grep -m1 "^HTTP/" | awk '{print $2}')

    # Case 1: HTTP 200 — datacenter IP served Gemini directly → ACCESSIBLE
    [ "$http_code" = "200" ] && { GEMINI_GL_CODE="DC"; return 0; }

    # Case 2: Redirect — inspect Location header
    location=$(echo "$response" | grep -i "^location:" | head -1)
    [ -z "$location" ] && return 1

    # Case 2a: consent.google.com redirect (GDPR/EU residential IPs)
    if echo "$location" | grep -qi "consent.google.com"; then
        gl_code=$(echo "$location" | grep -oi 'gl=[A-Za-z][A-Za-z]' | head -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
        case "$gl_code" in
            RU|BY|KZ) return 1 ;;
        esac
        GEMINI_GL_CODE="${gl_code:-EU}"
        return 0
    fi

    # Case 2b: accounts.google.com (auth required but geo-accessible) → ACCESSIBLE
    if echo "$location" | grep -qi "accounts.google.com"; then
        GEMINI_GL_CODE="AUTH"
        return 0
    fi

    # Case 2c: any other redirect (geo-block page, error, etc.) → BLOCKED
    return 1
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

    local proxies
    proxies=$(get_group_proxies "$GEMINI_GROUP")

    if [ -z "$proxies" ]; then
        logger -t "$LOG_TAG" "GEMINI: failed to get proxy list from Mihomo API"
        echo "GEMINI_STATUS=api_error" >> "$STATUS_FILE"
        return 1
    fi

    local current_proxy
    current_proxy=$(get_group_current "$GEMINI_GROUP")
    logger -t "$LOG_TAG" "GEMINI: current='${current_proxy:-none}'"

    local proxy_count
    proxy_count=$(echo "$proxies" | wc -l)
    logger -t "$LOG_TAG" "GEMINI: phase 1 — latency test (${proxy_count} proxies)"

    # ── Phase 1: latency test via Mihomo delay API (non-switching, fast) ──────
    # Candidates stored as "NNNNN|proxy_name" for sort-by-latency
    local tmp_cand
    tmp_cand=$(mktemp 2>/dev/null || echo "/tmp/gemini-cand-$$")
    : > "$tmp_cand"
    local current_delay=9999
    local tested=0

    while IFS= read -r proxy; do
        [ -z "$proxy" ] && continue
        local delay
        delay=$(get_proxy_delay "$proxy" 5000)
        tested=$((tested + 1))
        logger -t "$LOG_TAG" "  [latency] $(printf '%-50s' "$proxy") ${delay}ms"
        [ "$proxy" = "$current_proxy" ] && current_delay=$delay
        [ "$delay" -lt 9000 ] 2>/dev/null && printf '%05d|%s\n' "$delay" "$proxy" >> "$tmp_cand"
        sleep 1
    done << PROXYEOF
$proxies
PROXYEOF

    logger -t "$LOG_TAG" "GEMINI: tested=${tested}, current_delay=${current_delay}ms"

    if [ ! -s "$tmp_cand" ]; then
        rm -f "$tmp_cand"
        logger -t "$LOG_TAG" "GEMINI: no reachable proxy found (all timed out)"
        echo "GEMINI_STATUS=all_timeout" >> "$STATUS_FILE"
        return
    fi

    local sorted_cand
    sorted_cand=$(sort "$tmp_cand")
    rm -f "$tmp_cand"

    # ── Phase 2: Gemini geo-block validation (requires SOCKS5) ────────────────
    # Temporarily switch to each candidate (fastest first) and probe Gemini API.
    # Google returns body "location is not supported" for geo-blocked IPs.
    # First accessible candidate wins — loop breaks immediately.
    local best_proxy=""
    local best_delay=9999

    if [ -n "$MIHOMO_SOCKS" ]; then
        logger -t "$LOG_TAG" "GEMINI: phase 2 — Gemini access validation via ${MIHOMO_SOCKS}"
        local validated=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local d px
            d=$(echo "$line" | cut -d'|' -f1 | awk '{print $1+0}')
            px=$(echo "$line" | cut -d'|' -f2-)
            [ -z "$px" ] && continue
            switch_group "$GEMINI_GROUP" "$px"
            sleep 2
            GEMINI_GL_CODE="?"
            if gemini_access_ok; then
                logger -t "$LOG_TAG" "  [gemini-ok]      '${px}' (${d}ms) gl=${GEMINI_GL_CODE}"
                best_proxy="$px"
                best_delay=$d
                validated=1
                break
            else
                logger -t "$LOG_TAG" "  [gemini-blocked] '${px}' — IP geo-blocked"
            fi
        done << CEOF
$sorted_cand
CEOF
        if [ "$validated" = "0" ]; then
            logger -t "$LOG_TAG" "GEMINI: WARNING — all candidates geo-blocked! Falling back to fastest by latency"
        fi
    fi

    # Fallback: SOCKS5 not configured or all blocked → use fastest by latency
    if [ -z "$best_proxy" ]; then
        local first_line
        first_line=$(echo "$sorted_cand" | head -1)
        best_delay=$(echo "$first_line" | cut -d'|' -f1 | awk '{print $1+0}')
        best_proxy=$(echo "$first_line" | cut -d'|' -f2-)
    fi

    logger -t "$LOG_TAG" "GEMINI: best='${best_proxy}'(${best_delay}ms), current='${current_proxy}'(${current_delay}ms)"

    if [ -z "$best_proxy" ] || [ "$best_delay" -ge 9000 ] 2>/dev/null; then
        logger -t "$LOG_TAG" "GEMINI: no valid proxy"
        echo "GEMINI_STATUS=all_timeout" >> "$STATUS_FILE"
        return
    fi

    if [ "$best_proxy" = "$current_proxy" ]; then
        logger -t "$LOG_TAG" "GEMINI: already optimal, keeping '${best_proxy}' (${best_delay}ms)"
        {
            echo "GEMINI_PROXY=${best_proxy}"
            echo "GEMINI_DELAY=${best_delay}ms"
            echo "GEMINI_STATUS=ok"
        } >> "$STATUS_FILE"
        return
    fi

    # ── Hysteresis check ──────────────────────────────────────────────────────
    # Skip hysteresis if best_proxy was geo-validated (phase 2) but current was not.
    # This ensures we always switch away from a geo-blocked current proxy.
    local threshold_delay
    if [ "${validated:-0}" = "1" ] && [ "$best_proxy" != "$current_proxy" ]; then
        # best_proxy passed geo-check; current may be geo-blocked → switch unconditionally
        threshold_delay=9999
        logger -t "$LOG_TAG" "GEMINI: geo-validated proxy found → switching unconditionally (bypassing hysteresis)"
    elif [ "$current_delay" -lt 9000 ] 2>/dev/null; then
        threshold_delay=$(awk "BEGIN { printf \"%d\", $current_delay * (100 - $SWITCH_THRESHOLD) / 100 }")
        logger -t "$LOG_TAG" "GEMINI: switch threshold = ${threshold_delay}ms (${SWITCH_THRESHOLD}% below ${current_delay}ms)"
    else
        threshold_delay=9999
        logger -t "$LOG_TAG" "GEMINI: current proxy unreachable, switching unconditionally"
    fi

    if [ "$best_delay" -lt "$threshold_delay" ] 2>/dev/null; then
        # Confirm switch (may already be set from validation phase — idempotent)
        local api_result
        api_result=$(switch_group "$GEMINI_GROUP" "$best_proxy")
        local saved=$((current_delay - best_delay))
        logger -t "$LOG_TAG" "GEMINI: switched '${current_proxy}'→'${best_proxy}' (-${saved}ms) [API: ${api_result}]"
        {
            echo "GEMINI_PROXY=${best_proxy}"
            echo "GEMINI_DELAY=${best_delay}ms"
            echo "GEMINI_STATUS=ok"
            echo "GEMINI_SWITCHED=1"
        } >> "$STATUS_FILE"
        cp "$STATUS_FILE" "$PERSISTENT_STATUS" 2>/dev/null || true
    else
        # Improvement below threshold — restore current proxy
        switch_group "$GEMINI_GROUP" "$current_proxy"
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
