# GL-iNet Flint 2 — SSClash + AdGuard Home

Роутер **GL-iNet Flint 2 (GL-MT6000)** с OpenWrt 25.12.0, прозрачным проксированием через SSClash (Mihomo) и DNS-фильтрацией через AdGuard Home.

---

## Архитектура

```
Клиент (любое устройство в сети)
    |
    | DNS-запрос
    v
AdGuard Home :53  (блокировка рекламы)
    |
    | upstream DNS
    v
Mihomo DNS :1053  (fake-ip mode)
    |
    | DoH (Cloudflare / Google / Quad9)
    v
Интернет

Клиент (TCP/UDP трафик)
    |
    | TPROXY — nftables перехватывает весь трафик
    v
Mihomo :7894  (правила из config.yaml)
    |
    +---> DIRECT  (Россия: .ru, .рф, .su, банки, etc.)
    +---> PROXY   (заблокированные: Google, YouTube, etc.)
    +---> REJECT  (реклама)
```

---

## Что установлено

| Компонент | Версия | Назначение |
|-----------|--------|-----------|
| OpenWrt | 25.12.0 | ОС роутера |
| SSClash / Mihomo | v1.19.20 | TPROXY + fake-ip DNS, порт 7894 |
| AdGuard Home | latest | DNS-фильтрация, порт 53/3000 |
| LuCI | 26.x | Веб-интерфейс |

---

## Файлы репозитория

| Файл | Назначение |
|------|-----------|
| `config.example.yaml` | Шаблон конфига Mihomo — **заполни своими прокси** |
| `adguardhome/adguardhome.yaml` | Конфиг AdGuard Home — путь на роутере: `/etc/adguardhome/adguardhome.yaml` |
| `README.md` | Этот файл |

> Реальный `config.yaml` с ключами VPN хранится локально и **не публикуется** (в `.gitignore`).

---

## Как подставить свои прокси в config.example.yaml

Все proxy-серверы в шаблоне помечены плейсхолдерами. Замени их на свои значения:

| Плейсхолдер | Что подставить |
|-------------|---------------|
| `YOUR_VPN_SERVER` | домен или IP твоего сервера, например `fi1.example.com` |
| `YOUR_UUID` | UUID пользователя VLESS (генерируется на сервере) |
| `YOUR_REALITY_PUBKEY` | Reality public key с сервера |
| `YOUR_REALITY_SHORTID` | Reality short-id с сервера |
| `YOUR_WS_PATH` | путь WebSocket, например `/abc123/ws` |
| `YOUR_TROJAN_PASSWORD` | пароль Trojan-прокси |
| `YOUR_WARP_PRIVKEY` | WireGuard private key (из WARP / AmneziaWG) |
| `YOUR_WARP_PUBKEY` | WireGuard public key сервера |
| `YOUR_AWG_HEX` | hex-конфиг AmneziaWG (поле `i1`) |
| `YOUR_NEXTDNS_ID` | ID профиля NextDNS (из nexdns.io/setup) |
| `YOUR_AGH_PASSWORD_HASH` | bcrypt хэш пароля AGH (см. ниже) |

**Генерация bcrypt хэша для AGH:**
```sh
# На роутере или Linux
htpasswd -bnBC 10 "" ВАШ_ПАРОЛЬ | tr -d ':\n'
# Результат вставить в agh/adguardhome.yaml → users[0].password
```

**Минимальный набор прокси** — нужна хотя бы одна рабочая группа. Пример со своим сервером:
1. В `proxies:` добавь свой сервер (VLESS / Trojan / WireGuard)
2. В `proxy-groups:` пропиши его в группу `PROXY`
3. Загрузи на роутер и перезапусти SSClash

---

## Пошаговая установка с нуля

### Шаг 1. Сборка прошивки на firmware-selector.openwrt.org

1. Открой [firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/)
2. Найди `GL-MT6000` / `Flint 2`
3. **Customize installed packages** — вставь:

