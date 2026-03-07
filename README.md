# GL-iNet Flint 2 — SSClash + AdGuard Home + CF IP Optimizer

Роутер **GL-iNet Flint 2 (GL-MT6000)** с OpenWrt 25.12.0, прозрачным проксированием через SSClash (Mihomo) и DNS-фильтрацией через AdGuard Home. Дополнительно — набор скриптов-оптимизаторов с управлением через LuCI.

---

## Архитектура

```
Клиент (любое устройство в сети)
    │
    │ DNS-запрос
    ▼
AdGuard Home :53  (блокировка рекламы, фильтрация)
    │
    │ upstream DNS
    ▼
Mihomo DNS :1053  (fake-ip mode)
    │
    │ DoH (Cloudflare / Google / Quad9)
    ▼
Интернет

Клиент (TCP/UDP трафик)
    │
    │ TPROXY — nftables перехватывает весь трафик
    ▼
Mihomo :7894  (правила из config.yaml)
    │
    ├──► DIRECT  (Россия: .ru, .рф, .su, банки, госсайты)
    ├──► PROXY   (заблокированные: Google, YouTube, Gemini, etc.)
    └──► REJECT  (реклама, трекеры)
```

---

## Что установлено

| Компонент | Версия | Назначение |
|-----------|--------|-----------|
| OpenWrt | 25.12.0 | ОС роутера (aarch64, mediatek/filogic) |
| SSClash / Mihomo | v1.19.20 | TPROXY + fake-ip DNS, порт 7894 |
| AdGuard Home | latest | DNS-фильтрация, порт 53 / UI 3000 |
| LuCI | 26.x | Веб-интерфейс управления |
| CF IP Optimizer | — | Набор скриптов оптимизации (patches/) |

---

## Файлы репозитория

```
Router/
├── README.md                          # этот файл
├── CF-IP-OPTIMIZER.md                 # архитектурный документ оптимизатора
├── config.example.yaml                # шаблон конфига Mihomo (плейсхолдеры вместо реальных данных)
├── adguardhome/
│   └── adguardhome.yaml               # конфиг AdGuard Home
└── patches/
    ├── setup-cf-optimizer.sh          # главный установщик всех оптимизаторов
    ├── setup-adguardhome.sh           # патч конфига AGH под Mihomo fake-ip
    ├── cf-ip-update.sh                # блок 1: поиск лучшего CF edge IP (только для прокси за Cloudflare CDN)
    ├── sni-scan.sh                    # блок 2: тест SNI через туннель Mihomo (только для прокси за Cloudflare CDN)
    ├── latency-monitor.sh             # блок 3: мониторинг задержек прокси-групп + автопереключение GEMINI
    ├── 99-cf-dpi-bypass.nft           # блок 4: DPI bypass через nftables MSS clamp
    ├── xray-fragment.json             # блок 4 alt: TLS fragmentation через Xray (опционально)
    └── luci/
        ├── controller/cf_optimizer.lua  # LuCI controller: меню Services → CF IP Optimizer
        └── model/cbi/cf_optimizer.lua   # LuCI CBI model: статус, настройки, кнопки
```

> Реальный `config.yaml` с ключами VPN хранится локально и **не публикуется** (`.gitignore`).

---

## CF IP Optimizer — что делает и как работает

Набор из 4 блоков для оптимизации соединения через Mihomo. Каждый блок можно включить/выключить независимо через LuCI (`Services → CF IP Optimizer`).

### Блок 1: CF IP Updater (`cf-ip-update.sh`)

**Применимо только если твои прокси-серверы стоят за Cloudflare CDN.**

Логика:

1. Запрашивает список IP Cloudflare edge-серверов у твоего Cloudflare Worker API по регионам (FI, DE, NL, ...)
2. Проверяет каждый IP через TCP-коннект с таймаутом 3 сек
3. Если новый IP быстрее текущего на `update_threshold`% — обновляет адрес прокси в `config.yaml`
4. Делает graceful hot-reload через Mihomo API (`PUT /configs?force=false`) — соединения не рвутся

