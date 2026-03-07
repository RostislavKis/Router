#!/bin/sh
# xray-install.sh
# Downloads and installs Xray-core binary for aarch64 (GL-MT6000 / aarch64_cortex-a53).
#
# Run via SSH on the router:
#   /usr/local/bin/xray-install.sh
#
# Or first time (before setup-cf-optimizer.sh was run):
#   scp patches/xray-install.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 "chmod +x /tmp/xray-install.sh && /tmp/xray-install.sh"
#
# After install:
#   1. Enable "Xray Fragment" in LuCI: Services > Proxy Optimizer
#   2. Add "dialer-proxy: xray-fragment" to the proxy entries in /opt/clash/config.yaml
#   3. Restart Mihomo: /etc/init.d/clash restart

set -e

XRAY_DEST="/usr/local/bin/xray"
TMP_ZIP="/tmp/xray-install.zip"
TMP_DIR="/tmp/xray-install"
URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"

echo "==> Installing Xray-core for aarch64"
echo ""

# Ensure unzip is available
if ! command -v unzip >/dev/null 2>&1; then
    echo "==> Installing unzip..."
    apk add unzip 2>/dev/null || { echo "ERROR: cannot install unzip"; exit 1; }
fi

echo "==> Downloading from GitHub releases..."
if ! curl -sL --max-time 180 "$URL" -o "$TMP_ZIP"; then
    echo "ERROR: Download failed. Check internet connectivity."
    exit 1
fi

echo "==> Extracting..."
mkdir -p "$TMP_DIR"
if ! unzip -o "$TMP_ZIP" xray -d "$TMP_DIR" 2>/dev/null; then
    echo "ERROR: Extraction failed."
    rm -f "$TMP_ZIP"
    rm -rf "$TMP_DIR"
    exit 1
fi

mv "$TMP_DIR/xray" "$XRAY_DEST"
chmod 755 "$XRAY_DEST"
rm -f "$TMP_ZIP"
rm -rf "$TMP_DIR"

echo ""
echo "==> Xray installed: $("$XRAY_DEST" version 2>&1 | head -1)"
echo ""
echo "==> Next steps:"
echo "    1. LuCI: Services > Proxy Optimizer > Xray Fragment — включить и запустить"
echo "    2. В /opt/clash/config.yaml добавить к нужным прокси:"
echo "         dialer-proxy: xray-fragment"
echo "    3. Перезапустить Mihomo: /etc/init.d/clash restart"
echo ""
