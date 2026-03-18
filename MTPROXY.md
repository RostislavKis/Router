# MTProxy на OpenWrt — полный гайд

MTProxy (mtg v2) — Telegram-прокси с FakeTLS-маскировкой. Разворачивается на роутере, позволяет устройствам подключаться к Telegram без VPN.

---

## Системные требования

- OpenWrt 21+ (тестировалось на 25.12.0, aarch64_cortex-a53 / GL-iNet Flint 2)
- Внешний статический IP на WAN или DDNS
- SSH-доступ к роутеру
- Опционально: Mihomo/Clash (если Telegram заблокирован у провайдера)

---

## Шаг 1 — Получить бинарник mtg

Страница релизов: `https://github.com/9seconds/mtg/releases`
Нужен файл для архитектуры роутера:

| Архитектура | Файл |
|---|---|
| aarch64 (GL-MT6000, MT3000 и др.) | `mtg-2.x.x-linux-arm64` |
| x86_64 (x86-роутеры) | `mtg-2.x.x-linux-amd64` |
| armv7 (RT3200 и др.) | `mtg-2.x.x-linux-arm-7` |

### Способ A: Прямая загрузка (если роутер достаёт GitHub)

```bash
wget -O /usr/local/bin/mtg \
  https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-arm64
chmod +x /usr/local/bin/mtg
mtg --version
```

> **Проблема на свежем OpenWrt**: `wget` может быть симлинком на `wget-nossl` (без HTTPS).
> **Фикс**: `ln -sf /bin/uclient-fetch /usr/bin/wget`

### Способ B: Через PC → SCP  GitHub заблокирован

```bash
# На PC: скачать бинарник, затем передать на роутер
scp mtg-2.1.7-linux-arm64 root@192.168.1.1:/usr/local/bin/mtg
ssh root@192.168.1.1 "chmod +x /usr/local/bin/mtg && mtg --version"
```

### Способ C: Python + paramiko (SCP через скрипт)

```python
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("192.168.1.1", username="root", password="YOUR_SSH_PASSWORD")

sftp = ssh.open_sftp()
sftp.put("mtg-2.1.7-linux-arm64", "/usr/local/bin/mtg")
sftp.close()

stdin, stdout, stderr = ssh.exec_command("chmod +x /usr/local/bin/mtg && mtg --version")
print(stdout.read().decode())
ssh.close()
```

---

## Шаг 2 — Сгенерировать FakeTLS секрет

```bash
ssh root@192.168.1.1 "/usr/local/bin/mtg generate-secret google.com"
```

Вывод — строка вида: `7hk3Z6AyCsbpu4aLoUPQ9J1nb29nbGUuY29t`

Сохраните её — понадобится на следующем шаге и при добавлении прокси в Telegram.

> **Важно**: mtg v2 требует FakeTLS-секрет, сгенерированный командой выше.
> Случайный hex (`dd if=/dev/urandom ...`) приведёт к ошибке `incorrect first byte of secret`.

---

## Шаг 3 — Создать init.d сервис

### Вариант A: С SOCKS5 через Mihomo/Clash

Используйте если Telegram заблокирован у провайдера и уже настроен Mihomo.

```sh
cat > /etc/init.d/mtg << 'EOF'
#!/bin/sh /etc/rc.common

START=96
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/mtg simple-run \
        -i prefer-ipv4 \
        -s socks5://SOCKS5_USER:SOCKS5_PASSWORD@127.0.0.1:SOCKS5_PORT \
        0.0.0.0:443 \
        YOUR_FAKEТLS_SECRET
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF

chmod +x /etc/init.d/mtg
```

**Параметры Mihomo:**

| Параметр | Значение |
|---|---|
| `SOCKS5_USER:SOCKS5_PASSWORD` | Из блока `authentication:` в config.yaml Mihomo |
| `SOCKS5_PORT` | Значение `socks-port:` из config.yaml (чистый SOCKS5) |

> Если в config.yaml только `mixed-port:` (без `socks-port:`), используйте `mixed-port` значение.

Проверить порты Mihomo:
```bash
grep -E 'mixed-port|socks-port' /opt/clash/config.yaml
```

### Вариант B: Без прокси (прямое подключение к Telegram DC)

Используйте если:
- Telegram не заблокирован у провайдера
- Роутер подключён через VPN и Telegram DC доступен напрямую

```sh
cat > /etc/init.d/mtg << 'EOF'
#!/bin/sh /etc/rc.common

START=96
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/mtg simple-run \
        -i prefer-ipv4 \
        0.0.0.0:443 \
        YOUR_FAKEТLS_SECRET
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF

chmod +x /etc/init.d/mtg
```

### Как проверить — нужен ли прокси?

```bash
# Если curl возвращает пустоту или ошибку — Telegram DC недоступен напрямую
curl -m5 -s --connect-timeout 3 \
  https://149.154.164.14 -o /dev/null -w '%{http_code}\n'
# 200 или 4xx = доступен → Вариант B
# 000 или timeout = заблокирован → Вариант A (через Mihomo)
```

