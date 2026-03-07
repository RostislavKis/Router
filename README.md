# GL-iNet Flint 2 — SSClash + AdGuard Home + Proxy Optimizer

Роутер **GL-iNet Flint 2 (GL-MT6000)** с OpenWrt 25.12.0, прозрачным проксированием через SSClash (Mihomo) и DNS-фильтрацией через AdGuard Home. Дополнительно — Proxy Optimizer: набор скриптов стабилизации и оптимизации с единым управлением через LuCI.

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
| OpenWrt | 25.12.0 r32713-f919e7899d | ОС роутера (aarch64, mediatek/filogic) |
| SSClash / Mihomo | v1.19.20 | TPROXY + fake-ip DNS, порт 7894 |
| AdGuard Home | latest | DNS-фильтрация, порт 53 / UI 3000 |
| LuCI | openwrt-25.12 branch 26.064.72454~b89e6b3 | Веб-интерфейс управления |
| Proxy Optimizer | — | Набор скриптов оптимизации и стабилизации (patches/) |

---

## Файлы репозитория

```
Router/
├── README.md                          # этот файл
├── config.example.yaml                # шаблон конфига Mihomo (плейсхолдеры)
├── adguardhome/
│   └── adguardhome.yaml               # конфиг AdGuard Home
└── patches/
    ├── setup-cf-optimizer.sh          # главный установщик Proxy Optimizer
    ├── setup-adguardhome.sh           # патч конфига AGH под Mihomo fake-ip
    │
    ├── latency-monitor.sh             # мониторинг задержек + автопереключение GEMINI (с гистерезисом)
    ├── latency-start.sh               # пишет trigger-файл для LuCI-кнопки (cron подхватывает за ≤1 мин)
    ├── mihomo-watchdog.sh             # watchdog: перезапуск Mihomo при сбое
    ├── log-rotate.sh                  # ротация логов (tmpfs /var/log)
    ├── geo-update.sh                  # обновление geoip.dat / geosite.dat / country.mmdb
    ├── xray-control.sh                # управление Xray fragment proxy (start/stop/status)
    ├── xray-install.sh                # загрузка Xray бинарника для aarch64 с GitHub
    ├── 99-router-mem.conf             # sysctl: оптимизация RAM для embedded/flash системы
    │
    ├── cf-ip-update.sh                # поиск лучшего CF edge IP (только для прокси за Cloudflare CDN)
    ├── sni-scan.sh                    # тест SNI через туннель Mihomo (только для прокси за Cloudflare CDN)
    ├── wifi-optimize.sh               # максимизация мощности и покрытия WiFi
    ├── 99-cf-dpi-bypass.nft           # DPI bypass через nftables MSS clamp
    ├── xray-fragment.json             # шаблон конфига Xray fragment (генерируется из UCI при старте)
    │
    └── luci/
        ├── menu.d/luci-app-cf-optimizer.json   # пункт меню "Proxy Optimizer"
        ├── menu.d/luci-app-adguardhome.json    # замена меню AGH (одна кнопка "Open Dashboard")
        ├── acl.d/luci-app-cf-optimizer.json    # права доступа rpcd
        ├── view/cf-optimizer/main.js           # Overview: статус мониторов, кнопки управления, live log
        ├── view/cf-optimizer/settings.js       # Settings: UCI-настройки прокси-групп, порогов, API
        └── view/adguardhome/dashboard.js       # кастомная страница AGH (кнопка, без авто-открытия)
```

> Реальный `config.yaml` с ключами VPN хранится локально и **не публикуется** (`.gitignore`).

---

## Proxy Optimizer — что делает и как работает

Набор из 7 компонентов для оптимизации и стабилизации работы Mihomo. Каждый компонент можно включить/выключить независимо через LuCI (`Services → Proxy Optimizer`).

---

### Latency Monitor (`latency-monitor.sh`)