```
apk-mbedtls base-files ca-bundle dnsmasq dropbear firewall4 fitblk fstools
kmod-crypto-hw-safexcel kmod-gpio-button-hotplug kmod-leds-gpio kmod-nft-offload kmod-nft-tproxy
libc libgcc libustream-mbedtls logd mtd netifd nftables odhcp6c odhcpd-ipv6only
ppp ppp-mod-pppoe procd-ujail uboot-envtools uci uclient-fetch urandom-seed urngd
wpad-basic-mbedtls e2fsprogs f2fsck mkf2fs kmod-usb3 kmod-mt7915e
kmod-mt7986-firmware mt7986-wo-firmware luci adguardhome luci-i18n-base-ru
luci-i18n-firewall-ru luci-app-firewall kmod-tun bash curl ip-full wget
iptables-mod-tproxy nftables-json openssh-sftp-server nano mc htop
```

> `kmod-nft-tproxy` — **обязательно** включить в прошивку. Без него nftables TPROXY не работает.
> Если забыл — можно установить после через `apk add kmod-nft-tproxy` (после фикса wget, см. Шаг 3).

4. Скачай `*-squashfs-sysupgrade.bin`

---

### Шаг 2. Прошивка через U-Boot

1. LAN-кабель: ПК → LAN-порт роутера
2. Статический IP на ПК: `192.168.1.2 / 255.255.255.0 / GW 192.168.1.1`
3. Выключи роутер → зажми Reset → включи, держи ~5 сек до быстрого мигания LED
4. Открой `http://192.168.1.1` → загрузи `sysupgrade.bin` → Update
5. Жди 3–5 минут, не отключай питание

---

### Шаг 3. Первые шаги после прошивки — ВАЖНО

Подключись по SSH: `ssh root@192.168.1.1`

#### 3.1 Фикс wget (без этого apk update не работает)

```sh
# wget симлинкован на wget-nossl (без HTTPS) — заменяем на uclient-fetch
ln -sf /bin/uclient-fetch /usr/bin/wget
```

Проверка:
```sh
apk update
# Должно показать: "N distinct packages available" (не "unexpected end of file")
```

#### 3.2 Установка пакетов (если не были в прошивке)

```sh
apk add kmod-nft-tproxy iptables-nft
```

---

### Шаг 4. Установка SSClash

```sh
# Скачать и установить luci-app-ssclash
# (пакет для OpenWrt 25.x, если есть в репозитории)
apk add luci-app-ssclash

# Если нет в репо — установить вручную с GitHub:
# https://github.com/zerolabnet/SSClash (папка luci-app-ssclash/rootfs/)
# Структура:
#   /etc/init.d/clash          (chmod +x)
#   /opt/clash/bin/clash-rules (chmod +x)
#   /opt/clash/ui/             (веб-интерфейс)
```

---

### Шаг 5. Загрузка конфига SSClash

```sh
# С ПК — загрузить config.yaml на роутер
scp config.yaml root@192.168.1.1:/opt/clash/config.yaml

# На роутере — запустить
/etc/init.d/clash enable
/etc/init.d/clash start
```

Проверка:
```sh
logread | grep 'clash-rules' | tail -5
# Должно быть: "nftables rules applied successfully"
# И: "Clash service started successfully"
```

---

### Шаг 6. Настройка AdGuard Home

#### 6.1 Первичная настройка

1. Открой `http://192.168.1.1:3000`
2. Пройди мастер:
   - DNS: `0.0.0.0:53`
   - Веб-интерфейс: `0.0.0.0:3000`

#### 6.2 Настройка upstream DNS → Clash

SSClash DNS слушает на `127.0.0.1:1053`. AGH должен форвардить туда:

```sh
# Вариант через SSH (или через UI: Настройки → DNS → Upstream DNS)
sed -i 's|  upstream_dns:.*|  upstream_dns:|' /etc/adguardhome/adguardhome.yaml
# Далее вручную поставить в upstream_dns: "127.0.0.1:1053"
```

**Через UI**: Настройки → DNS → Upstream DNS → заменить на:
```
127.0.0.1:1053
```

#### 6.3 Отключить AAAA-запросы (совместимость с ipv6: false в Mihomo)

```sh
sed -i 's/aaaa_disabled: false/aaaa_disabled: true/' /etc/adguardhome/adguardhome.yaml
/etc/init.d/adguardhome restart
```