---

## Шаг 4 — Открыть порт в firewall

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-MTProxy'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='443'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

Проверить что правило применилось:
```bash
nft list ruleset | grep -A1 'MTProxy'
# Должно быть: tcp dport 443 ... accept
```

> **Порт 443**: рекомендуется, так как FakeTLS маскируется под HTTPS и не блокируется фильтрами.
> Можно использовать любой другой открытый порт.

---

## Шаг 5 — Запустить сервис

```bash
/etc/init.d/mtg enable   # автозапуск при старте роутера
/etc/init.d/mtg start    # запустить сейчас

# Проверить статус
/etc/init.d/mtg status
ps | grep mtg | grep -v grep
netstat -tlnp | grep :443
```

---

## Шаг 6 — Добавить прокси в Telegram

**Метод 1**: Открыть ссылку в браузере на устройстве:
```
tg://proxy?server=ВАШ_ВНЕШНИЙ_IP&port=443&secret=ВАШ_СЕКРЕТ
```

**Метод 2**: Вручную через Settings → Privacy and Security → Data and Storage → Proxy Settings → Add Proxy → MTProto.

---

## Диагностика

### Сервис не запускается

```bash
logread | grep mtg | tail -20
/etc/init.d/mtg stop
# Запустить вручную для вывода ошибок в консоль:
/usr/local/bin/mtg simple-run -i prefer-ipv4 0.0.0.0:443 YOUR_SECRET
```

### Проверить работу SOCKS5 прокси (Вариант A)

Mihomo слушает на `:::PORT` (IPv6 wildcard), но IPv4-подключения (`127.0.0.1`) обычно работают через IPv4-mapped адреса. Проверить через HTTP прокси (curl на OpenWrt поддерживает HTTP CONNECT, но не SOCKS5):

```bash
# Тест HTTP прокси (mixed-port поддерживает HTTP CONNECT + SOCKS5)
curl -m5 -x http://SOCKS5_USER:SOCKS5_PASSWORD@127.0.0.1:7890 \
  -s http://ip-api.com/json | grep '"query"'
# Должен вернуть IP прокси-сервера (не IP роутера)
```

### Проверить что Mihomo маршрутизирует Telegram через нужный прокси

```bash
logread | grep -E '149\.154\.|91\.108\.' | tail -20
```

Должны быть записи вида `→ TELEGRAM[AWG]` (или ваша группа).

### Порт 443 занят другим сервисом

```bash
netstat -tlnp | grep :443
```

Если занят — измените порт mtg и обновите firewall-правило. Например, порт 8443.

### Проверить внешний IP роутера

```bash
curl -s https://api.ipify.org
```

---

## Частые ошибки

### `incorrect first byte of secret: 0xea` (или другой байт)

**Причина**: Использован случайный hex-секрет.
**Решение**: Всегда генерировать секрет через:
```bash
/usr/local/bin/mtg generate-secret ДОМЕН
# Например: /usr/local/bin/mtg generate-secret google.com
```

---

### `incorrect socks5 proxy URL`

**Причина**: URL без схемы.
```
# Неверно:
-s 127.0.0.1:7891
# Верно:
-s socks5://user:pass@127.0.0.1:7891
```

---

### `unknown flag --anti-replay-max-size`

**Причина**: Флаг не существует в mtg v2.x (был в v1).
**Решение**: Удалить флаг из команды запуска.

---

### mtg запущен, порт слушает, но Telegram не подключается

1. Проверить что внешний IP/порт доступен снаружи:
   ```bash
   # С другого устройства вне сети:
   curl -m5 --connect-timeout 3 https://ВАШ_IP:443 -o /dev/null -w '%{http_code}'
   ```

2. Проверить firewall:
   ```bash
   nft list ruleset | grep -A1 '443'
   # Должно быть accept, не drop/reject
   ```

3. Проверить логи Mihomo (если Вариант A):
   ```bash
   logread | grep -i 'socks\|149.154\|91.108' | tail -20
   ```

---

### Mihomo SOCKS5: IPv4 не работает несмотря на `:::PORT`

На некоторых системах с `net.ipv6.conf.all.disable_ipv6=1` сокет Mihomo может быть IPv6-only.

**Решение**: Добавить в начало `config.yaml` Mihomo (до `mixed-port`):
```yaml
bind-address: '0.0.0.0'
```
Затем перезапустить Mihomo:
```bash
/etc/init.d/clash restart
```

---

### Правила для Telegram в config.yaml Mihomo

Убедитесь что в секции `rules:` есть IP-CIDR правила для всех Telegram DC:

```yaml
rules:
  - IP-CIDR,149.154.160.0/20,TELEGRAM,no-resolve
  - IP-CIDR,91.108.4.0/22,TELEGRAM,no-resolve
  - IP-CIDR,91.108.8.0/22,TELEGRAM,no-resolve
  - IP-CIDR,91.108.12.0/22,TELEGRAM,no-resolve
  - IP-CIDR,91.108.16.0/22,TELEGRAM,no-resolve
  - IP-CIDR,91.108.56.0/22,TELEGRAM,no-resolve
```

