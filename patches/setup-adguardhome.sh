#!/bin/sh
# setup-adguardhome.sh
# Настройка AdGuard Home для работы с Mihomo (SSClash) fake-ip DNS.
#
# Что делает:
#   1. Устанавливает пароль root (LuCI + AGH используют один пароль)
#   2. Отключает dnsmasq на порту 53 (AGH занимает порт 53)
#   3. Настраивает DHCP: клиенты получают 192.168.1.1 как DNS-сервер (= AGH)
#   4. Указывает UCI adguardhome путь к config.yaml
#   5. Разворачивает конфиг AGH (из шаблона или патчит существующий):
#      - upstream DNS → Mihomo 127.0.0.1:1053 (fake-ip)
#      - aaaa_disabled: true (Mihomo работает без IPv6)
#      - Устанавливает логин/пароль
#   6. Устанавливает LuCI-страницу AGH (iframe → порт 3000)
#
# Использование:
#   chmod +x setup-adguardhome.sh && ./setup-adguardhome.sh
#
# Запуск через SSH:
#   scp -r patches/ root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 "chmod +x /tmp/patches/setup-adguardhome.sh && /tmp/patches/setup-adguardhome.sh"

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGH_CONFIG="/etc/adguardhome/config.yaml"

# ============================================================
# ПАРОЛЬ РОУТЕРА (используется для LuCI и AGH)
# Задаётся ОДИН РАЗ — скрипт устанавливает его везде.
#
# Для смены пароля:
#   1. Измените ROUTER_PASSWORD ниже
#   2. Пересчитайте bcrypt-хэш:
#      python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASS', bcrypt.gensalt(10)).decode())"
#   3. Замените AGH_PASSWORD_HASH
# ============================================================
ROUTER_PASSWORD="4bu-j6m-7Bf-5JK"
AGH_USER="root"
# bcrypt-хэш от ROUTER_PASSWORD (для AGH):
AGH_PASSWORD_HASH='$2b$10$lOOoSmdzB2jZQ73mugmktOQ6L//NzV.RGbzGzbND7w6HptAqIkHB.'
_PLACEHOLDER_HASH='$2y$10$REPLACE_THIS_WITH_YOUR_BCRYPT_HASH'
# ============================================================

echo "==> AdGuard Home: настройка"
echo ""

# --- 1. Устанавливаем пароль root (LuCI) ---
echo "==> [1/6] Установка пароля root (LuCI)"
printf '%s\n%s\n' "$ROUTER_PASSWORD" "$ROUTER_PASSWORD" | passwd root 2>/dev/null \
    && echo "    пароль root — установлен" \
    || echo "    WARNING: не удалось установить пароль root"

# --- 2. dnsmasq: отключаем DNS, оставляем только DHCP ---
echo ""
echo "==> [2/6] dnsmasq: порт 53 → 0 (AGH занимает DNS)"
uci set dhcp.@dnsmasq[0].port='0'
echo "    dnsmasq port=0 (DNS отключён, только DHCP)"

# --- 3. DHCP: клиенты должны использовать роутер как DNS ---
echo ""
echo "==> [3/6] DHCP option 6 → 192.168.1.1 (AGH как DNS для клиентов)"
# Без этого dnsmasq с port=0 отдаёт клиентам DNS провайдера вместо AGH
uci -q delete dhcp.lan.dhcp_option 2>/dev/null || true
uci add_list dhcp.lan.dhcp_option='6,192.168.1.1'
uci commit dhcp
/etc/init.d/dnsmasq restart 2>/dev/null || true
echo "    dhcp_option 6,192.168.1.1 → клиенты получат AGH как DNS"

# --- 4. UCI: указываем путь к конфигу AGH ---
echo ""
echo "==> [4/6] UCI adguardhome → $AGH_CONFIG"
uci set adguardhome.config.config_file="$AGH_CONFIG"
uci commit adguardhome
echo "    adguardhome.config.config_file=$AGH_CONFIG"

# --- 5. Конфиг AGH ---
echo ""
echo "==> [5/6] Конфиг AdGuard Home: $AGH_CONFIG"

# Если конфига нет — разворачиваем из шаблона или создаём минимальный
if [ ! -f "$AGH_CONFIG" ]; then
    mkdir -p "$(dirname "$AGH_CONFIG")"
    CONFIG_TEMPLATE="$SCRIPT_DIR/../adguardhome/config.yaml"
    if [ -f "$CONFIG_TEMPLATE" ]; then
        cp "$CONFIG_TEMPLATE" "$AGH_CONFIG"
        echo "    Скопирован шаблон из $CONFIG_TEMPLATE"
    else
        # Минимальный конфиг (если шаблон не найден рядом)
        cat > "$AGH_CONFIG" << 'MINIMALCONFIG'
http:
  address: 0.0.0.0:3000
  session_ttl: 720h
users: []
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - 127.0.0.1:1053
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  aaaa_disabled: true
  cache_enabled: true
  cache_size: 4194304
filtering:
  filtering_enabled: true
  protection_enabled: true
schema_version: 33
MINIMALCONFIG
        echo "    Создан минимальный конфиг (шаблон не найден)"
    fi
fi

