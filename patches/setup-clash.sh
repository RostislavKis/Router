#!/bin/sh
# setup-clash.sh
# Устанавливает SSClash (zerolabnet/SSClash) — Mihomo в виде OpenWrt-пакета.
#
# SSClash предоставляет:
#   - /etc/init.d/clash     (procd, START=21, DNS через dnsmasq, TPROXY через clash-rules)
#   - /opt/clash/bin/clash-rules  (nftables TPROXY-скрипт)
#   - luci-app-ssclash      (веб-интерфейс в LuCI)
#
# Использование:
#   chmod +x setup-clash.sh
#   ./setup-clash.sh
#
# Запуск на роутере через SSH:
#   scp patches/setup-clash.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 "chmod +x /tmp/setup-clash.sh && /tmp/setup-clash.sh"
#
# После выполнения скопируйте конфиг:
#   scp config.yaml root@192.168.1.1:/opt/clash/config.yaml
#   /etc/init.d/clash start
#
# Требования в config.yaml:
#   tproxy-port: 7894
#   routing-mark: 2
#   dns:
#     listen: '127.0.0.1:1053'
#   external-controller: 0.0.0.0:9090

set -e

SSCLASH_VERSION="3.5.0"
SSCLASH_ARCH="aarch64_cortex-a53"

MIHOMO_VERSION="v1.19.20"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-arm64-${MIHOMO_VERSION}.gz"

GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"

echo "==> SSClash + Mihomo: установка"
echo ""

# --- 1. Исправление wget ---
echo "==> [1/6] Исправление wget (uclient-fetch, поддержка HTTPS)"
ln -sf /bin/uclient-fetch /usr/bin/wget
echo "    wget -> uclient-fetch"

# --- 2. Модуль ядра для TPROXY ---
echo ""
echo "==> [2/6] Установка kmod-nft-tproxy"
apk update >/dev/null 2>&1 || true
apk add kmod-nft-tproxy 2>&1 | grep -E '(Installing|OK|already)' || true
echo "    kmod-nft-tproxy — ОК"

# --- 3. SSClash APK-пакеты ---
echo ""
echo "==> [3/6] Установка SSClash ${SSCLASH_VERSION}"

# Получаем URL пакетов из GitHub Releases API
echo "    Поиск пакетов на GitHub..."
RELEASE_JSON=$(uclient-fetch -q -O - \
    "https://api.github.com/repos/zerolabnet/SSClash/releases/tags/v${SSCLASH_VERSION}" \
    2>/dev/null) || RELEASE_JSON=""

# Извлекаем URL пакетов из JSON (ищем все .apk ссылки)
SSCLASH_APK_URL=$(echo "$RELEASE_JSON" | \
    grep -o 'https://github.com/[^"]*\.apk' | \
    grep "${SSCLASH_ARCH}" | grep -v 'luci' | head -1)

LUCI_APK_URL=$(echo "$RELEASE_JSON" | \
    grep -o 'https://github.com/[^"]*\.apk' | \
    grep 'luci-app-ssclash' | head -1)

# Fallback URLs если API не дал результатов
if [ -z "$SSCLASH_APK_URL" ]; then
    SSCLASH_APK_URL="https://github.com/zerolabnet/SSClash/releases/download/v${SSCLASH_VERSION}/ssclash_${SSCLASH_VERSION}-r1_${SSCLASH_ARCH}.apk"
    echo "    (GitHub API не ответил, используем стандартный URL)"
fi
if [ -z "$LUCI_APK_URL" ]; then
    LUCI_APK_URL="https://github.com/zerolabnet/SSClash/releases/download/v${SSCLASH_VERSION}/luci-app-ssclash_${SSCLASH_VERSION}-r1_all.apk"
fi

echo "    ssclash: $(basename "$SSCLASH_APK_URL")"
echo "    luci:    $(basename "$LUCI_APK_URL")"
echo ""

uclient-fetch -O /tmp/ssclash.apk "$SSCLASH_APK_URL"
apk add --allow-untrusted /tmp/ssclash.apk
rm -f /tmp/ssclash.apk
echo "    ssclash — установлен"

uclient-fetch -O /tmp/luci-app-ssclash.apk "$LUCI_APK_URL"
apk add --allow-untrusted /tmp/luci-app-ssclash.apk
rm -f /tmp/luci-app-ssclash.apk
echo "    luci-app-ssclash — установлен"

# --- 4. Бинарник Mihomo ---
echo ""
echo "==> [4/6] Установка Mihomo ${MIHOMO_VERSION} → /opt/clash/bin/clash"
# SSClash ожидает бинарник именно с именем 'clash', не 'mihomo'
mkdir -p /opt/clash/bin /opt/clash/logs

uclient-fetch -O /tmp/mihomo.gz "$MIHOMO_URL"
gunzip -c /tmp/mihomo.gz > /opt/clash/bin/clash
chmod 755 /opt/clash/bin/clash
rm -f /tmp/mihomo.gz

echo "    $(/opt/clash/bin/clash -v 2>&1 | head -1)"

# --- 5. Geo-базы ---
echo ""
echo "==> [5/6] Загрузка geo-баз данных"

download_geo() {
    local url="$1" dest="$2"
    if [ -f "$dest" ] && [ "$(wc -c < "$dest")" -gt 1048576 ]; then
        echo "    $(basename "$dest") — уже есть, пропускаем"
        return 0
    fi
    uclient-fetch -O "${dest}.tmp" "$url" && mv "${dest}.tmp" "$dest" || {
        rm -f "${dest}.tmp"
        echo "    WARN: не удалось загрузить $(basename "$dest")"
    }
    echo "    $(basename "$dest") — $(wc -c < "$dest") байт"
}

download_geo "$GEOIP_URL"   /opt/clash/geoip.dat
download_geo "$GEOSITE_URL" /opt/clash/geosite.dat
download_geo "$MMDB_URL"    /opt/clash/country.mmdb

# --- 6. Включение сервиса ---
echo ""
echo "==> [6/6] Включение сервиса SSClash"
/etc/init.d/clash enable
echo "    clash service enabled (START=21)"

echo ""
echo "=================================================="
echo " SSClash ${SSCLASH_VERSION} установлен!"
echo " Бинарник: /opt/clash/bin/clash"
echo " Init.d:   /etc/init.d/clash  (START=21)"
echo "=================================================="
echo ""
echo " СЛЕДУЮЩИЙ ШАГ: загрузите конфиг с вашего ПК:"
echo "   scp config.yaml root@192.168.1.1:/opt/clash/config.yaml"
echo ""
echo " Запуск сервиса:"
echo "   /etc/init.d/clash start"
echo ""
echo " Проверка:"
echo "   /etc/init.d/clash status"
echo "   ss -tlunp | grep -E '(:9090|:7894|:1053)'"
echo ""
