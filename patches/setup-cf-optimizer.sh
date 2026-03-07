#!/bin/sh
# setup-cf-optimizer.sh
# Installs CF IP Optimizer on OpenWrt router (GL-iNet Flint 2 / GL-MT6000).
#
# Steps:
#   1. Copy scripts to /usr/local/bin/
#   2. Create /etc/config/cf_optimizer (UCI)
#   3. Deploy LuCI page (Services > CF IP Optimizer)
#   4. Setup cron (IP every 6h, SNI daily)
#   5. Apply DPI bypass nftables rule (MSS=150)
#   6. Create init script for autostart on boot
#   7. Remove non-working AGH LuCI tabs (Filters, Query Log, Settings)
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
WORKER_URL="https://YOUR_WORKER.workers.dev"
REGIONS="FI,DE,NL"
PROXY_NAME="YOUR_PROXY_NAME"
MIHOMO_API="http://127.0.0.1:9090"
MIHOMO_SECRET=""
MIHOMO_SOCKS="127.0.0.1:7891"
MIHOMO_CONFIG="/opt/clash/config.yaml"
MSS_VALUE="150"
UPDATE_THRESHOLD="20"
LIMIT_PER_REGION="10"
# ============================================================

# --- 1. Copy scripts ---
echo "==> [1/7] Copying scripts to /usr/local/bin/"

mkdir -p /usr/local/bin

cp "$SCRIPT_DIR/cf-ip-update.sh" /usr/local/bin/cf-ip-update.sh && chmod 755 /usr/local/bin/cf-ip-update.sh
cp "$SCRIPT_DIR/sni-scan.sh"     /usr/local/bin/sni-scan.sh     && chmod 755 /usr/local/bin/sni-scan.sh

echo "    cf-ip-update.sh -> /usr/local/bin/"
echo "    sni-scan.sh     -> /usr/local/bin/"

mkdir -p /etc/nftables.d
cp "$SCRIPT_DIR/99-cf-dpi-bypass.nft" /etc/nftables.d/99-cf-dpi-bypass.nft
chmod 644 /etc/nftables.d/99-cf-dpi-bypass.nft
echo "    99-cf-dpi-bypass.nft -> /etc/nftables.d/"

# --- 2. Create UCI config ---
echo ""
echo "==> [2/7] Creating /etc/config/cf_optimizer (UCI)"

# Создаём файл конфига если не существует (UCI требует наличия файла)
touch /etc/config/cf_optimizer

# Delete existing section if any
uci -q delete cf_optimizer.main 2>/dev/null || true

uci set cf_optimizer.main=cf_optimizer
uci set cf_optimizer.main.ip_updater_enabled=1
uci set cf_optimizer.main.sni_scanner_enabled=1
uci set cf_optimizer.main.dpi_bypass_enabled=1
uci set cf_optimizer.main.worker_url="$WORKER_URL"
uci set cf_optimizer.main.regions="$REGIONS"
uci set cf_optimizer.main.proxy_name="$PROXY_NAME"
uci set cf_optimizer.main.mihomo_api="$MIHOMO_API"
uci set cf_optimizer.main.mihomo_secret="$MIHOMO_SECRET"
uci set cf_optimizer.main.mihomo_socks="$MIHOMO_SOCKS"
uci set cf_optimizer.main.mihomo_config="$MIHOMO_CONFIG"
uci set cf_optimizer.main.mss_value="$MSS_VALUE"
uci set cf_optimizer.main.update_threshold="$UPDATE_THRESHOLD"
uci set cf_optimizer.main.limit_per_region="$LIMIT_PER_REGION"
uci commit cf_optimizer

echo "    UCI config created."

# --- 3. Deploy LuCI ---
echo ""
echo "==> [3/7] Installing LuCI page (Services > CF IP Optimizer)"

LUCI_CTRL="/usr/lib/lua/luci/controller"
LUCI_CBI="/usr/lib/lua/luci/model/cbi"

mkdir -p "$LUCI_CTRL" "$LUCI_CBI"

cp "$SCRIPT_DIR/luci/controller/cf_optimizer.lua" "$LUCI_CTRL/cf_optimizer.lua"
chmod 644 "$LUCI_CTRL/cf_optimizer.lua"

cp "$SCRIPT_DIR/luci/model/cbi/cf_optimizer.lua" "$LUCI_CBI/cf_optimizer.lua"
chmod 644 "$LUCI_CBI/cf_optimizer.lua"

rm -rf /tmp/luci-*
echo "    LuCI files installed, cache cleared."

