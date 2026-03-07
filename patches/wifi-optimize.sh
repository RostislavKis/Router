#!/bin/sh
# wifi-optimize.sh
# Настройка WiFi на GL-MT6000 (OpenWrt):
#   - Интерактивный запрос имён сетей и паролей
#   - Максимальная мощность: страна BO (Bolivia), 30 dBm на 5 GHz
#   - 2.4 GHz: ch6, HE40 (40 MHz), 20 dBm
#   - 5 GHz:   ch149, HE80 (80 MHz), 30 dBm = 1000 мВт
#
# Использование:
#   chmod +x wifi-optimize.sh && ./wifi-optimize.sh
#
# Запуск через SSH:
#   scp patches/wifi-optimize.sh root@192.168.1.1:/tmp/
#   ssh -t root@192.168.1.1 "chmod +x /tmp/wifi-optimize.sh && /tmp/wifi-optimize.sh"
#   (флаг -t нужен для интерактивного ввода)

set -e

if [ "$1" = "--show" ]; then
    echo "=== Текущий статус WiFi ==="
    iwinfo 2>/dev/null | grep -E "(ESSID|Tx-Power|Channel|HT Mode|Bit Rate)" || true
    exit 0
fi

echo "==> WiFi: настройка имён сетей, паролей и оптимизация мощности"
echo ""

# Находим UCI-интерфейсы для 2.4 и 5 GHz
IFACE_2G=$(uci show wireless 2>/dev/null | awk -F'[.=]' '/\.device=/ && /radio0/ {print $2; exit}')
IFACE_5G=$(uci show wireless 2>/dev/null | awk -F'[.=]' '/\.device=/ && /radio1/ {print $2; exit}')

[ -z "$IFACE_2G" ] && IFACE_2G="default_radio0"
[ -z "$IFACE_5G" ] && IFACE_5G="default_radio1"

# Текущие значения
CURRENT_SSID_2G=$(uci -q get wireless.${IFACE_2G}.ssid 2>/dev/null || echo "Flint-2")
CURRENT_SSID_5G=$(uci -q get wireless.${IFACE_5G}.ssid 2>/dev/null || echo "Flint-2-5G")
CURRENT_KEY_2G=$(uci -q get wireless.${IFACE_2G}.key 2>/dev/null || echo "")
CURRENT_KEY_5G=$(uci -q get wireless.${IFACE_5G}.key 2>/dev/null || echo "")

echo "Текущие WiFi сети:"
echo "  2.4 GHz: \"$CURRENT_SSID_2G\"  (интерфейс: $IFACE_2G)"
echo "  5 GHz:   \"$CURRENT_SSID_5G\"  (интерфейс: $IFACE_5G)"
echo ""
echo "Нажмите Enter чтобы оставить текущее значение."
echo ""

# ---- Ввод 2.4 GHz ----
printf "Имя сети 2.4 GHz [%s]: " "$CURRENT_SSID_2G"
read -r WIFI_SSID_2G
[ -z "$WIFI_SSID_2G" ] && WIFI_SSID_2G="$CURRENT_SSID_2G"

printf "Пароль 2.4 GHz (мин. 8 символов) [оставить]: "
stty -echo 2>/dev/null || true
read -r WIFI_KEY_2G
stty echo 2>/dev/null || true
echo ""

if [ -z "$WIFI_KEY_2G" ]; then
    WIFI_KEY_2G="$CURRENT_KEY_2G"
elif [ ${#WIFI_KEY_2G} -lt 8 ]; then
    echo "ОШИБКА: пароль должен быть минимум 8 символов"
    exit 1
fi

# ---- Ввод 5 GHz ----
echo ""
printf "Имя сети 5 GHz [%s]: " "$CURRENT_SSID_5G"
read -r WIFI_SSID_5G
[ -z "$WIFI_SSID_5G" ] && WIFI_SSID_5G="$CURRENT_SSID_5G"

printf "Пароль 5 GHz (мин. 8 символов) [оставить / пустой = тот же что 2.4G]: "
stty -echo 2>/dev/null || true
read -r WIFI_KEY_5G
stty echo 2>/dev/null || true
echo ""

if [ -z "$WIFI_KEY_5G" ]; then
    WIFI_KEY_5G="${WIFI_KEY_2G}"
elif [ ${#WIFI_KEY_5G} -lt 8 ]; then
    echo "ОШИБКА: пароль должен быть минимум 8 символов"
    exit 1
fi

echo ""
echo "==> Применяем настройки:"
echo "  2.4 GHz: \"$WIFI_SSID_2G\"  ch6  HE40  20 dBm"
echo "  5 GHz:   \"$WIFI_SSID_5G\"  ch149 HE80 30 dBm"
echo ""

# ---- Включаем отключённые SSID (после factory reset) ----
for iface in $(uci show wireless 2>/dev/null | grep '\.disabled=1' | cut -d. -f2 | grep -v '^radio'); do
    uci set wireless.${iface}.disabled='0'
done

# ---- SSID и пароли ----
uci set wireless.${IFACE_2G}.ssid="$WIFI_SSID_2G"
uci set wireless.${IFACE_2G}.encryption='psk2'
[ -n "$WIFI_KEY_2G" ] && uci set wireless.${IFACE_2G}.key="$WIFI_KEY_2G"

uci set wireless.${IFACE_5G}.ssid="$WIFI_SSID_5G"
uci set wireless.${IFACE_5G}.encryption='psk2'
[ -n "$WIFI_KEY_5G" ] && uci set wireless.${IFACE_5G}.key="$WIFI_KEY_5G"

# ---- 2.4 GHz оптимизация ----
uci set wireless.radio0.country='BO'
uci set wireless.radio0.channel='6'
uci set wireless.radio0.htmode='HE40'
uci delete wireless.radio0.txpower 2>/dev/null || true
# noscan: не снижать ширину канала из-за соседних точек
uci set wireless.radio0.noscan='1'

# ---- 5 GHz оптимизация ----
uci set wireless.radio1.country='BO'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci delete wireless.radio1.txpower 2>/dev/null || true
uci set wireless.radio1.noscan='1'

uci commit wireless

echo "==> Применяем (wifi reload)..."
wifi reload
sleep 6

echo ""
echo "=== Новый статус ==="
iwinfo 2>/dev/null | grep -E "(ESSID|Tx-Power|Channel|HT Mode)" || true

echo ""
echo "==> Готово!"
echo "  2.4 GHz  \"$WIFI_SSID_2G\"  ch6  HE40  20 dBm  (100 мВт)"
echo "  5 GHz    \"$WIFI_SSID_5G\"  ch149 HE80 30 dBm  (1000 мВт — 10x!)"
