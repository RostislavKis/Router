#!/bin/sh
# install.sh — Router: полная установка SSClash + AdGuard Home
#
# Порядок установки:
#   1. setup-clash.sh    — SSClash (Mihomo) + TPROXY (START=21)
#   2. Копируем config.yaml → /opt/clash/config.yaml
#   3. Запускаем SSClash (Mihomo слушает DNS :1053, TPROXY :7894)
#   4. setup-adguardhome.sh — AGH (START=19), dnsmasq DHCP, LuCI-страница
#   5. setup-cf-optimizer.sh — CF Optimizer (опционально)
#
# Порядок старта после перезагрузки:
#   AGH (19) → dnsmasq (20) → SSClash/Mihomo (21)
#   DNS-цепочка: Клиенты → AGH :53 → Mihomo :1053 → интернет
#
# Способы запуска:
#
#   1. Весь репозиторий (рекомендуется):
#      scp -r . root@192.168.1.1:/tmp/router/
#      ssh root@192.168.1.1 "sh /tmp/router/install.sh"
#
#   2. Только install.sh (скачает файлы с GitHub):
#      scp install.sh root@192.168.1.1:/tmp/
#      ssh root@192.168.1.1 "sh /tmp/install.sh"
#
#   3. Одна строка через curl (нужен интернет):
#      curl -fsSL https://raw.githubusercontent.com/RostislavKis/Router/master/install.sh | sh

set -e

REPO_RAW="https://raw.githubusercontent.com/RostislavKis/Router/master"
DEST="/tmp/router-setup"

# Файлы из patches/ для загрузки
PATCH_FILES="
setup-clash.sh
setup-adguardhome.sh
setup-cf-optimizer.sh
latency-monitor.sh
latency-start.sh
mihomo-watchdog.sh
clash-watchdog.sh
mem-cleanup.sh
log-rotate.sh
geo-update.sh
cf-ip-update.sh
sni-scan.sh
xray-control.sh
xray-install.sh
xray-apply-config.sh
99-cf-dpi-bypass.nft
98-telegram-tproxy.nft
99-clash-restart
99-router-mem.conf
xray-fragment.json
wifi-optimize.sh
luci/menu.d/luci-app-cf-optimizer.json
luci/menu.d/luci-app-adguardhome.json
luci/acl.d/luci-app-cf-optimizer.json
luci/view/cf-optimizer/main.js
luci/view/adguardhome/dashboard.js
"

echo "==> Router Setup — установка SSClash + AdGuard Home"
echo ""

# ── Исправление wget (OpenWrt 25.12.0: wget → wget-nossl без HTTPS) ────────
if [ -f /bin/uclient-fetch ] && [ "$(readlink /usr/bin/wget 2>/dev/null)" != "/bin/uclient-fetch" ]; then
    echo "==> Исправление wget (uclient-fetch, поддержка HTTPS)"
    ln -sf /bin/uclient-fetch /usr/bin/wget
fi

# ── Зеркало apk: китайские репозитории (доступны из России без VPN) ────────
# downloads.openwrt.org заблокирован в России — используем TUNA mirror
_APK_REPO_FILE="/etc/apk/repositories"
_OPENWRT_VER="25.12.0"
_OPENWRT_ARCH="aarch64_cortex-a53"
_OPENWRT_TARGET="mediatek/filogic"
_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt"

# Настраиваем только если репозиторий ещё не переключён на зеркало
if [ ! -f "$_APK_REPO_FILE" ] || ! grep -q "tuna.tsinghua" "$_APK_REPO_FILE" 2>/dev/null; then
    echo "==> Настройка зеркала apk (TUNA, Китай)"
    mkdir -p /etc/apk
    cat > "$_APK_REPO_FILE" << REPOEOF
${_MIRROR}/releases/${_OPENWRT_VER}/targets/${_OPENWRT_TARGET}/packages
${_MIRROR}/releases/${_OPENWRT_VER}/packages/${_OPENWRT_ARCH}/base
${_MIRROR}/releases/${_OPENWRT_VER}/packages/${_OPENWRT_ARCH}/luci
${_MIRROR}/releases/${_OPENWRT_VER}/packages/${_OPENWRT_ARCH}/packages
${_MIRROR}/releases/${_OPENWRT_VER}/packages/${_OPENWRT_ARCH}/routing
REPOEOF
    apk update --quiet 2>/dev/null || true
fi

# ── Определяем источник файлов ────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo /tmp)"
LOCAL_PATCHES=""
LOCAL_AGH_CONFIG=""

# Ищем patches/ рядом со скриптом или в корне репозитория
if [ -f "$SELF_DIR/setup-clash.sh" ]; then
    LOCAL_PATCHES="$SELF_DIR"