**Работает для любых прокси — не зависит от Cloudflare CDN.**

Тестирует прокси через Mihomo API и автоматически переключает группы. Запускается каждые 2 часа через cron.

#### Группа GEMINI (`🤖 GEMINI`, тип: selector)

- Список прокси читается динамически из Mihomo API — не захардкожен
- Каждый прокси тестируется через `GET /proxies/{name}/delay` (Mihomo проверяет внутри, не переключая группу)
- Пауза 1 сек между тестами (щадящий режим)
- **Гистерезис**: переключает только если лучший прокси быстрее текущего на `switch_threshold`% или больше
  - По умолчанию: 20% (при current=150ms переключит только если best < 120ms)
  - Защищает Gemini / NotebookLM от лишних переключений (они чувствительны к геолокации)
- Статус сохраняется в `/var/run/latency-monitor.status` (RAM)
- При каждом фактическом переключении — дублируется в `/etc/cf-optimizer.status` (flash, сохраняется при ребуте)
- На старте системы init-скрипт восстанавливает flash-статус в RAM

#### Группа PrvtVPN All Auto (тип: url-test)

- Mihomo сам управляет ею автоматически (url-test)
- Скрипт только читает текущий прокси и логирует, ничего не переключает

UCI: `latency_enabled`, `gemini_group`, `main_group`, `switch_threshold`

---

### Mihomo Watchdog (`mihomo-watchdog.sh`)

Мониторит здоровье Mihomo и перезапускает сервис при сбое. Запускается каждые 10 минут через cron.

- Проверка 1: `GET /version` — базовая доступность API
- Проверка 2: `GET /proxies` — конфиг загружен и парсился без ошибок
- **2 сбоя подряд** → перезапуск `/etc/init.d/clash restart`
- После перезапуска ждёт до 30 сек и проверяет восстановление
- Статус пишет в `/var/run/mihomo-watchdog.status`
- Состояния: `healthy`, `warning`, `restarting`, `recovered`, `failed`
- **Не трогает** выбор прокси в GEMINI или любых других группах

UCI: `watchdog_enabled`

---

### Log Rotate (`log-rotate.sh`)

Обрезает лог-файлы до последних 500 строк. Запускается ежедневно в 03:00.

`/var/log` на OpenWrt — tmpfs (RAM). Стандартного logrotate нет. Без чистки логи могут съесть RAM за несколько дней.

Файлы: `latency-monitor.log`, `cf-ip-update.log`, `sni-scan.log`, `mihomo-watchdog.log`

---

### RAM Optimization (`99-router-mem.conf`)

Файл sysctl-настроек для embedded/flash системы с 1 GB RAM и тремя Go-процессами (Mihomo, AdGuard Home, Xray). Разворачивается в `/etc/sysctl.d/99-router-mem.conf` и применяется автоматически при загрузке через `S11sysctl`.

| Параметр | Значение | По умолчанию | Причина |
| -------- | -------- | ------------ | ------- |
| `vm.dirty_ratio` | 5 | 20 | Сбрасывать грязные страницы на флеш быстрее — меньше риск потери данных при отключении питания |
| `vm.dirty_background_ratio` | 2 | 10 | Фоновая запись начинается раньше, меньше пиковая нагрузка |
| `vm.vfs_cache_pressure` | 200 | 100 | Ядро активнее освобождает page/dentry/inode кеш — больше RAM для процессов |
| `vm.min_free_kbytes` | 16384 | авто | Всегда держать 16 MB свободными, защита от OOM-спайков Go runtime |

**Реальный эффект на GL-MT6000 (1 GB):**

```text
До:   MemFree ~340 MB   MemAvailable ~579 MB
После: MemFree ~553 MB   MemAvailable ~602 MB
```

Основная причина прироста — `drop_caches` при установке и более агрессивный `vfs_cache_pressure` в дальнейшем. Процессы (Clash ~100 MB, AGH ~90 MB, Xray ~30 MB) в сумме занимают ~230 MB физической памяти — остаток свободен.

