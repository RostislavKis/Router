# CF IP Optimizer — Автономная оптимизация Cloudflare IP на роутере

Проект: встроенная система автоматического выбора оптимальных Cloudflare edge IP
для роутера GL-iNet Flint 2 (GL-MT6000) с Mihomo/SSClash.

## Концепция

Когда VPN-сервер работает за Cloudflare CDN (VLESS/Trojan через CF Worker или CDN proxy),
клиент подключается не напрямую к серверу, а к одному из тысяч Cloudflare edge IP.
Выбор конкретного edge IP влияет на задержку, стабильность и то, блокирует ли его провайдер.

Этот проект автоматизирует:
1. Получение свежих CF edge IP по нужным странам
2. Тест доступности и задержки через реальный туннель Mihomo
3. Выбор лучшего SNI для соединения
4. DPI bypass через nftables MSS clamping
5. Обновление конфига Mihomo без перезапуска сервиса

## Архитектура

```
cron (каждые 6 часов)
    |
    +-- cf-ip-update.sh          Блок 1: получить лучший IP
    |       |
    |       +-- curl -> CF Worker API (Cloudflare-Country-Specific-IP-Filter)
    |       |   Возвращает список edge IP по странам (FI, DE, NL, ...)
    |       |
    |       +-- TCP тест каждого IP: curl --connect-timeout 2 https://IP:443
    |       |
    |       +-- curl PATCH -> Mihomo REST API :9090
    |               Обновляет server: без перезапуска
    |
    +-- sni-scan.sh              Блок 2: найти лучший SNI
            |
            +-- curl --socks5 127.0.0.1:7891 -> https://cp.cloudflare.com/generate_204
            |   (тест идёт ЧЕРЕЗ Mihomo SOCKS5 — реальный туннель)
            |
            +-- curl PATCH -> Mihomo REST API :9090
                    Обновляет sni: без перезапуска

При старте системы (один раз):
    nftables MSS rule              Блок 3: DPI bypass
        meta mark 2 + port 443 -> MSS = 40-100 байт
        Только трафик Mihomo (routing-mark: 2), не затрагивает остальных

Опционально — Xray aarch64:       Блок 4: TLS fragment
    Xray socks5 :10801 с fragment {tlshello, length: 10-20}
    Mihomo dialer-proxy -> Xray -> CF edge IP
```

## Взаимодействие компонентов

```
Устройства LAN
    | DNS  -> AGH :53 -> Mihomo DNS :1053 -> DoH
    | трафик -> nftables TPROXY -> Mihomo :7894
    |
    v
Mihomo (SSClash) — центральный узел
    |
    +-- REST API :9090           <- cf-ip-update.sh и sni-scan.sh пишут сюда
    +-- SOCKS5  :7891            <- sni-scan.sh тестирует через него
    +-- TPROXY  :7894            <- весь LAN трафик
    |
    v
nftables MSS clamping (mark=2, port=443)
    |
    v
[опц. Xray :10801 с TLS fragment]
    |
    v
Cloudflare edge IP (оптимальный, обновляется автоматически)
    |
    v
VPN сервер (за CF CDN)
```

## Блок 1 — CF IP Updater

### Источник данных

Cloudflare-Country-Specific-IP-Filter — Cloudflare Worker с публичным API.
Возвращает edge IP из базы community-листов, отфильтрованные по стране.

API endpoint (пример):
```
https://YOUR_WORKER.workers.dev/api=1&region=FI,DE,NL&format=line&limit=10
```

Ответ:
```
104.21.45.2:443
172.67.12.55:2053
104.21.89.11:443
...
```

### Алгоритм скрипта