elif [ -f "$SELF_DIR/patches/setup-clash.sh" ]; then
    LOCAL_PATCHES="$SELF_DIR/patches"
fi

# Ищем adguardhome/config.yaml (шаблон конфига AGH)
if [ -f "$SELF_DIR/adguardhome/config.yaml" ]; then
    LOCAL_AGH_CONFIG="$SELF_DIR/adguardhome/config.yaml"
elif [ -f "$SELF_DIR/../adguardhome/config.yaml" ]; then
    LOCAL_AGH_CONFIG="$(cd "$SELF_DIR/.." && pwd)/adguardhome/config.yaml"
fi

if [ -n "$LOCAL_PATCHES" ]; then
    echo "==> Режим: локальные файлы ($LOCAL_PATCHES)"
else
    echo "==> Режим: загрузка с GitHub ($REPO_RAW)"
fi
echo ""

# ── Запрос пароля ─────────────────────────────────────────────────────────
echo "==> Настройка пароля"
echo "    Пароль будет установлен для: SSH / LuCI (root) и AdGuard Home"
echo ""

ROUTER_PASS=""
while [ -z "$ROUTER_PASS" ]; do
    printf "    Введите пароль: "
    stty -echo < /dev/tty 2>/dev/null || true
    read -r ROUTER_PASS < /dev/tty
    stty echo < /dev/tty 2>/dev/null || true
    printf "\n"
    [ -z "$ROUTER_PASS" ] && echo "    Пароль не может быть пустым." && continue
    printf "    Подтвердите пароль: "
    stty -echo < /dev/tty 2>/dev/null || true
    read -r _PASS2 < /dev/tty
    stty echo < /dev/tty 2>/dev/null || true
    printf "\n"
    if [ "$ROUTER_PASS" != "$_PASS2" ]; then
        echo "    Пароли не совпадают. Попробуйте ещё раз."
        ROUTER_PASS=""
    fi
done
export ROUTER_PASS
echo "    Пароль принят."
echo ""

# ── Создаём рабочую директорию ────────────────────────────────────────────
rm -rf "$DEST"
mkdir -p "$DEST/luci/menu.d" "$DEST/luci/acl.d" "$DEST/luci/view/cf-optimizer" "$DEST/luci/view/adguardhome"

# Вспомогательная функция: загрузка или копирование файла
# $3=optional — предупреждение вместо ошибки если файл недоступен
fetch_file() {
    local src_rel="$1"   # относительный путь (patches/...)
    local dest="$2"
    local optional="${3:-}"

    mkdir -p "$(dirname "$dest")"

    if [ -n "$LOCAL_PATCHES" ] && [ -f "$LOCAL_PATCHES/$src_rel" ]; then
        cp "$LOCAL_PATCHES/$src_rel" "$dest"
        printf '    [local] %s\n' "$src_rel"
        return 0
    fi

    local url="$REPO_RAW/patches/$src_rel"
    if curl -fsSL --max-time 90 "$url" -o "$dest" 2>/dev/null; then
        printf '    [curl]  %s\n' "$src_rel"
    elif uclient-fetch -O "$dest" "$url" 2>/dev/null; then
        printf '    [fetch] %s\n' "$src_rel"
    elif [ "$optional" = "optional" ]; then
        printf '    [skip]  %s (не в репозитории — пропускаем)\n' "$src_rel"
        return 0
    else
        echo "ERROR: не удалось получить $src_rel"
        echo "       Проверь интернет или скопируй файлы вручную (scp -r . root@192.168.1.1:/tmp/router/)."
        rm -rf "$DEST"
        exit 1
    fi
}

# ── Загружаем / копируем патчи ────────────────────────────────────────────
echo "==> Подготовка файлов..."
for f in $PATCH_FILES; do
    [ -z "$f" ] && continue
    case "$f" in
        cf-ip-update.sh) fetch_file "$f" "$DEST/$f" optional ;;
        *)               fetch_file "$f" "$DEST/$f" ;;
    esac
done

# ── Загружаем шаблон конфига AGH ──────────────────────────────────────────
mkdir -p "$DEST/../adguardhome"
AGH_TEMPLATE="$DEST/../adguardhome/config.yaml"

if [ -n "$LOCAL_AGH_CONFIG" ]; then
    cp "$LOCAL_AGH_CONFIG" "$AGH_TEMPLATE"
    echo "    [local] adguardhome/config.yaml"