---

### WiFi Optimization (`wifi-optimize.sh`)

Максимизирует мощность передатчика и ширину канала WiFi на GL-MT6000. Применяется однократно — настройки сохраняются в UCI и переживают перезагрузки.

| Диапазон | До | После |
| --- | --- | --- |
| 2.4 ГГц | ch1, HE20, 20 dBm | ch6, **HE40**, 20 dBm |
| 5 ГГц | ch36, HE80, 20 dBm | ch149, **HE80, 30 dBm** |
| TX мощность 5 ГГц | 100 мВт | **1000 мВт (10×)** |

**Почему ch149 и страна BO:**

- Regulatory database прошивки (`wireless-regdb`) ограничивает страну `00` и `RU` максимумом 20 dBm на всех диапазонах
- Country code `BO` (Bolivia) в этой же базе разрешает **30 dBm на U-NII-3 (5735–5835 МГц = ch149–165)**
- Драйвер MT76 c `txpower auto` берёт максимум разрешённый регдоменом — `fixed 3000 mBm` в этом режиме не работает

**2.4 ГГц:** ch6 вместо ch1 — центральная позиция в диапазоне, меньше соседских помех. HE40 (40 МГц) удваивает пропускную способность. `noscan=1` — игнорирует HT40-intolerant биконы соседей.

**5 ГГц:** ch149 (5745 МГц) — U-NII-3 диапазон, нет DFS, нет задержки радар-детекции. 30 dBm = +10 дБ к дефолтным 20 dBm на ch36. Чипсет MT7986A аппаратно поддерживает эту мощность.

```sh
# Применить оптимизацию
/usr/local/bin/wifi-optimize.sh

# Текущий статус без изменений
/usr/local/bin/wifi-optimize.sh --show
```

> Скрипт автоматически устанавливается через `setup-cf-optimizer.sh`.

---

### Geo Update (`geo-update.sh`)

Скачивает свежие geo-базы Mihomo и делает hot-reload конфига. Запускается раз в неделю (воскресенье 04:00). **По умолчанию включён.**

- `geoip.dat`, `geosite.dat`, `country.mmdb` из MetaCubeX latest release
- После скачивания: `PUT /configs?force=false` — Mihomo перезагружает правила без разрыва соединений
- Curl с 3 retry и таймаутом 120 сек

UCI: `geo_update_enabled`, `mihomo_config`

---

### DPI Bypass (`99-cf-dpi-bypass.nft`)

Защищает TLS-соединения от DPI. Устанавливает MSS = 150 байт для TCP SYN-пакетов исходящих от Mihomo (mark=2, порты 443/2053/2083/2087/2096). Разбивает TLS ClientHello на несколько сегментов — DPI не видит SNI целиком.

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
- MSS 150 — рекомендуемый баланс (40 = максимум, 200 = минимум)

UCI: `dpi_bypass_enabled`, `mss_value`

---

### DPI Bypass — Xray Fragment (`xray-control.sh`, `xray-install.sh`)

Альтернативный и дополнительный метод DPI bypass. Запускает Xray-core как локальный SOCKS5-прокси на порту 10801. Xray фрагментирует TLS ClientHello при подключении к прокси-серверу на уровне TCP-сегментов.

**Отличие от nftables MSS:**

| | nftables MSS | Xray Fragment |
| -- | -- | -- |
| Уровень | Сетевой (nftables) | Приложения (Xray) |
| Что фрагментирует | Любые TCP SYN (mark=2) | TLS ClientHello при коннекте к прокси |
| Настройка в config.yaml | Не нужна | `dialer-proxy: xray-fragment` на каждом прокси |
| Нагрузка | Минимальная | Минимальная |

**По умолчанию выключен.** Требует двух шагов для активации:

1. Установить Xray бинарник (aarch64):

   ```sh
   /usr/local/bin/xray-install.sh
   ```

2. Добавить `dialer-proxy: xray-fragment` к прокси в `/opt/clash/config.yaml`:

   ```yaml
   proxies:
     - name: "🇩🇪 Германия · WS"
       type: ws
       ...
       dialer-proxy: xray-fragment   # ← добавить эту строку
   ```

3. Перезапустить Mihomo: `/etc/init.d/clash restart`

4. Включить в LuCI: `Services → Proxy Optimizer → Xray Fragment → ON` или нажать "Запустить Xray"

UCI: `xray_fragment_enabled`, `xray_fragment_length` (default `10-30`), `xray_fragment_interval` (default `10-20`)

> Можно использовать совместно с nftables MSS — они не конфликтуют.

---

### CF IP Updater + SNI Scanner (`cf-ip-update.sh`, `sni-scan.sh`)

**Только если прокси стоят за Cloudflare CDN.** По умолчанию выключены.

- CF IP Updater: ищет быстрейший Cloudflare edge IP по регионам через Worker API, обновляет `config.yaml`, hot-reload
- SNI Scanner: тестирует SNI-варианты через SOCKS5 туннель Mihomo, выбирает лучший

UCI: `ip_updater_enabled`, `sni_scanner_enabled`, `worker_url`, `regions`, `proxy_name`, `update_threshold`, `limit_per_region`

---

## Init-скрипт (`/etc/init.d/cf-optimizer`)

При старте системы:

1. Восстанавливает последний статус latency monitor из `/etc/cf-optimizer.status` (flash) в `/var/run/` (RAM)
2. Применяет DPI bypass nftables (MSS clamp)
3. Ждёт готовности Mihomo API (loop с таймаутом 120 сек, вместо слепого `sleep 30`)
4. Запускает latency monitor как только API готов
5. Запускает Xray fragment proxy (если `xray_fragment_enabled=1`)

---

## LuCI-интерфейс

`Services → Proxy Optimizer` — единая панель управления. Две вкладки: **Overview** и **Settings**.

> Реализован на LuCI без Lua (OpenWrt 25.12 + LuCI 26.064) — JSON-меню + JS view.

### Overview

**Latency Monitor — статус** — текущий прокси GEMINI + задержка, текущий Main прокси, кнопка "Запустить мониторинг сейчас"

> Кнопка пишет trigger-файл `/var/run/latency-trigger`. Cron проверяет его каждую минуту и запускает `latency-monitor.sh` вне rpcd (решение проблемы таймаута XHR). Страница опрашивает статус каждые 3 сек и перезагружается автоматически по завершении.

**Mihomo Watchdog — статус** — последняя проверка, состояние (healthy / warning / restarting / recovered / failed), счётчик сбоев

**Xray Fragment** — кнопки Запустить / Остановить, применить / удалить `dialer-proxy` из config.yaml

**Latency Monitor — статус файл (live)** — автообновляемый лог последнего запуска (poll каждые 5 сек)

### Settings

**Включить / Выключить**:

- `Latency Monitor` — мониторинг + автопереключение GEMINI (каждые 2 часа)
- `DPI Bypass — nftables MSS` — MSS clamp для защиты от DPI
- `Mihomo Watchdog` — перезапуск при сбое (каждые 10 мин)
- `Xray Fragment — DPI bypass` — Xray SOCKS5 :10801 для фрагментации TLS ClientHello
- `Geo Update` — обновление geo-баз (раз в неделю)
- `CF IP Updater` — поиск CF edge IP (только CDN)
- `SNI Scanner` — тест SNI (только CDN)

**Настройки прокси-групп**:

- `GEMINI группа` — точное имя selector-группы (с эмодзи)
- `Main группа` — url-test группа (только мониторинг)
- `Порог переключения GEMINI (%)` — гистерезис. 20 = переключать только если экономия > 20%
- `nftables MSS Value` — для DPI bypass через MSS clamp
- `Xray — длина фрагментов` — диапазон байт (default `10-30`)
- `Xray — интервал мс` — задержка между фрагментами (default `10-20`)