```sh
#!/bin/sh
# /usr/local/bin/cf-ip-update.sh

WORKER_URL="https://YOUR_WORKER.workers.dev"
REGIONS="FI,DE,NL"
LIMIT=10
PROXY_NAME="MY_VLESS"
MIHOMO_API="http://127.0.0.1:9090"
MIHOMO_SECRET="YOUR_API_SECRET"

# 1. Получить список IP от Worker API
IP_LIST=$(curl -sf --max-time 10 \
    "${WORKER_URL}?api=1&region=${REGIONS}&format=line&limit=${LIMIT}" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$')

if [ -z "$IP_LIST" ]; then
    logger -t cf-ip-update "ERROR: failed to fetch IP list"
    exit 1
fi

# 2. TCP тест каждого IP, найти лучший
BEST_IP=""
BEST_TIME=99999

for ENTRY in $IP_LIST; do
    IP=$(echo "$ENTRY" | cut -d: -f1)
    PORT=$(echo "$ENTRY" | cut -d: -f2)

    # Измерить время TCP-соединения в мс
    T=$(curl -sf -o /dev/null -w "%{time_connect}" \
        --connect-timeout 2 \
        "https://${IP}:${PORT}" 2>/dev/null \
        | awk '{printf "%d", $1 * 1000}')

    [ -z "$T" ] && T=99999

    if [ "$T" -lt "$BEST_TIME" ] 2>/dev/null; then
        BEST_TIME=$T
        BEST_IP=$IP
        BEST_PORT=$PORT
    fi
done

if [ -z "$BEST_IP" ]; then
    logger -t cf-ip-update "ERROR: no reachable IP found"
    exit 1
fi

logger -t cf-ip-update "Best IP: ${BEST_IP}:${BEST_PORT} (${BEST_TIME}ms)"

# 3. Обновить Mihomo через REST API (без перезапуска)
curl -sf -X PATCH "${MIHOMO_API}/proxies/${PROXY_NAME}" \
    -H "Authorization: Bearer ${MIHOMO_SECRET}" \
    -H "Content-Type: application/json" \
    -d "{\"server\": \"${BEST_IP}\", \"port\": ${BEST_PORT}}"

logger -t cf-ip-update "Updated proxy ${PROXY_NAME} -> ${BEST_IP}:${BEST_PORT}"
```

## Блок 2 — SNI Scanner

Тест через реальный SOCKS5-туннель Mihomo — результат честный,
так как трафик идёт через само прокси-соединение.

```sh
#!/bin/sh
# /usr/local/bin/sni-scan.sh

PROXY_NAME="MY_VLESS"
MIHOMO_API="http://127.0.0.1:9090"
MIHOMO_SECRET="YOUR_API_SECRET"
MIHOMO_SOCKS="127.0.0.1:7891"

SNI_LIST="
cdn.cloudflare.com
workers.dev
pages.dev
cloudflaressl.com
one.one.one.one
"

BEST_SNI=""
BEST_TIME=99999

for SNI in $SNI_LIST; do
    [ -z "$SNI" ] && continue

    # Обновить SNI в прокси
    curl -sf -X PATCH "${MIHOMO_API}/proxies/${PROXY_NAME}" \
        -H "Authorization: Bearer ${MIHOMO_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\"sni\": \"${SNI}\"}" > /dev/null

    sleep 0.3

    # Тест через Mihomo SOCKS5 (реальный туннель)
    T=$(curl -sf -o /dev/null -w "%{time_connect}" \
        --socks5 "${MIHOMO_SOCKS}" \
        --connect-timeout 3 \
        "https://cp.cloudflare.com/generate_204" 2>/dev/null \
        | awk '{printf "%d", $1 * 1000}')

    [ -z "$T" ] && T=99999

    logger -t sni-scan "SNI ${SNI}: ${T}ms"

    if [ "$T" -lt "$BEST_TIME" ] 2>/dev/null; then
        BEST_TIME=$T
        BEST_SNI=$SNI
    fi
done

if [ -n "$BEST_SNI" ]; then
    # Применить лучший SNI
    curl -sf -X PATCH "${MIHOMO_API}/proxies/${PROXY_NAME}" \
        -H "Authorization: Bearer ${MIHOMO_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\"sni\": \"${BEST_SNI}\"}"

    logger -t sni-scan "Best SNI: ${BEST_SNI} (${BEST_TIME}ms)"
fi
```

## Блок 3 — DPI Bypass (nftables MSS clamping)

Применяется только к трафику Mihomo — через routing-mark: 2.
LAN-трафик и прочие соединения не затрагиваются.

TLS ClientHello разбивается на несколько сегментов — DPI не может
прочитать SNI из первого пакета.

Добавить в /etc/nftables.d/99-cf-dpi-bypass.nft:

```nft
# DPI bypass для Mihomo outbound (routing-mark: 2)
# MSS 100 байт — разбивает TLS ClientHello без сильного влияния на скорость
table inet cf_dpi_bypass {
    chain output {
        type filter hook output priority mangle; policy accept;
        meta mark 2 tcp dport 443 tcp option maxseg size set 100
        meta mark 2 tcp dport 2053 tcp option maxseg size set 100
        meta mark 2 tcp dport 2083 tcp option maxseg size set 100
        meta mark 2 tcp dport 2087 tcp option maxseg size set 100
    }
}
```