else
    url="$REPO_RAW/adguardhome/config.yaml"
    if curl -fsSL --max-time 90 "$url" -o "$AGH_TEMPLATE" 2>/dev/null; then
        echo "    [curl]  adguardhome/config.yaml"
    elif uclient-fetch -O "$AGH_TEMPLATE" "$url" 2>/dev/null; then
        echo "    [fetch] adguardhome/config.yaml"
    else
        echo "    [warn]  adguardhome/config.yaml не найден — будет создан минимальный конфиг"
    fi
fi

echo ""

# ── Шаг 1: Устанавливаем SSClash (Mihomo + TPROXY) ───────────────────────
echo "==> [1/4] SSClash: установка пакетов и бинарника Mihomo"
echo "    (kmod-nft-tproxy, ssclash APK, luci-app-ssclash, geo-базы)"
echo ""
chmod +x "$DEST/setup-clash.sh"
"$DEST/setup-clash.sh"

# ── Шаг 2: Копируем конфиг и запускаем SSClash ───────────────────────────
echo ""
echo "==> [2/4] Конфиг Mihomo: копируем config.yaml → /opt/clash/config.yaml"

CLASH_CONFIG_SRC=""
if [ -n "$LOCAL_PATCHES" ]; then
    # Ищем config.yaml в корне репозитория
    REPO_ROOT=""
    if [ -f "$LOCAL_PATCHES/../config.yaml" ]; then
        REPO_ROOT="$(cd "$LOCAL_PATCHES/.." && pwd)"
    elif [ -f "$LOCAL_PATCHES/config.yaml" ]; then
        REPO_ROOT="$LOCAL_PATCHES"
    fi
    [ -n "$REPO_ROOT" ] && CLASH_CONFIG_SRC="$REPO_ROOT/config.yaml"
fi

if [ -n "$CLASH_CONFIG_SRC" ] && [ -f "$CLASH_CONFIG_SRC" ]; then
    mkdir -p /opt/clash
    cp "$CLASH_CONFIG_SRC" /opt/clash/config.yaml
    echo "    config.yaml скопирован из $CLASH_CONFIG_SRC"
elif [ -f /opt/clash/config.yaml ]; then
    echo "    config.yaml уже есть на роутере — не перезаписываем"
else
    echo "    WARNING: config.yaml не найден — скопируйте вручную:"
    echo "      scp config.yaml root@192.168.1.1:/opt/clash/config.yaml"
fi

echo ""
echo "==> Запуск SSClash (Mihomo DNS :1053 + TPROXY :7894)..."
/etc/init.d/clash start 2>/dev/null || true
sleep 3
if /etc/init.d/clash status 2>/dev/null | grep -q running; then
    echo "    SSClash — запущен"
else
    echo "    INFO: SSClash не запущен (возможно, нет config.yaml — это нормально)"
    echo "         Скопируйте конфиг и запустите: scp config.yaml root@192.168.1.1:/opt/clash/config.yaml"
    echo "         /etc/init.d/clash start"
fi

# ── Шаг 3: Настраиваем AdGuard Home ──────────────────────────────────────
echo ""
echo "==> [3/4] AdGuard Home: настройка DNS, DHCP, пользователя, LuCI-страницы"
echo "    (AGH :53 → Mihomo :1053, dnsmasq DHCP-only, option 6=192.168.1.1)"
echo ""

# setup-adguardhome.sh использует $SCRIPT_DIR для поиска файлов
# Переносим его вместе с LuCI-файлами в DEST
chmod +x "$DEST/setup-adguardhome.sh"
"$DEST/setup-adguardhome.sh"

# ── Шаг 4: CF Optimizer (latency monitor, DPI bypass, watchdog) ───────────
echo ""
echo "==> [4/4] Proxy Optimizer: latency-monitor, DPI bypass, watchdog, cron"
echo ""
chmod +x "$DEST/setup-cf-optimizer.sh"
"$DEST/setup-cf-optimizer.sh"

# ── Итог ──────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo " Установка завершена!"
echo "=================================================="
echo ""
echo " Порядок старта после перезагрузки:"
echo "   AGH (19) → dnsmasq (20) → SSClash/Mihomo (21)"
echo ""
echo " DNS-цепочка:"
echo "   Клиенты → AGH :53 → Mihomo :1053 → интернет"
echo ""
echo " Проверка:"
echo "   ss -tlunp | grep -E '(:53|:3000|:7894|:1053|:9090)'"
echo "   nslookup google.com 127.0.0.1   # ожидается 198.18.x.x (fake-ip)"
echo "   nslookup yandex.ru 127.0.0.1    # ожидается реальный IP"
echo ""
echo " WiFi настройка (интерактивно, запускать отдельно):"
echo "   wifi-optimize.sh"
echo ""
echo " После проверки перезагрузитесь:"
echo "   reboot"
echo ""

# Чистка
rm -rf "$DEST"