# Бэкап
cp "$AGH_CONFIG" "${AGH_CONFIG}.bak"
echo "    Резервная копия: ${AGH_CONFIG}.bak"

# Патчим upstream_dns → Mihomo 127.0.0.1:1053
if grep -q 'upstream_dns:' "$AGH_CONFIG"; then
    awk '
        /upstream_dns:/ { print; in_upstream=1; next }
        in_upstream && /^    - / {
            if (!replaced) { print "    - 127.0.0.1:1053"; replaced=1 }
            next
        }
        in_upstream && !/^    - / { in_upstream=0; replaced=0 }
        { print }
    ' "$AGH_CONFIG" > "${AGH_CONFIG}.tmp" && mv "${AGH_CONFIG}.tmp" "$AGH_CONFIG"
    echo "    upstream_dns → 127.0.0.1:1053 (Mihomo fake-ip DNS)"
else
    echo "    WARNING: upstream_dns не найден в конфиге"
fi

# Отключаем AAAA (Mihomo работает без IPv6)
sed -i 's/aaaa_disabled: false/aaaa_disabled: true/' "$AGH_CONFIG"
echo "    aaaa_disabled → true"

# Устанавливаем пользователя и пароль (пропускаем если хэш-плейсхолдер)
if [ "$AGH_PASSWORD_HASH" = "$_PLACEHOLDER_HASH" ]; then
    echo "    пароль не задан — установите через веб-интерфейс AGH (порт 3000)"
elif grep -q 'users:' "$AGH_CONFIG"; then
    awk -v user="$AGH_USER" -v hash="$AGH_PASSWORD_HASH" '
        /^users:/ { print; in_users=1; next }
        in_users && /^  - name:/ { print "  - name: " user; next }
        in_users && /^    password:/ { print "    password: " hash; in_users=0; next }
        { print }
    ' "$AGH_CONFIG" > "${AGH_CONFIG}.tmp" && mv "${AGH_CONFIG}.tmp" "$AGH_CONFIG"
    echo "    admin пользователь → $AGH_USER"
    echo "    пароль → задан (bcrypt)"
else
    # Добавляем пользователя если секции users нет или она пустая
    awk -v user="$AGH_USER" -v hash="$AGH_PASSWORD_HASH" '
        /^users: \[\]/ {
            print "users:"
            print "  - name: " user
            print "    password: " hash
            next
        }
        { print }
    ' "$AGH_CONFIG" > "${AGH_CONFIG}.tmp" && mv "${AGH_CONFIG}.tmp" "$AGH_CONFIG"
    echo "    admin пользователь добавлен: $AGH_USER"
fi

# Перезапуск AGH
echo ""
echo "==> Перезапуск AdGuard Home..."
/etc/init.d/adguardhome restart
sleep 2
/etc/init.d/adguardhome status 2>/dev/null && echo "    AGH запущен" || echo "    WARNING: AGH не запущен"

# --- 6. LuCI: устанавливаем меню и iframe-страницу ---
echo ""
echo "==> [6/6] LuCI-страница AdGuard Home (iframe → порт 3000)"

MENU_SRC="$SCRIPT_DIR/luci/menu.d/luci-app-adguardhome.json"
MENU_DST="/usr/share/luci/menu.d/luci-app-adguardhome.json"
VIEW_SRC="$SCRIPT_DIR/luci/view/adguardhome/dashboard.js"
VIEW_DST="/www/luci-static/resources/view/adguardhome/dashboard.js"

if [ -f "$MENU_SRC" ]; then
    cp "$MENU_SRC" "$MENU_DST"
    chmod 644 "$MENU_DST"
    echo "    menu.d/luci-app-adguardhome.json — установлен"
else
    cat > "$MENU_DST" << 'MENUJSON'
{
	"admin/services/adguardhome": {
		"title": "AdGuard Home",
		"order": 15,
		"action": {
			"type": "alias",
			"path": "admin/services/adguardhome/dashboard"
		}
	},
	"admin/services/adguardhome/dashboard": {
		"title": "Overview",
		"order": 10,
		"action": {
			"type": "view",
			"path": "adguardhome/dashboard"
		}
	}
}
MENUJSON
    chmod 644 "$MENU_DST"
    echo "    menu.d/luci-app-adguardhome.json — создан (встроенный)"
fi

if [ -f "$VIEW_SRC" ]; then
    mkdir -p "$(dirname "$VIEW_DST")"
    cp "$VIEW_SRC" "$VIEW_DST"
    chmod 644 "$VIEW_DST"
    echo "    view/adguardhome/dashboard.js — установлен (iframe :3000)"
fi

rm -rf /tmp/luci-*
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
echo "    LuCI кэш очищен, rpcd/uhttpd перезапущены"

echo ""
echo "=================================================="
echo " AdGuard Home настроен!"
echo "=================================================="
echo ""
echo " DNS-цепочка:"
echo "   Клиенты → AGH :53 → Mihomo :1053 → интернет"
echo ""
echo " Проверка:"
echo "   nslookup google.com 127.0.0.1"
echo "   # Ожидается: 198.18.x.x (fake-ip → через прокси)"
echo ""
echo "   nslookup yandex.ru 127.0.0.1"
echo "   # Ожидается: реальный IP (прямое подключение)"
echo ""