UCI-настройки: `worker_url`, `regions`, `proxy_name`, `update_threshold`, `limit_per_region`

> Если прокси-сервер — прямой VPS (не за Cloudflare CDN) — этот блок не нужен.

---

### Блок 2: SNI Scanner (`sni-scan.sh`)

**Применимо только если прокси за Cloudflare CDN.**

Логика:

- Тестирует несколько SNI-вариантов (популярные cloudflare-домены) через реальный туннель Mihomo SOCKS5
- Выбирает SNI с наименьшей задержкой
- Обновляет `sni` поле в `config.yaml` + hot-reload

UCI-настройки: `mihomo_socks`, `mihomo_config`

---

### Блок 3: Latency Monitor (`latency-monitor.sh`)

**Работает для любых прокси — не зависит от Cloudflare CDN.**

Тестирует прокси через Mihomo API и автоматически переключает группы на самый быстрый прокси. Запускается автоматически каждые 2 часа через cron.

#### Группа GEMINI (`🤖 GEMINI`, тип: selector)

- Список прокси читается динамически из Mihomo API (`GET /proxies/{group}`) — не захардкожен
- Каждый прокси тестируется через `GET /proxies/{name}/delay` — Mihomo проверяет внутри, не переключая группу
- Между тестами — пауза 1 сек (щадящий режим, не перегружает сеть)
- Выбирается прокси с минимальной задержкой
- GEMINI переключается через `PUT /proxies/{group}` с JSON-телом `{"name": "лучший_прокси"}`
- Группа GEMINI полностью изолирована: скрипт никогда не трогает другие группы

Пример результата:
```
[GEMINI] 🇩🇪 Германия · WS          274ms  ← выбран
[GEMINI] 🇩🇪 Германия² · WS         287ms
[GEMINI] 🇳🇱 Netherlands, Amsterdam  339ms
[GEMINI] 🇫🇮 Finland, Helsinki       352ms
[GEMINI] 🇨🇭 Switzerland, Geneva     367ms
[GEMINI] 🇺🇸 USA, Fremont           1001ms
[GEMINI] 🇺🇸 USA, Salt Lake City    1049ms
GEMINI: switched to '🇩🇪 Германия · WS' (274ms) [API: 204]
```

#### Группа PrvtVPN All Auto (тип: url-test)

- Mihomo сам управляет этой группой автоматически (url-test)
- Скрипт только читает текущий активный прокси и его задержку
- Логирует, ничего не переключает

UCI-настройки: `latency_enabled`, `gemini_group`, `main_group`

---

### Блок 4: DPI Bypass (`99-cf-dpi-bypass.nft`)

Защищает TLS-соединения от глубокой инспекции пакетов (DPI). Работает через nftables: устанавливает MSS = 150 байт для TCP SYN-пакетов, которые исходят от Mihomo (mark=2, порты 443/2053/2083/2087/2096). Это разбивает TLS ClientHello на несколько сегментов — DPI не видит SNI целиком.

```nft
table inet cf_dpi_bypass {
    chain output {
        type filter hook output priority mangle; policy accept;
        meta mark 2 tcp dport { 443, 2053, 2083, 2087, 2096 } \
            tcp flags syn \
            tcp option maxseg size set 150
    }
}
```

- `mark 2` = `routing-mark: 2` из `config.yaml` — только трафик самого Mihomo
- MSS 150 — рекомендуемый баланс защита/задержка (40 = максимум, 200 = минимум)
- Активен на роутере прямо сейчас

#### Блок 4 alt: TLS Fragment через Xray (`xray-fragment.json`)

Альтернативный вариант DPI bypass — Xray-core с fragmentation. Запускается как SOCKS5 proxy на порту 10801, фрагментирует TLS ClientHello (`tlshello`, 10–30 байт, интервал 10–20 мс). Подключается к Mihomo через `dialer-proxy: xray-fragment`. Опционально, не задеплоен.

---

## LuCI-интерфейс

`Services → CF IP Optimizer` — единая панель управления всеми оптимизаторами.

### Секции

**Статус** — текущий CF edge IP, задержка, SNI, статус DPI bypass, кнопки ручного запуска

