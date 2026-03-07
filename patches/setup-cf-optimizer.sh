#!/bin/sh
# setup-cf-optimizer.sh
# Installs CF IP Optimizer on OpenWrt router (GL-iNet Flint 2 / GL-MT6000).
#
# Steps:
#   1. Copy scripts to /usr/local/bin/
#   2. Create /etc/config/cf_optimizer (UCI)
#   3. Deploy LuCI page (JSON menu + ACL + JS view — for OpenWrt 26.x without Lua)
#   4. Setup cron (latency/watchdog/log-rotate/geo-update/cf-ip/sni)
#   5. Apply DPI bypass nftables rule (MSS=150)
#   6. Create init script for autostart on boot
#
# Run on router:
#   scp -r patches/ root@192.168.1.1:/tmp/cf-optimizer/
#   ssh root@192.168.1.1 "chmod +x /tmp/cf-optimizer/setup-cf-optimizer.sh && /tmp/cf-optimizer/setup-cf-optimizer.sh"

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> CF IP Optimizer: starting install"
echo ""

# ============================================================
# CONFIGURE THESE BEFORE RUNNING
# ============================================================
GEMINI_GROUP="🤖 GEMINI"
MAIN_GROUP="PrvtVPN All Auto"
MIHOMO_API="http://127.0.0.1:9090"
MIHOMO_SECRET=""
MIHOMO_SOCKS="127.0.0.1:7891"
MIHOMO_CONFIG="/opt/clash/config.yaml"
MSS_VALUE="150"
SWITCH_THRESHOLD="20"
# --- Only needed if your proxies are behind Cloudflare CDN ---
WORKER_URL="https://YOUR_WORKER.workers.dev"
REGIONS="FI,DE,NL"
PROXY_NAME="YOUR_PROXY_NAME"
UPDATE_THRESHOLD="20"
LIMIT_PER_REGION="10"
# ============================================================

# --- 1. Copy scripts ---
echo "==> [1/6] Copying scripts to /usr/local/bin/"

mkdir -p /usr/local/bin

cp "$SCRIPT_DIR/latency-monitor.sh"  /usr/local/bin/latency-monitor.sh  && chmod 755 /usr/local/bin/latency-monitor.sh
cp "$SCRIPT_DIR/latency-start.sh"    /usr/local/bin/latency-start.sh    && chmod 755 /usr/local/bin/latency-start.sh
cp "$SCRIPT_DIR/mihomo-watchdog.sh"  /usr/local/bin/mihomo-watchdog.sh  && chmod 755 /usr/local/bin/mihomo-watchdog.sh
cp "$SCRIPT_DIR/log-rotate.sh"       /usr/local/bin/log-rotate.sh       && chmod 755 /usr/local/bin/log-rotate.sh
cp "$SCRIPT_DIR/geo-update.sh"       /usr/local/bin/geo-update.sh       && chmod 755 /usr/local/bin/geo-update.sh
cp "$SCRIPT_DIR/cf-ip-update.sh"     /usr/local/bin/cf-ip-update.sh     && chmod 755 /usr/local/bin/cf-ip-update.sh
cp "$SCRIPT_DIR/sni-scan.sh"         /usr/local/bin/sni-scan.sh         && chmod 755 /usr/local/bin/sni-scan.sh

echo "    latency-monitor.sh  -> /usr/local/bin/"
echo "    latency-start.sh    -> /usr/local/bin/"
echo "    mihomo-watchdog.sh  -> /usr/local/bin/"
echo "    log-rotate.sh       -> /usr/local/bin/"
echo "    geo-update.sh       -> /usr/local/bin/"
echo "    cf-ip-update.sh     -> /usr/local/bin/"
echo "    sni-scan.sh         -> /usr/local/bin/"

mkdir -p /etc/nftables.d
cp "$SCRIPT_DIR/99-cf-dpi-bypass.nft" /etc/nftables.d/99-cf-dpi-bypass.nft
chmod 644 /etc/nftables.d/99-cf-dpi-bypass.nft
echo "    99-cf-dpi-bypass.nft -> /etc/nftables.d/"

# --- 2. Create UCI config ---
echo ""
echo "==> [2/6] Creating /etc/config/cf_optimizer (UCI)"

touch /etc/config/cf_optimizer
uci -q delete cf_optimizer.main 2>/dev/null || true

uci set cf_optimizer.main=cf_optimizer

# Latency monitor (enabled by default)
uci set cf_optimizer.main.latency_enabled=1
uci set cf_optimizer.main.gemini_group="$GEMINI_GROUP"
uci set cf_optimizer.main.main_group="$MAIN_GROUP"
uci set cf_optimizer.main.switch_threshold="$SWITCH_THRESHOLD"

# DPI bypass (enabled by default)
uci set cf_optimizer.main.dpi_bypass_enabled=1
uci set cf_optimizer.main.mss_value="$MSS_VALUE"