**Mihomo API** — URL, secret, SOCKS5

---

## Cron расписание

| Задача | Расписание | Управление | По умолчанию |
| ------ | ---------- | ---------- | ------------ |
| Latency Monitor | каждые 2 часа | UCI `latency_enabled` | ON |
| Latency trigger (LuCI-кнопка) | каждую минуту | автоматически | ON |
| Mihomo Watchdog | каждые 10 мин | UCI `watchdog_enabled` | ON |
| Log Rotate | ежедневно 03:00 | всегда активно | ON |
| Geo Update | вс 04:00 | UCI `geo_update_enabled` | ON |
| CF IP Update | каждые 6 часов | UCI `ip_updater_enabled` | OFF |
| SNI Scan | ежедневно 02:30 | UCI `sni_scanner_enabled` | OFF |

---

## Установка Proxy Optimizer

### Способ 1 — одна команда в SSH (самый простой)

Открой SSH-сессию на роутере и выполни:

```sh
curl -fsSL https://raw.githubusercontent.com/RostislavKis/Router/master/install.sh | sh
```

`install.sh` сам скачает все нужные файлы с GitHub и запустит установку. Интернет на роутере должен работать (SSClash уже настроен).

---

### Способ 2 — `install.sh` + файлы рядом (офлайн)

```sh
# С ПК: скопировать install.sh и папку patches/ на роутер
scp -r patches/ install.sh root@192.168.1.1:/tmp/

# На роутере: одна команда
ssh root@192.168.1.1 "sh /tmp/install.sh"
```

`install.sh` автоматически обнаружит локальные файлы и не будет ничего скачивать.

---

### Способ 3 — `deploy.py` с ПК (Python)

Альтернатива для тех, кто предпочитает запускать с Windows без SSH-сессии. Впиши данные в верхнюю секцию файла и запусти:

```sh
pip install paramiko        # один раз
python -X utf8 deploy.py    # деплой
```

> `deploy.py` находится в `.gitignore` (содержит пароль) — не попадает в репозиторий.

---

### Ручной способ

### Шаг 1. Настроить переменные в установщике

Открой `patches/setup-cf-optimizer.sh` и при необходимости измени:

```sh
GEMINI_GROUP="🤖 GEMINI"       # точное имя selector-группы из config.yaml
MAIN_GROUP="PrvtVPN All Auto"  # точное имя url-test группы
SWITCH_THRESHOLD="20"           # гистерезис %: 20 = переключать только если экономия > 20%
MSS_VALUE="150"                 # DPI bypass MSS
```

### Шаг 2. Скопировать и запустить

```sh
# С ПК
scp -r patches/ root@192.168.1.1:/tmp/patches/

# На роутере
ssh root@192.168.1.1 "chmod +x /tmp/patches/setup-cf-optimizer.sh && /tmp/patches/setup-cf-optimizer.sh"
```

### Что делает установщик

1. Копирует все скрипты в `/usr/local/bin/` с правами 755 (9 скриптов)
2. Создаёт UCI-конфиг `/etc/config/cf_optimizer`:
   - **ON**: Latency Monitor, DPI Bypass, Watchdog, Geo Update
   - **OFF**: Xray Fragment (нужен бинарник), CF IP Updater, SNI Scanner (только CDN)
3. Устанавливает LuCI-файлы (меню "Proxy Optimizer", ACL, JS-view)
4. Добавляет задачи в cron (6 задач)
5. Применяет nftables DPI bypass (MSS=150)
6. Создаёт и включает `/etc/init.d/cf-optimizer`

### Шаг 3. Проверка