**Latency Monitor** — текущий прокси GEMINI + задержка, текущий прокси основной группы, кнопка "Запустить сейчас"

**Включить / Выключить** — флаги для каждого блока:

- `Latency Monitor` — включить мониторинг прокси-групп (каждые 2 часа)
- `DPI Bypass` — включить nftables MSS clamp
- `CF IP Updater` — включить поиск CF edge IP (только для прокси за CDN)
- `SNI Scanner` — включить тест SNI (только для прокси за CDN)

**Настройки** — параметры всех блоков:

- `GEMINI группа` — точное имя selector-группы в Mihomo (по умолчанию: `🤖 GEMINI`)
- `Main группа` — имя url-test группы для мониторинга (по умолчанию: `PrvtVPN All Auto`)
- `Worker API URL` — URL твоего Cloudflare Worker (для блоков 1–2)
- `Регионы` — коды стран через запятую (FI,DE,NL,SE)
- `Имя прокси в Mihomo` — для блока 1 (CF IP updater)
- `MSS Value` — для DPI bypass (150 рекомендуется)
- `Порог обновления (%)` — обновлять IP только если новый быстрее на X%

**Mihomo API** — URL, secret, SOCKS5 адрес, путь к config.yaml

**Последний лог** — последние строки лога IP updater прямо в интерфейсе

---

## Установка CF IP Optimizer

### Шаг 1. Скопировать и запустить установщик

```sh
# С ПК — скопировать всю папку patches на роутер
scp -r patches/ root@192.168.1.1:/tmp/patches/

# На роутере — запустить установщик
ssh root@192.168.1.1 "chmod +x /tmp/patches/setup-cf-optimizer.sh && /tmp/patches/setup-cf-optimizer.sh"
```

### Что делает установщик (`setup-cf-optimizer.sh`)

1. Копирует скрипты в `/usr/local/bin/` с правами 755
2. Создаёт UCI-конфиг `/etc/config/cf_optimizer` с дефолтными значениями
3. Устанавливает LuCI-файлы в `/usr/lib/lua/luci/`
4. Добавляет задачи в cron:
   - CF IP update: каждые 6 часов
   - SNI scan: ежедневно в 02:30
   - Latency monitor: каждые 2 часа
5. Применяет nftables DPI bypass правило
6. Создаёт init-скрипт `/etc/init.d/cf-optimizer` (запуск при старте системы)

### Шаг 2. Настройка через LuCI

`Services → CF IP Optimizer`:
1. Вписать имя GEMINI-группы (точно как в Mihomo `config.yaml`)
2. Вписать имя основной группы
3. Включить `Latency Monitor`
4. Если прокси за Cloudflare CDN — заполнить Worker URL, регионы, имя прокси, включить IP Updater
5. Нажать `Save & Apply`

### Шаг 3. Проверка

```sh
# Запустить latency monitor вручную
/usr/local/bin/latency-monitor.sh

# Посмотреть результат
cat /var/run/latency-monitor.status

# Лог
logread | grep latency-monitor | tail -20
```

---

## Настройка AdGuard Home

Скрипт `patches/setup-adguardhome.sh` автоматически патчит конфиг AGH:

- upstream DNS → `127.0.0.1:1053` (Mihomo fake-ip)
- отключает AAAA-запросы (`ipv6: false` в Mihomo)
- устанавливает логин и пароль администратора

**Перед запуском** — открой файл и впиши свои данные:

```sh
# В patches/setup-adguardhome.sh замени:
AGH_USER="root"
AGH_PASSWORD_HASH='$2y$10$REPLACE_THIS_WITH_YOUR_BCRYPT_HASH'

# Сгенерировать bcrypt-хэш (на роутере или Linux):
htpasswd -bnBC 10 "" YOUR_PASSWORD | tr -d ':\n'
```

**Запуск:**

```sh
scp patches/setup-adguardhome.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "chmod +x /tmp/setup-adguardhome.sh && /tmp/setup-adguardhome.sh"
```

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
> Если забыл — можно доустановить: `apk add kmod-nft-tproxy` (после фикса wget, см. ниже).