---

### Шаг 7. Проверка

```sh
# Сервисы запущены
/etc/init.d/clash status       # running
/etc/init.d/adguardhome status # running

# Порты
netstat -tlunp | grep -E ':53|:1053|:7894|:3000|:9090'
# 127.0.0.1:1053 — Mihomo DNS (fake-ip)
# :::53          — AdGuard Home
# :::7894        — Mihomo TPROXY
# :::3000        — AGH UI
# :::9090        — Mihomo API

# DNS работает корректно
nslookup gemini.google.com 127.0.0.1
# Ожидается: Address: 198.18.x.x  (fake-ip → прокси)

nslookup yandex.ru 127.0.0.1
# Ожидается: реальный IP → direct

# TPROXY трафик идёт
nft list ruleset | grep -c tproxy
# Должно быть > 0

# Интернет
ping -c 3 8.8.8.8
```

---

## Конфиг SSClash — ключевые параметры

Смотри `config.example.yaml`. Важные моменты:

```yaml
# TPROXY порт (nftables перехватывает весь трафик и редиректит сюда)
tproxy-port: 7894

# Исходящий трафик самого Mihomo не должен уходить в TPROXY-петлю
routing-mark: 2

# DNS — fake-ip, слушает на 127.0.0.1:1053
dns:
  enable: true
  listen: '127.0.0.1:1053'
  enhanced-mode: fake-ip
  ipv6: false          # AGH настроен с aaaa_disabled: true
```

---

## Обновление конфига

```sh
# С ПК
scp config.yaml root@192.168.1.1:/opt/clash/config.yaml
ssh root@192.168.1.1 "/etc/init.d/clash restart"
```

---

## Полезные команды

```sh
# Аудит: что установлено из сетевых модулей
apk list --installed | grep -E '(iptables|nftables|tproxy|kmod|tun)'
lsmod | grep -E '(tproxy|TPROXY|nft_tproxy)'

# Логи
logread | grep clash | tail -20
logread | grep AdGuard | tail -10

# nft правила (проверить что TPROXY активен)
nft list ruleset | grep -E '(tproxy|TPROXY|proxy)'

# Статус всех сервисов
/etc/init.d/clash status
/etc/init.d/adguardhome status
netstat -tlunp | grep -E ':53|:1053|:7894|:3000|:9090'
```

---

## Известные проблемы и решения

| Проблема | Причина | Решение |
|---------|---------|---------|
| `apk update` — "unexpected end of file" | `wget` → `wget-nossl` (без HTTPS) | `ln -sf /bin/uclient-fetch /usr/bin/wget` |
| `Error: Could not process rule: No such file or directory` | `kmod-nft-tproxy` не установлен | `apk add kmod-nft-tproxy` |
| `ERROR: Neither nftables nor iptables found` | `iptables` бинарник не установлен | `apk add iptables-nft` |
| DNS SERVFAIL для всех доменов | AGH не может достучаться до Clash DNS 1053 (AAAA запросы) | `aaaa_disabled: true` в adguardhome.yaml |
| Домены `.ru` не резолвятся | Циклическая зависимость: `direct-nameserver: system` → AGH → Clash → AGH | Убрать `system` из `direct-nameserver`, использовать `1.1.1.1` / `8.8.8.8` |
| `4 × Error: syntax error, unexpected junk` при старте | nft пытается применить IPv6 правила при `ipv6: false` | Некритично, правила применяются успешно |

---

## Обновление прошивки (сохранить настройки SSClash и AGH)

При обновлении прошивки через sysupgrade настройки в `/overlay` сохраняются автоматически.

**Что сохраняется:** AGH config, SSClash init-скрипт, clash-rules, config.yaml
**Что НЕ сохраняется:** установленные через apk пакеты (kmod-nft-tproxy, iptables-nft, wget-симлинк)

После обновления прошивки выполнить заново:
```sh
ln -sf /bin/uclient-fetch /usr/bin/wget
apk update
apk add kmod-nft-tproxy iptables-nft
/etc/init.d/clash restart
/etc/init.d/adguardhome restart
```