```sh
# Запустить latency monitor вручную (первый прогон)
/usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1 &

# Посмотреть результат (~1-2 мин)
cat /var/run/latency-monitor.status

# Watchdog статус
cat /var/run/mihomo-watchdog.status

# Xray статус
cat /var/run/xray-fragment.status

# Лог
logread | grep latency-monitor | tail -20
```

### Шаг 4 (опционально). Установить Xray Fragment

```sh
# На роутере (требует интернет через Mihomo)
/usr/local/bin/xray-install.sh

# Затем добавить в /opt/clash/config.yaml для нужных прокси:
#   dialer-proxy: xray-fragment
# Перезапустить Mihomo:
/etc/init.d/clash restart
# Включить в LuCI: Services > Proxy Optimizer > Xray Fragment > ON
```

---

## Настройка AdGuard Home

Скрипт `patches/setup-adguardhome.sh` патчит конфиг AGH:

- upstream DNS → `127.0.0.1:1053` (Mihomo fake-ip)
- отключает AAAA-запросы
- устанавливает логин/пароль

**Перед запуском** — впиши свои данные в скрипт:

```sh
AGH_USER="root"
AGH_PASSWORD_HASH='$2y$10$REPLACE_THIS_WITH_YOUR_BCRYPT_HASH'

# Сгенерировать bcrypt-хэш:
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

```text
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
> Если забыл — можно доустановить: `apk add kmod-nft-tproxy` (после фикса wget).

1. Скачай `*-squashfs-sysupgrade.bin`

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
```

#### 3.2 Установка пакетов (если не были в прошивке)

```sh
apk add kmod-nft-tproxy iptables-nft
```

---

### Шаг 4. Установка SSClash

```sh
apk add luci-app-ssclash
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

# DNS
nslookup gemini.google.com 127.0.0.1  # → 198.18.x.x (fake-ip → прокси)
nslookup yandex.ru 127.0.0.1          # → реальный IP (direct)

# DPI bypass активен
nft list table inet cf_dpi_bypass

# Latency monitor + watchdog
cat /var/run/latency-monitor.status
cat /var/run/mihomo-watchdog.status
```

---

## UCI-конфиг (`/etc/config/cf_optimizer`)

```sh
# Latency monitor
uci set cf_optimizer.main.latency_enabled=1
uci set cf_optimizer.main.gemini_group='🤖 GEMINI'
uci set cf_optimizer.main.main_group='PrvtVPN All Auto'
uci set cf_optimizer.main.switch_threshold=20   # гистерезис %

# DPI bypass
uci set cf_optimizer.main.dpi_bypass_enabled=1
uci set cf_optimizer.main.mss_value=150

# Watchdog
uci set cf_optimizer.main.watchdog_enabled=1

# Geo update (включён по умолчанию)
uci set cf_optimizer.main.geo_update_enabled=1

# Xray fragment (выключен по умолчанию — нужен бинарник)
uci set cf_optimizer.main.xray_fragment_enabled=0
uci set cf_optimizer.main.xray_fragment_length='10-30'
uci set cf_optimizer.main.xray_fragment_interval='10-20'

# Mihomo API
uci set cf_optimizer.main.mihomo_api='http://127.0.0.1:9090'
uci set cf_optimizer.main.mihomo_secret=''       # если secret задан в config.yaml

uci commit cf_optimizer
```

---

## Конфиг SSClash — ключевые параметры

```yaml
tproxy-port: 7894
routing-mark: 2       # трафик Mihomo — не уходит в TPROXY-петлю

dns:
  enable: true
  listen: '127.0.0.1:1053'
  enhanced-mode: fake-ip
  ipv6: false

proxy-groups:
  # Selector-группа — Latency Monitor управляет выбором
  - name: "🤖 GEMINI"
    type: select
    proxies:
      - "🇩🇪 Германия · WS"
      - "🇳🇱 Netherlands · VLESS"

  # url-test — Mihomo управляет сам, Latency Monitor только читает
  - name: "PrvtVPN All Auto"
    type: url-test
    proxies:
      - "Server1"
      - "Server2"
