#!/bin/sh
# install.sh — Proxy Optimizer: универсальный установщик
#
# Три способа запуска из SSH-консоли роутера:
#
# 1. Одна строка без копирования файлов (интернет через SSClash):
#
#      curl -fsSL https://raw.githubusercontent.com/RostislavKis/Router/master/install.sh | sh
#
# 2. Скопировал только install.sh и запускаешь (он сам скачает остальное):
#
#      scp install.sh root@192.168.1.1:/tmp/
#      ssh root@192.168.1.1 "sh /tmp/install.sh"
#
# 3. Скопировал папку patches/ рядом с install.sh (офлайн, без интернета):
#
#      scp -r patches/ install.sh root@192.168.1.1:/tmp/
#      ssh root@192.168.1.1 "sh /tmp/install.sh"
#
#    Или весь репозиторий:
#      scp -r . root@192.168.1.1:/tmp/router/
#      ssh root@192.168.1.1 "sh /tmp/router/install.sh"

set -e

REPO="https://raw.githubusercontent.com/RostislavKis/Router/master/patches"
DEST="/tmp/cf-optimizer-setup"

# Список файлов из patches/
FILES="
latency-monitor.sh
latency-start.sh
mihomo-watchdog.sh
log-rotate.sh
geo-update.sh
xray-control.sh
xray-install.sh
xray-apply-config.sh
cf-ip-update.sh
sni-scan.sh
setup-clash.sh
setup-cf-optimizer.sh
setup-adguardhome.sh
clash-tproxy.nft
clash-init.sh
99-cf-dpi-bypass.nft
99-router-mem.conf
xray-fragment.json
luci/menu.d/luci-app-cf-optimizer.json
luci/menu.d/luci-app-adguardhome.json
luci/acl.d/luci-app-cf-optimizer.json
luci/view/cf-optimizer/main.js
luci/view/adguardhome/dashboard.js
wifi-optimize.sh
"

echo "==> Proxy Optimizer — install.sh"
echo ""

# ── Ищем локальные файлы рядом со скриптом ───────────────────────────────
SELF_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo /tmp)"
LOCAL_PATCHES=""

if [ -f "$SELF_DIR/setup-cf-optimizer.sh" ]; then
    # install.sh лежит прямо в папке с патчами
    LOCAL_PATCHES="$SELF_DIR"
elif [ -f "$SELF_DIR/patches/setup-cf-optimizer.sh" ]; then
    # install.sh в корне репозитория, patches/ рядом
    LOCAL_PATCHES="$SELF_DIR/patches"
fi

if [ -n "$LOCAL_PATCHES" ]; then
    echo "==> Режим: локальные файлы ($LOCAL_PATCHES)"
else
    echo "==> Режим: загрузка с GitHub"
    echo "    $REPO"
fi
echo ""

# ── Подготовка временной директории ──────────────────────────────────────
rm -rf "$DEST"

# ── Загрузка / копирование файлов ────────────────────────────────────────
for f in $FILES; do
    [ -z "$f" ] && continue

    dest_file="$DEST/$f"
    mkdir -p "$(dirname "$dest_file")"

    if [ -n "$LOCAL_PATCHES" ] && [ -f "$LOCAL_PATCHES/$f" ]; then
        cp "$LOCAL_PATCHES/$f" "$dest_file"
        printf '    [local] %s\n' "$f"
    else
        url="$REPO/$f"
        if curl -fsSL --max-time 90 "$url" -o "$dest_file" 2>/dev/null; then
            printf '    [curl]  %s\n' "$f"
        elif uclient-fetch -O "$dest_file" "$url" 2>/dev/null; then
            printf '    [fetch] %s\n' "$f"
        else
            echo "ERROR: не удалось получить $f"
            echo "       Проверь интернет-соединение или скопируй файлы вручную."
            rm -rf "$DEST"
            exit 1
        fi
    fi
done

# ── Запуск установщиков ───────────────────────────────────────────────────
echo ""
echo "==> [1/2] Запуск setup-clash.sh (Mihomo + TPROXY fail-safe)..."
echo ""
chmod +x "$DEST/setup-clash.sh" "$DEST/clash-init.sh"
"$DEST/setup-clash.sh"

echo ""
echo "==> [2/2] Запуск setup-cf-optimizer.sh (Proxy Optimizer)..."
echo ""
chmod +x "$DEST/setup-cf-optimizer.sh"
"$DEST/setup-cf-optimizer.sh"

echo ""
echo "==> [3/3] Запуск setup-adguardhome.sh (AGH DNS + credentials)..."
echo ""
chmod +x "$DEST/setup-adguardhome.sh"
"$DEST/setup-adguardhome.sh"

# ── Чистка ───────────────────────────────────────────────────────────────
rm -rf "$DEST"

echo ""
echo "==> install.sh завершён."
echo ""