# --- 4. Setup cron ---
echo ""
echo "==> [4/7] Setting up cron"

CRON_FILE="/etc/crontabs/root"
touch "$CRON_FILE"

sed -i '/cf-ip-update\|sni-scan/d' "$CRON_FILE" 2>/dev/null || true

echo "0 */6 * * * /usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1" >> "$CRON_FILE"
echo "30 2 * * * /usr/local/bin/sni-scan.sh >> /var/log/sni-scan.log 2>&1" >> "$CRON_FILE"

/etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
echo "    cron: IP every 6h, SNI at 02:30 daily"

# --- 5. Apply DPI bypass nftables ---
echo ""
echo "==> [5/7] Applying DPI bypass (nftables MSS=${MSS_VALUE})"

sed -i "s/size set [0-9]*/size set ${MSS_VALUE}/" /etc/nftables.d/99-cf-dpi-bypass.nft

nft delete table inet cf_dpi_bypass 2>/dev/null || true
if nft -f /etc/nftables.d/99-cf-dpi-bypass.nft 2>/dev/null; then
    echo "    nftables rule applied (MSS=${MSS_VALUE})"
else
    echo "    WARNING: nft failed - rule will apply on reboot"
fi

# --- 6. Init script ---
echo ""
echo "==> [6/7] Creating /etc/init.d/cf-optimizer"

cat > /etc/init.d/cf-optimizer << 'INITEOF'
#!/bin/sh /etc/rc.common
START=96
STOP=04

start() {
    local dpi_enabled
    dpi_enabled=$(uci -q get cf_optimizer.main.dpi_bypass_enabled)
    if [ "$dpi_enabled" = "1" ]; then
        nft -f /etc/nftables.d/99-cf-dpi-bypass.nft 2>/dev/null || true
        logger -t cf-optimizer "DPI bypass rules applied"
    fi

    local ip_enabled
    ip_enabled=$(uci -q get cf_optimizer.main.ip_updater_enabled)
    if [ "$ip_enabled" = "1" ]; then
        (sleep 30 && /usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1) &
        logger -t cf-optimizer "IP updater scheduled (30s delay)"
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
echo "    init script created and enabled"

# --- 7. Remove non-working AGH LuCI tabs ---
echo ""
echo "==> [7/7] Removing non-working AdGuard Home LuCI tabs"
echo "    (Filters, Query Log, Settings)"

AGH_CTRL=""
for path in \
    /usr/lib/lua/luci/controller/adguardhome.lua \
    /usr/lib/lua/luci/controller/admin/adguardhome.lua \
    /usr/lib/lua/luci/controller/gl-adguardhome.lua; do
    if [ -f "$path" ]; then
        AGH_CTRL="$path"
        break
    fi
done

if [ -n "$AGH_CTRL" ]; then
    [ ! -f "${AGH_CTRL}.bak" ] && cp "$AGH_CTRL" "${AGH_CTRL}.bak"
    sed -i \
        -e '/["'"'"']\(filters\|query_log\|settings\)["'"'"']/s/^/--/' \
        -e '/Filters\|Query.Log\|AdGuard.*Settings/s/^/--/' \
        "$AGH_CTRL"
    rm -rf /tmp/luci-*
    /etc/init.d/rpcd restart 2>/dev/null || true
    /etc/init.d/uhttpd restart 2>/dev/null || true
    echo "    Tabs removed, LuCI restarted: $AGH_CTRL"
else
    echo "    INFO: AGH LuCI controller not found"
    echo "         Check: find /usr/lib/lua/luci -name '*adguard*'"
fi

# --- Done ---
echo ""
echo "=================================================="
echo " CF IP Optimizer installed!"
echo "=================================================="
echo ""
echo " LuCI: Services > CF IP Optimizer"
echo " Logs:"
echo "   IP updater:  tail -f /var/log/cf-ip-update.log"
echo "   SNI scanner: tail -f /var/log/sni-scan.log"
echo "   Syslog:      logread | grep cf-ip"
echo ""
echo " IMPORTANT: Set your params via LuCI or UCI:"
echo "   uci set cf_optimizer.main.worker_url='https://YOUR_WORKER.workers.dev'"
echo "   uci set cf_optimizer.main.proxy_name='YOUR_PROXY_NAME'"
echo "   uci set cf_optimizer.main.regions='FI,DE,NL'"
echo "   uci commit cf_optimizer"
echo ""
echo " Manual IP update:"
echo "   /usr/local/bin/cf-ip-update.sh"
echo ""