```

---

## Полезные команды

```sh
# Статус
cat /var/run/latency-monitor.status
cat /var/run/mihomo-watchdog.status
cat /var/run/xray-fragment.status

# Запустить вручную
/usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1 &
/usr/local/bin/mihomo-watchdog.sh >> /var/log/mihomo-watchdog.log 2>&1
/usr/local/bin/xray-control.sh start
/usr/local/bin/xray-control.sh stop
/usr/local/bin/xray-control.sh status

# Логи
logread | grep latency-monitor | tail -20
logread | grep mihomo-watchdog | tail -10
logread | grep xray-fragment | tail -10
tail -f /var/log/latency-monitor.log

# Mihomo API
curl http://127.0.0.1:9090/version
curl http://127.0.0.1:9090/proxies | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['proxies'].keys()))"

# DPI bypass
nft list table inet cf_dpi_bypass
nft delete table inet cf_dpi_bypass                 # выключить
nft -f /etc/nftables.d/99-cf-dpi-bypass.nft        # включить

# Cron
crontab -l

# Аудит сетевых модулей
apk list --installed | grep -E '(iptables|nftables|tproxy|kmod)'
lsmod | grep -E '(tproxy|nft_tproxy)'
```

---

## Известные проблемы и решения

| Проблема | Причина | Решение |
|---------|---------|---------|
| `apk update` — "unexpected end of file" | `wget` → `wget-nossl` (без HTTPS) | `ln -sf /bin/uclient-fetch /usr/bin/wget` |
| `Error: Could not process rule: No such file or directory` | `kmod-nft-tproxy` не установлен | `apk add kmod-nft-tproxy` |
| `ERROR: Neither nftables nor iptables found` | `iptables` не установлен | `apk add iptables-nft` |
| DNS SERVFAIL для всех доменов | AGH не может достучаться до Mihomo DNS | `aaaa_disabled: true` в adguardhome.yaml |
| Домены `.ru` не резолвятся | Цикл: `direct-nameserver: system` → AGH → Clash | Убрать `system`, использовать `1.1.1.1` |
| GEMINI переключается слишком часто | `switch_threshold` = 0 | Установить 20: `uci set cf_optimizer.main.switch_threshold=20` |
| GEMINI не переключается | Имя группы в UCI не совпадает с Mihomo | Проверить: `uci get cf_optimizer.main.gemini_group` |
| Watchdog постоянно перезапускает | Mihomo API меняет порт или secret | Проверить `cf_optimizer.main.mihomo_api` и `mihomo_secret` |
| Lock file завис после сбоя | Скрипт убит без trap (SIGKILL) | `rm -f /var/run/latency-monitor.lock` |
| AGH не скачивает фильтры (таймаут `198.18.x.x`) | `github.io` / `adaway.org` не в `fake-ip-filter` → AGH получает фейковый IP | Добавить `+.github.io` и `+.adaway.org` в `fake-ip-filter` в `config.yaml`, перезапустить Mihomo |
| DNS перестал работать после hot-reload | Hot-reload через `/configs` API иногда ломает DNS-листенер `:1053` | `killall clash && /etc/init.d/clash start` (полный перезапуск) |

---

## Обновление прошивки (сохранить настройки)

При sysupgrade настройки в `/overlay` сохраняются.

**Сохраняется:** AGH config, SSClash init, clash-rules, config.yaml, UCI конфиги, LuCI, nftables.
**Не сохраняется:** пакеты `apk` (kmod-nft-tproxy, iptables-nft, wget-симлинк).

После обновления:
```sh
ln -sf /bin/uclient-fetch /usr/bin/wget
apk update
apk add kmod-nft-tproxy iptables-nft
/etc/init.d/clash restart
/etc/init.d/adguardhome restart
```
