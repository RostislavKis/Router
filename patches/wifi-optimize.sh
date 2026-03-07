#!/bin/sh
# wifi-optimize.sh
# Maximize WiFi power and coverage on GL-MT6000 (OpenWrt).
#
# Key changes:
#   1. Country BO (Bolivia) — regulatory DB allows 30 dBm on 5 GHz ch149-161
#      (RU/00 caps everything at 20 dBm in this firmware's wireless-regdb)
#   2. 2.4GHz: HE40 (40 MHz) on ch6, txpower 30 (capped at 20 dBm by regdb)
#   3. 5GHz:   HE80 (80 MHz) on ch149, txpower 30 dBm = 1000 mW!
#      vs previous: ch36 HE80 20 dBm — 10 dBm gain = 10x more transmit power
#
# Usage: /usr/local/bin/wifi-optimize.sh [--show]
#   --show  Only print current status, no changes

set -e

if [ "$1" = "--show" ]; then
    echo "=== Current WiFi status ==="
    iwinfo 2>/dev/null | grep -E "(ESSID|Tx-Power|Channel|HT Mode|Bit Rate)" || true
    iw reg get 2>/dev/null | head -4 || true
    exit 0
fi

echo "==> WiFi Optimization"
echo ""

# Save current state for comparison
OLD_2G_CH=$(uci -q get wireless.radio0.channel 2>/dev/null || echo "?")
OLD_2G_HT=$(uci -q get wireless.radio0.htmode  2>/dev/null || echo "?")
OLD_5G_CH=$(uci -q get wireless.radio1.channel 2>/dev/null || echo "?")
OLD_5G_HT=$(uci -q get wireless.radio1.htmode  2>/dev/null || echo "?")

echo "    Before: 2.4GHz ch${OLD_2G_CH} ${OLD_2G_HT}  |  5GHz ch${OLD_5G_CH} ${OLD_5G_HT}"

# ---- Enable SSIDs (may be disabled after factory reset) ----
for iface in $(uci show wireless | grep '\.disabled=' | cut -d. -f2 | grep -v '^radio'); do
    uci set wireless.${iface}.disabled='0'
done

# ---- 2.4GHz (radio0) ----
uci set wireless.radio0.country='BO'
uci set wireless.radio0.channel='6'
uci set wireless.radio0.htmode='HE40'
# Remove fixed txpower — let driver use AUTO (max allowed by regdomain)
# With BO: 2.4GHz cap = 20 dBm; using 'fixed 30' would still show 20 dBm
uci delete wireless.radio0.txpower 2>/dev/null || true
# noscan: ignore HT40-intolerant beacons from neighbors, stay on 40 MHz
uci set wireless.radio0.noscan='1'
echo "    2.4GHz: country BO, ch6, HE40, txpower AUTO (cap 20 dBm = 100 mW)"

# ---- 5GHz (radio1) ----
uci set wireless.radio1.country='BO'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
# AUTO txpower on ch149 with BO regdomain = 30 dBm (1000 mW)
# 'fixed 3000 mBm' mode is capped by driver; AUTO uses full regulatory allowance
uci delete wireless.radio1.txpower 2>/dev/null || true
uci set wireless.radio1.noscan='1'
echo "    5GHz:   country BO, ch149, HE80, txpower AUTO (30 dBm = 1000 mW!)"

uci commit wireless

echo ""
echo "==> Applying (wifi reload)..."
wifi reload

sleep 6

echo ""
echo "=== New status ==="
iwinfo 2>/dev/null | grep -E "(ESSID|Tx-Power|Channel|HT Mode)" || true
echo ""
echo "==> Done."
echo "    2.4GHz ch6  HE40  — wider channel, better throughput, 20 dBm"
echo "    5GHz   ch149 HE80 — 30 dBm = 1000 mW (10x vs default ch36 @ 20 dBm)"