`TELEGRAM` — имя вашей прокси-группы.

---

## Архитектура

### Вариант A (через Mihomo)

```
Телефон
  │  TCP 443 (FakeTLS/MTProto)
  ▼
Роутер :443
  │
[mtg]
  │  SOCKS5 127.0.0.1:SOCKS5_PORT
  ▼
[Mihomo]
  │  правила → группа TELEGRAM
  ▼
[AWG / WARP / другой VPN]
  │
  ▼
Telegram DC (149.154.x.x / 91.108.x.x)
```

### Вариант B (прямое подключение)

```
Телефон
  │  TCP 443 (FakeTLS/MTProto)
  ▼
Роутер :443
  │
[mtg]
  │  прямое подключение
  ▼
Telegram DC (149.154.x.x / 91.108.x.x)
```

> **Примечание**: TPROXY-правила Mihomo/nftables НЕ применяются к трафику самого роутера (root-процессов).
> mtg подключается к Mihomo через SOCKS5, а не через TPROXY.

---

---

## Использование с телефона в домашнем WiFi (петля TPROXY)

### Проблема

Телефон подключён к домашнему WiFi. В Telegram указан прокси `server=WAN_IP&port=443`.

**Что происходит:**

1. Telegram пытается подключиться к `WAN_IP:443`
2. Пакет проходит через nftables PREROUTING → `CLASH_MARK`
3. WAN IP не входит в список исключений → получает mark `0x1`
4. Цепочка `proxy` (TPROXY) перехватывает → отправляет на Mihomo `:7894`
5. Mihomo пытается соединиться с `WAN_IP:443` напрямую в интернет
6. ISP не делает NAT loopback → соединение не приходит обратно на роутер → **петля / timeout**

### Решение 1 — LAN IP в настройках Telegram (проще всего)

В настройках прокси Telegram на домашнем устройстве указать **LAN IP роутера** вместо WAN IP:

```
server = 192.168.1.1
port   = 443
secret = ВАШ_СЕКРЕТ
```

**Почему работает**: в цепочке `CLASH_MARK` есть правило `ip daddr 192.168.0.0/16 return` — трафик к LAN-адресам пропускается мимо TPROXY и идёт напрямую на `mtg`, который слушает на `0.0.0.0:443`.

**Итог:** две конфигурации прокси в Telegram — `192.168.1.1:443` для WiFi и `WAN_IP:443` для мобильного интернета. Telegram перебирает их автоматически.

---

### Решение 2 — Исключить WAN IP из TPROXY (один прокси-линк везде)

Добавить WAN IP в nftables set `proxy_servers`, который уже содержит VPN-серверы и исключён из маркировки:

```bash
# Узнать текущий WAN IP
WAN_IP=$(ip addr show dev pppoe-wan | awk '/inet /{print $2}' | cut -d/ -f1)
echo "WAN IP: $WAN_IP"

# Добавить в proxy_servers (bypass TPROXY)
nft add element inet clash proxy_servers { $WAN_IP }
```

Проверить:

```bash
nft list set inet clash proxy_servers
# Должен содержать WAN IP
```

**Важно: правило слетает при перезагрузке/переподключении PPPoE.**

#### Сделать постоянным через hotplug

```bash
cat > /etc/hotplug.d/iface/99-mtproxy-bypass << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] || exit 0

# Получить WAN IP
WAN_IP=$(ip addr show dev pppoe-wan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
[ -z "$WAN_IP" ] && exit 0

# Удалить старые WAN IP из set (очистить 82.208.0.0/16 диапазон грубо)
nft flush set inet clash proxy_servers 2>/dev/null

# Добавить текущий WAN IP + VPN-серверы обратно
nft add element inet clash proxy_servers { $WAN_IP }
# Добавьте ваши VPN серверы если они были в set:
# nft add element inet clash proxy_servers { VPN_SERVER_IP }

logger -t mtproxy-bypass "Added WAN IP $WAN_IP to clash proxy_servers bypass"
EOF

chmod +x /etc/hotplug.d/iface/99-mtproxy-bypass
```

> **Замечание**: этот скрипт сбрасывает `proxy_servers` set при каждом переподключении PPPoE. Убедитесь что VPN-серверы из оригинального set прописаны в скрипте отдельно, иначе они пропадут.

---

### Решение 3 — Только для систем без Mihomo/Clash

Если Mihomo не установлен — TPROXY нет, петли нет. Оба варианта (`192.168.1.1:443` и `WAN_IP:443`) работают с домашнего WiFi без дополнительных настроек.

---

## Обновление mtg

Остановить, заменить бинарник, запустить:

```bash
/etc/init.d/mtg stop
# Загрузить новый бинарник (см. Шаг 1)
/etc/init.d/mtg start
mtg --version
```

Секрет при обновлении менять не нужно — он не зависит от версии.
