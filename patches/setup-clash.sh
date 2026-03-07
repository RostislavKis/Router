#!/bin/sh
# setup-clash.sh
# Installs Mihomo (Clash Meta) on OpenWrt with TPROXY fail-safe.
#
# What this does:
#   1. Fix wget (symlink to uclient-fetch for HTTPS support)
#   2. Install required kernel modules (kmod-nft-tproxy, iptables-nft)
#   3. Create /opt/clash/ directory structure
#   4. Download Mihomo binary (aarch64) from GitHub releases
#   5. Download geo databases (geoip.dat, geosite.dat, country.mmdb)
#   6. Install TPROXY nftables rules
#   7. Install /etc/init.d/clash with FAIL-SAFE:
#      TPROXY applied ONLY after Mihomo API responds.
#      If Mihomo fails → internet works directly (no TPROXY blackhole).
#   8. Enable clash service (does NOT start — requires config.yaml)
#
# After running this script, put your config.yaml at:
#   /opt/clash/config.yaml
# Required fields in config.yaml:
#   tproxy-port: 7894
#   routing-mark: 2
#   external-controller: 0.0.0.0:9090
#
# Then start: /etc/init.d/clash start

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MIHOMO_VERSION="v1.19.20"
MIHOMO_ARCH="arm64"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"

GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"

echo "==> Clash/Mihomo: starting install"
echo ""

# --- 1. Fix wget ---
echo "==> [1/8] Fix wget (uclient-fetch HTTPS support)"
ln -sf /bin/uclient-fetch /usr/bin/wget
echo "    wget -> uclient-fetch (HTTPS enabled)"

# --- 2. Install kernel modules ---
echo ""
echo "==> [2/8] Installing kernel modules"
apk update >/dev/null 2>&1 || true
apk add kmod-nft-tproxy iptables-nft 2>&1 | grep -E '(Installing|OK|already)' || true
echo "    kmod-nft-tproxy, iptables-nft — done"

# --- 3. Directory structure ---
echo ""
echo "==> [3/8] Creating /opt/clash/ structure"
mkdir -p /opt/clash/bin /opt/clash/logs
echo "    /opt/clash/bin, /opt/clash/logs — done"

# --- 4. Mihomo binary ---
echo ""
echo "==> [4/8] Installing Mihomo ${MIHOMO_VERSION} (${MIHOMO_ARCH})"

if [ -x /opt/clash/bin/mihomo ]; then
    CURRENT=$(/opt/clash/bin/mihomo -v 2>&1 | grep -o 'v[0-9.]*' | head -1)
    if [ "$CURRENT" = "$MIHOMO_VERSION" ]; then
        echo "    Already installed: $CURRENT — skipping download"
    else
        echo "    Current: $CURRENT → upgrading to $MIHOMO_VERSION"
        uclient-fetch -O /tmp/mihomo.gz "$MIHOMO_URL"
        gunzip -c /tmp/mihomo.gz > /opt/clash/bin/mihomo
        chmod 755 /opt/clash/bin/mihomo
        rm -f /tmp/mihomo.gz
    fi
else
    uclient-fetch -O /tmp/mihomo.gz "$MIHOMO_URL"
    gunzip -c /tmp/mihomo.gz > /opt/clash/bin/mihomo
    chmod 755 /opt/clash/bin/mihomo
    rm -f /tmp/mihomo.gz
fi

echo "    Mihomo: $(/opt/clash/bin/mihomo -v 2>&1 | head -1)"

# --- 5. Geo databases ---
echo ""
echo "==> [5/8] Downloading geo databases"

download_geo() {
    local url="$1" dest="$2"
    if [ -f "$dest" ] && [ "$(wc -c < "$dest")" -gt 1048576 ]; then
        echo "    $(basename $dest) — already present, skipping"
        return 0
    fi
    uclient-fetch -O "${dest}.tmp" "$url" && mv "${dest}.tmp" "$dest" || {
        rm -f "${dest}.tmp"
        echo "    WARNING: failed to download $(basename $dest)"
        return 1
    }
    echo "    $(basename $dest) — $(wc -c < "$dest") bytes"
}

download_geo "$GEOIP_URL"   /opt/clash/geoip.dat
download_geo "$GEOSITE_URL" /opt/clash/geosite.dat
download_geo "$MMDB_URL"    /opt/clash/country.mmdb

# --- 6. TPROXY nft rules ---
echo ""
echo "==> [6/8] Installing TPROXY nftables rules"
mkdir -p /etc/nftables.d
cp "$SCRIPT_DIR/clash-tproxy.nft" /etc/nftables.d/clash-tproxy.nft
chmod 644 /etc/nftables.d/clash-tproxy.nft
echo "    clash-tproxy.nft -> /etc/nftables.d/"

# --- 7. Init script with fail-safe ---
echo ""
echo "==> [7/8] Installing /etc/init.d/clash (FAIL-SAFE)"
cp "$SCRIPT_DIR/clash-init.sh" /etc/init.d/clash
chmod 755 /etc/init.d/clash
echo "    FAIL-SAFE: TPROXY applied ONLY after Mihomo API responds"
echo "    If Mihomo fails → internet stays direct (no blackhole)"

# --- 8. Enable service ---
echo ""
echo "==> [8/8] Enabling clash service"
/etc/init.d/clash enable
echo "    clash service enabled (START=90)"

# --- Done ---
echo ""
echo "=================================================="
echo " Mihomo ${MIHOMO_VERSION} installed!"
echo "=================================================="
echo ""
echo " NEXT STEP: provide your config.yaml:"
echo "   scp config.yaml root@192.168.1.1:/opt/clash/config.yaml"
echo ""
echo " Required fields in config.yaml:"
echo "   tproxy-port: 7894"
echo "   routing-mark: 2"
echo "   external-controller: 0.0.0.0:9090"
echo ""
echo " Start manually:"
echo "   /etc/init.d/clash start"
echo ""
echo " Check logs:"
echo "   tail -f /opt/clash/logs/mihomo.log"
echo "   logread | grep clash"
echo ""