# Watchdog (enabled by default)
uci set cf_optimizer.main.watchdog_enabled=1

# Geo update (disabled by default — enable once proxy is confirmed working)
uci set cf_optimizer.main.geo_update_enabled=0

# CF IP Updater and SNI Scanner (disabled by default — only for proxies behind Cloudflare CDN)
uci set cf_optimizer.main.ip_updater_enabled=0
uci set cf_optimizer.main.sni_scanner_enabled=0
uci set cf_optimizer.main.worker_url="$WORKER_URL"
uci set cf_optimizer.main.regions="$REGIONS"
uci set cf_optimizer.main.proxy_name="$PROXY_NAME"
uci set cf_optimizer.main.update_threshold="$UPDATE_THRESHOLD"
uci set cf_optimizer.main.limit_per_region="$LIMIT_PER_REGION"

# Mihomo API
uci set cf_optimizer.main.mihomo_api="$MIHOMO_API"
uci set cf_optimizer.main.mihomo_secret="$MIHOMO_SECRET"
uci set cf_optimizer.main.mihomo_socks="$MIHOMO_SOCKS"
uci set cf_optimizer.main.mihomo_config="$MIHOMO_CONFIG"

uci commit cf_optimizer
echo "    UCI config created."

# --- 3. Deploy LuCI (JSON menu + ACL + JS view — OpenWrt 26.x style, no Lua) ---
echo ""
echo "==> [3/6] Installing LuCI page (Services > CF IP Optimizer)"

# JSON menu entry
mkdir -p /usr/share/luci/menu.d
cp "$SCRIPT_DIR/luci/menu.d/luci-app-cf-optimizer.json" \
   /usr/share/luci/menu.d/luci-app-cf-optimizer.json
chmod 644 /usr/share/luci/menu.d/luci-app-cf-optimizer.json
echo "    menu.d/luci-app-cf-optimizer.json -> /usr/share/luci/menu.d/"

# ACL permissions for rpcd
mkdir -p /usr/share/rpcd/acl.d
cp "$SCRIPT_DIR/luci/acl.d/luci-app-cf-optimizer.json" \
   /usr/share/rpcd/acl.d/luci-app-cf-optimizer.json
chmod 644 /usr/share/rpcd/acl.d/luci-app-cf-optimizer.json
echo "    acl.d/luci-app-cf-optimizer.json  -> /usr/share/rpcd/acl.d/"

# JavaScript view
mkdir -p /www/luci-static/resources/view/cf-optimizer
cp "$SCRIPT_DIR/luci/view/cf-optimizer/main.js" \
   /www/luci-static/resources/view/cf-optimizer/main.js
chmod 644 /www/luci-static/resources/view/cf-optimizer/main.js
echo "    view/cf-optimizer/main.js         -> /www/luci-static/resources/view/cf-optimizer/"

# Remove old Lua files if they exist (from previous installs)
rm -f /usr/lib/lua/luci/controller/cf_optimizer.lua
rm -f /usr/lib/lua/luci/model/cbi/cf_optimizer.lua

# Clear LuCI index cache and restart services
rm -rf /tmp/luci-*
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
echo "    LuCI installed, cache cleared, rpcd/uhttpd restarted."

# --- 4. Setup cron ---
echo ""
echo "==> [4/6] Setting up cron"

CRON_FILE="/etc/crontabs/root"
touch "$CRON_FILE"

# Remove old entries if present (busybox sed: separate -e per pattern, no \| alternation)
sed -i '/cf-ip-update/d' "$CRON_FILE" 2>/dev/null || true
sed -i '/sni-scan/d'     "$CRON_FILE" 2>/dev/null || true
sed -i '/latency-monitor/d' "$CRON_FILE" 2>/dev/null || true
sed -i '/mihomo-watchdog/d' "$CRON_FILE" 2>/dev/null || true
sed -i '/log-rotate/d'   "$CRON_FILE" 2>/dev/null || true
sed -i '/geo-update/d'   "$CRON_FILE" 2>/dev/null || true

# Latency monitor: every 2 hours
echo "0 */2 * * * /usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1" >> "$CRON_FILE"
# Mihomo watchdog: every 10 minutes
echo "*/10 * * * * /usr/local/bin/mihomo-watchdog.sh >> /var/log/mihomo-watchdog.log 2>&1" >> "$CRON_FILE"
# Log rotation: daily at 03:00
echo "0 3 * * * /usr/local/bin/log-rotate.sh" >> "$CRON_FILE"
# Geo update: weekly Sunday at 04:00 (activate via LuCI when needed)
echo "0 4 * * 0 /usr/local/bin/geo-update.sh >> /var/log/geo-update.log 2>&1" >> "$CRON_FILE"
# CF IP update: every 6 hours (only active if ip_updater_enabled=1)
echo "0 */6 * * * /usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1" >> "$CRON_FILE"
# SNI scan: daily at 02:30 (only active if sni_scanner_enabled=1)
echo "30 2 * * * /usr/local/bin/sni-scan.sh >> /var/log/sni-scan.log 2>&1" >> "$CRON_FILE"

/etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
echo "    latency monitor:   every 2h"
echo "    mihomo watchdog:   every 10 min"
echo "    log rotation:      daily 03:00"
echo "    geo update:        weekly Sun 04:00 (activate via LuCI)"
echo "    CF IP update:      every 6h (activate via LuCI)"
echo "    SNI scan:          daily 02:30 (activate via LuCI)"

# --- 5. Apply DPI bypass nftables ---
echo ""
echo "==> [5/6] Applying DPI bypass (nftables MSS=${MSS_VALUE})"

sed -i "s/size set [0-9]*/size set ${MSS_VALUE}/" /etc/nftables.d/99-cf-dpi-bypass.nft

nft delete table inet cf_dpi_bypass 2>/dev/null || true
if nft -f /etc/nftables.d/99-cf-dpi-bypass.nft 2>/dev/null; then
    echo "    nftables rule applied (MSS=${MSS_VALUE})"
else
    echo "    WARNING: nft failed - rule will apply on reboot"
fi

# --- 6. Init script ---
echo ""
echo "==> [6/6] Creating /etc/init.d/cf-optimizer"

cat > /etc/init.d/cf-optimizer << 'INITEOF'
#!/bin/sh /etc/rc.common
START=96
STOP=04

start() {
    local api
    api=$(uci -q get cf_optimizer.main.mihomo_api)
    api="${api:-http://127.0.0.1:9090}"

    # Restore last known status from flash to RAM (lost on every reboot)
    [ -f /etc/cf-optimizer.status ] && \
        cp /etc/cf-optimizer.status /var/run/latency-monitor.status 2>/dev/null || true

    # DPI bypass
    local dpi_enabled
    dpi_enabled=$(uci -q get cf_optimizer.main.dpi_bypass_enabled)
    if [ "$dpi_enabled" = "1" ]; then
        nft -f /etc/nftables.d/99-cf-dpi-bypass.nft 2>/dev/null || true
        logger -t cf-optimizer "DPI bypass rules applied"
    fi

    # Latency monitor — wait for Mihomo API instead of blind sleep
    local lat_enabled
    lat_enabled=$(uci -q get cf_optimizer.main.latency_enabled)
    if [ "$lat_enabled" = "1" ]; then
        (
            waited=0
            while ! curl -sf --max-time 3 "${api}/version" >/dev/null 2>&1; do
                [ $waited -ge 120 ] && break
                sleep 5
                waited=$((waited + 5))
            done
            /usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1
        ) &
        logger -t cf-optimizer "Latency monitor will run after Mihomo API ready"
    fi

    # CF IP updater (90s delay — after latency monitor starts)
    local ip_enabled
    ip_enabled=$(uci -q get cf_optimizer.main.ip_updater_enabled)
    if [ "$ip_enabled" = "1" ]; then
        (sleep 90 && /usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1) &
        logger -t cf-optimizer "IP updater scheduled (90s delay)"
    fi
}

stop() {
    nft delete table inet cf_dpi_bypass 2>/dev/null || true
    logger -t cf-optimizer "DPI bypass rules removed"
}

restart() {
    stop
    start
}
INITEOF

chmod +x /etc/init.d/cf-optimizer
/etc/init.d/cf-optimizer enable
echo "    init script created and enabled (START=96)"

# --- Done ---
echo ""
echo "=================================================="
echo " CF IP Optimizer installed!"
echo "=================================================="
echo ""
echo " LuCI: Services > CF IP Optimizer"
echo ""
echo " Что включено по умолчанию:"
echo "   [ON]  Latency Monitor  — переключает GEMINI каждые 2 часа (гистерезис ${SWITCH_THRESHOLD}%)"
echo "   [ON]  DPI Bypass       — nftables MSS=${MSS_VALUE}"
echo "   [ON]  Mihomo Watchdog  — перезапуск при сбое (каждые 10 мин)"
echo "   [OFF] Geo Update       — обновление geoip/geosite (включить после проверки)"
echo "   [OFF] CF IP Updater    — включить если прокси за Cloudflare CDN"
echo "   [OFF] SNI Scanner      — включить если прокси за Cloudflare CDN"
echo ""
echo " Логи:"
echo "   Latency monitor: tail -f /var/log/latency-monitor.log"
echo "   Watchdog:        tail -f /var/log/mihomo-watchdog.log"
echo "   Syslog:          logread | grep cf-optimizer"
echo ""
echo " Проверить GEMINI:"
echo "   cat /var/run/latency-monitor.status"
echo " Проверить watchdog:"
echo "   cat /var/run/mihomo-watchdog.status"
echo ""