Применить сразу:
```sh
nft -f /etc/nftables.d/99-cf-dpi-bypass.nft
```

При перезагрузке применяется автоматически через nftables.

Выбор значения MSS:
- 40  байт — максимальная фрагментация, +20-40 мс к handshake
- 100 байт — баланс защиты и скорости (рекомендуется)
- 200 байт — минимальная фрагментация, почти без влияния на скорость

## Блок 4 — Xray TLS Fragment (опционально)

Нужен только если MSS clamping недостаточен.
Xray делает фрагментацию на уровне приложения (только tlshello).

### Установка Xray aarch64

```sh
# Скачать бинарь Xray для linux-arm64
curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" \
    -o /tmp/xray.zip
unzip /tmp/xray.zip -d /tmp/xray/
cp /tmp/xray/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
```

### Конфиг Xray как fragment-proxy

/etc/xray-fragment.json:
```json
{
    "log": {"loglevel": "none"},
    "inbounds": [{
        "port": 10801,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": false}
    }],
    "outbounds": [{
        "protocol": "freedom",
        "tag": "fragment-out",
        "settings": {
            "fragment": {
                "packets": "tlshello",
                "length": "10-20",
                "interval": "10-20"
            }
        },
        "streamSettings": {
            "sockopt": {"tcpNoDelay": true}
        }
    }]
}
```

Запуск:
```sh
xray -c /etc/xray-fragment.json &
```

### Привязка к Mihomo через dialer-proxy

В /opt/clash/config.yaml добавить proxy:
```yaml
proxies:
  - name: "xray-fragment"
    type: socks5
    server: 127.0.0.1
    port: 10801

  - name: "MY_VLESS"
    type: vless
    server: CF_EDGE_IP
    port: 443
    dialer-proxy: "xray-fragment"   # <-- цепочка через Xray
    # ... остальные параметры
```

Трафик: Mihomo -> Xray :10801 (fragment) -> CF edge IP

## Настройка cron

```sh
# Редактировать crontab
crontab -e

# Добавить:
# Обновление IP каждые 6 часов
0 */6 * * * /usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1

# SNI сканирование раз в сутки (после обновления IP)
30 0 * * * /usr/local/bin/sni-scan.sh >> /var/log/sni-scan.log 2>&1
```

## Файлы проекта

```
patches/
    cf-ip-update.sh      Блок 1: обновление CF edge IP
    sni-scan.sh          Блок 2: сканирование SNI
    99-cf-dpi-bypass.nft Блок 3: DPI bypass через nftables MSS
    xray-fragment.json   Блок 4: конфиг Xray fragment-proxy (опц.)
    setup-cf-optimizer.sh Установщик всего выше
```

## Плюсы и минусы

### Плюсы

- Полностью автономно — роутер сам обновляет IP раз в 6 часов
- Mihomo не перезапускается — устройства не теряют соединение
- MSS clamping точечно — только трафик Mihomo (mark=2), остальной не затронут
- SNI тест через реальный туннель — честный результат
- Нет тяжёлых зависимостей без Xray — только curl и ash
- AGH и DNS-цепочка не затрагиваются

### Минусы

- TCP тест != speed test — доступный IP может быть медленным
  Решение: добавить curl download через SOCKS5 для замера пропускной способности
- MSS clamping добавляет +10-30 мс к TLS handshake (только к установке соединения)
  Решение: MSS=100 вместо 40 — баланс защиты и скорости
- PATCH /proxies через Mihomo API — не все параметры обновляются на лету
  Решение: fallback через перезапись config.yaml + PUT /configs?force=true
- Xray (+30 МБ RAM) — рядом с Mihomo (~80 МБ) суммарно ~110 МБ из 512 МБ
  Допустимо, но нужен мониторинг
- Worker API — внешняя зависимость на zip.cm.edu.kg
  Решение: хардкоженный fallback список IP в скрипте

## Приоритет внедрения для России

1. Блок 1 (IP updater) — наибольший практический эффект, внедрить первым
2. Блок 3 (MSS nftables) — бесплатно по ресурсам, рекомендуется включить
3. Блок 2 (SNI scanner) — тонкая настройка, менее критично
4. Блок 4 (Xray fragment) — только если провайдер активно блокирует по SNI