4. Скачай `*-squashfs-sysupgrade.bin`

---

### Шаг 2. Прошивка через U-Boot

1. LAN-кабель: ПК → LAN-порт роутера
2. Статический IP на ПК: `192.168.1.2 / 255.255.255.0 / GW 192.168.1.1`
3. Выключи роутер → зажми Reset → включи, держи ~5 сек до быстрого мигания LED
4. Открой `http://192.168.1.1` → загрузи `sysupgrade.bin` → Update
5. Жди 3–5 минут, не отключай питание

---

### Шаг 3. Первые шаги после прошивки

```sh
ssh root@192.168.1.1
```

#### 3.1 Фикс wget (без этого apk update не работает)

```sh
# wget симлинкован на wget-nossl (без HTTPS) — заменяем на uclient-fetch
ln -sf /bin/uclient-fetch /usr/bin/wget

# Проверка
apk update
# Должно показать: "N distinct packages available"
```

#### 3.2 Установка пакетов (если не были в прошивке)

```sh
apk add kmod-nft-tproxy iptables-nft
```

---

### Шаг 4. Установка SSClash

```sh
apk add luci-app-ssclash

# Если нет в репо — вручную с GitHub (zerolabnet/SSClash):
# /etc/init.d/clash          (chmod +x)
# /opt/clash/bin/clash-rules (chmod +x)
# /opt/clash/ui/             (веб-интерфейс)
```

---

### Шаг 5. Загрузка конфига

```sh
# С ПК
scp config.yaml root@192.168.1.1:/opt/clash/config.yaml

# На роутере
/etc/init.d/clash enable
/etc/init.d/clash start
```

Проверка:
```sh
logread | grep 'clash-rules' | tail -5
# Ожидается: "nftables rules applied successfully"
```

---

### Шаг 6. Настройка AdGuard Home

1. Открой `http://192.168.1.1:3000`
2. Пройди мастер: DNS `0.0.0.0:53`, веб `0.0.0.0:3000`
3. Запусти патч-скрипт (см. раздел выше)

---

### Шаг 7. Установка CF IP Optimizer

```sh
scp -r patches/ root@192.168.1.1:/tmp/patches/
ssh root@192.168.1.1 "chmod +x /tmp/patches/setup-cf-optimizer.sh && /tmp/patches/setup-cf-optimizer.sh"
```

---

### Шаг 8. Проверка

```sh
# Сервисы запущены
/etc/init.d/clash status
/etc/init.d/adguardhome status

# Порты
ss -tlunp | grep -E ':53|:1053|:7894|:3000|:9090'
# 127.0.0.1:1053 — Mihomo DNS (fake-ip)
# 0.0.0.0:53     — AdGuard Home
# 0.0.0.0:7894   — Mihomo TPROXY
# 0.0.0.0:3000   — AGH UI
# 127.0.0.1:9090 — Mihomo REST API

# DNS
nslookup gemini.google.com 127.0.0.1
# Ожидается: Address: 198.18.x.x  (fake-ip → прокси)

nslookup yandex.ru 127.0.0.1
# Ожидается: реальный IP → direct

# DPI bypass активен
nft list table inet cf_dpi_bypass

# Latency monitor
cat /var/run/latency-monitor.status
```

---

## UCI-конфиг (`/etc/config/cf_optimizer`)

Все настройки хранятся в UCI. Можно редактировать через LuCI или напрямую:

```sh
# Включить latency monitor
uci set cf_optimizer.main.latency_enabled=1

# Задать имя GEMINI-группы (точно как в Mihomo config.yaml)
uci set cf_optimizer.main.gemini_group='🤖 GEMINI'

# Задать имя основной группы
uci set cf_optimizer.main.main_group='PrvtVPN All Auto'

# Mihomo API (дефолт: http://127.0.0.1:9090)
uci set cf_optimizer.main.mihomo_api='http://127.0.0.1:9090'

# Secret для Mihomo API (если задан в config.yaml)
uci set cf_optimizer.main.mihomo_secret='твой_secret'

# DPI bypass
uci set cf_optimizer.main.dpi_bypass_enabled=1
uci set cf_optimizer.main.mss_value=150

# Применить
uci commit cf_optimizer
```

