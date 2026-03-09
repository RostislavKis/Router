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
echo "==> [6/7] Включение сервиса SSClash"
/etc/init.d/clash enable
echo "    clash service enabled (START=21)"

# --- 7. Патч clash-rules: пометить ВЕСЬ трафик через TPROXY ---
# Проблема: CLASH_MARK по умолчанию помечает только 198.18.0.0/16 (fake-ip range),
# когда задан fake-ip-range в конфиге. Домены из fake-ip-filter получают от Mihomo
# реальный IP — и их соединения обходят TPROXY, уходя напрямую с IP провайдера.
# Это ломает обход блокировок: Google видит российский IP даже при настроенном прокси.
#
# Решение: добавить mark-all правила ПОСЛЕ fake-ip-specific правил. Оба сосуществуют
# (одинаковый mark 0x0001, нет конфликта). fake-ip трафик матчится первым правилом,
# реальный IP из fake-ip-filter — catch-all правилом.
echo ""
echo "==> [7/7] Патч clash-rules: полное покрытие TPROXY"
CR="/opt/clash/bin/clash-rules"

if grep -q 'real-IP TPROXY' "$CR" 2>/dev/null; then
    echo "    Уже запатчено — пропускаем"
elif [ ! -f "$CR" ]; then
    echo "    WARNING: $CR не найден — пропускаем"
else
    cat > /tmp/patch-cr.awk << 'AWKEOF'
BEGIN { d="$"; s=0; q1=""; q2=""; q3="" }
{
    line=$0
    if (/msg "Marking applied for all traffic/) {
        q1=""; q2=""; q3=""
        s=1
    } else if (s==1 && /^    fi$/) {
        s=0
        print "    fi"
        print "    # Always also mark ALL remaining traffic (real-IP TPROXY, prevents ISP IP leaks)"
        print "    nft add rule inet clash CLASH_MARK meta l4proto tcp meta mark set 0x0001 counter"
        printf "    nft add rule inet clash CLASH_MARK meta l4proto udp meta mark set \"%sudp_mark\" counter\n", d
        print "    msg \"Marking applied for ALL remaining traffic (real-IP TPROXY enabled)\""
    } else if (s==1) {
        s=0
        print line
    } else {
        if (q3 != "") print q3
        q3=q2; q2=q1; q1=line
    }
}
END {
    if (q3 != "") print q3
    if (q2 != "") print q2
    if (q1 != "") print q1
}
AWKEOF
    awk -f /tmp/patch-cr.awk "$CR" > "${CR}.tmp"
    if grep -q 'real-IP TPROXY' "${CR}.tmp" 2>/dev/null; then
        mv "${CR}.tmp" "$CR"
        chmod 755 "$CR"
        echo "    clash-rules запатчен: весь TCP/UDP трафик идёт через TPROXY"
    else
        rm -f "${CR}.tmp"
        echo "    WARNING: патч не применился (файл мог измениться) — пропускаем"
    fi
    rm -f /tmp/patch-cr.awk
fi

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