---

## Конфиг SSClash — ключевые параметры

```yaml
# TPROXY порт
tproxy-port: 7894

# Исходящий трафик Mihomo — не уходит в TPROXY-петлю
routing-mark: 2

# DNS — fake-ip, слушает на 127.0.0.1:1053
dns:
  enable: true
  listen: '127.0.0.1:1053'
  enhanced-mode: fake-ip
  ipv6: false

# Пример selector-группы (Latency Monitor управляет ею)
proxy-groups:
  - name: "🤖 GEMINI"
    type: select
    proxies:
      - "🇩🇪 Германия · WS"
      - "🇳🇱 Netherlands · VLESS"
      # ...

  # url-test группа — Mihomo управляет сам, Latency Monitor только читает
  - name: "PrvtVPN All Auto"
    type: url-test
    proxies:
      - "Server1"
      - "Server2"
      # ...
```

Все плейсхолдеры для подстановки своих прокси — в `config.example.yaml`.

---

## Полезные команды

```sh
# Статус latency monitor
cat /var/run/latency-monitor.status
logread | grep latency-monitor | tail -20

# Запустить latency monitor вручную (без cron)
/usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1 &

# Mihomo API напрямую
curl http://127.0.0.1:9090/proxies | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['proxies'].keys()))"
curl http://127.0.0.1:9090/version

# DPI bypass
nft list table inet cf_dpi_bypass
nft delete table inet cf_dpi_bypass   # выключить
nft -f /etc/nftables.d/99-cf-dpi-bypass.nft  # включить

# Cron
crontab -l

# Аудит сетевых модулей
apk list --installed | grep -E '(iptables|nftables|tproxy|kmod)'
lsmod | grep -E '(tproxy|nft_tproxy)'

# Логи
logread | grep clash | tail -20
logread | grep AdGuard | tail -10
logread | grep latency-monitor | tail -20
```

---

## Известные проблемы и решения

| Проблема | Причина | Решение |
|---------|---------|---------|
| `apk update` — "unexpected end of file" | `wget` → `wget-nossl` (без HTTPS) | `ln -sf /bin/uclient-fetch /usr/bin/wget` |
| `Error: Could not process rule: No such file or directory` | `kmod-nft-tproxy` не установлен | `apk add kmod-nft-tproxy` |
| `ERROR: Neither nftables nor iptables found` | `iptables` не установлен | `apk add iptables-nft` |
| DNS SERVFAIL для всех доменов | AGH не может достучаться до Mihomo DNS (AAAA запросы) | `aaaa_disabled: true` в adguardhome.yaml |
| Домены `.ru` не резолвятся | Циклическая зависимость: `direct-nameserver: system` → AGH → Clash | Убрать `system` из `direct-nameserver`, использовать `1.1.1.1` |
| GEMINI не переключается | Имя группы в UCI не совпадает с именем в Mihomo | Проверить `uci get cf_optimizer.main.gemini_group`, должно совпадать с `config.yaml` |
| Latency monitor не запускается | `latency_enabled` = 0 | `uci set cf_optimizer.main.latency_enabled=1 && uci commit cf_optimizer` |
| Lock file завис после сбоя | Скрипт убит без trap (SIGKILL) | `rm -f /var/run/latency-monitor.lock` |

---

## Обновление прошивки (сохранить настройки)

При обновлении через sysupgrade настройки в `/overlay` сохраняются автоматически.

**Сохраняется:** AGH config, SSClash init-скрипт, clash-rules, config.yaml, UCI конфиги, LuCI скрипты, nftables правила.
**Не сохраняется:** пакеты, установленные через `apk` (kmod-nft-tproxy, iptables-nft, wget-симлинк).

После обновления:
```sh
ln -sf /bin/uclient-fetch /usr/bin/wget
apk update
apk add kmod-nft-tproxy iptables-nft
/etc/init.d/clash restart
/etc/init.d/adguardhome restart
```
