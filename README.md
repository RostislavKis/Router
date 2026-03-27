# GL-iNet Flint 2 — SSClash + AdGuard Home + Proxy Optimizer

**Железо:** GL-iNet Flint 2 (GL-MT6000) · **Прошивка:** OpenWrt 25.12.0 r32713-f919e7899d · **Арх.:** aarch64_cortex-a53 (mediatek/filogic)

Прозрачный прокси-роутер для всей домашней сети. Каждое устройство — телефон, ТВ, ПК — ходит в обход блокировок без каких-либо настроек на самом устройстве. DNS-реклама режется на уровне роутера. Набор авторских скриптов следит за скоростью и доступностью прокси в фоне: переключает группы, перезапускает зависший Mihomo, обновляет геобазы, бэкапит конфиг.

---

## Что умеет из коробки

**Умный выбор прокси для Gemini / заблокированных сервисов**
`latency-monitor.sh` каждую минуту делает быструю гео-проверку активного прокси; полный цикл — тест задержки всех прокси через Mihomo API + HEAD-запрос к `gemini.google.com` — запускается раз в 5 минут. Прокси с `gl=RU`, `gl=BY`, `gl=KZ` в редиректе Google отбрасываются, даже если у них лучший пинг. GEMINI-группа — тип **Selector**: Mihomo не трогает выбор сам, всем управляет скрипт. Переключение происходит только если новый вариант быстрее текущего на 30% и более — мелкие флуктуации не дёргают активные соединения.

**Защита конфига Clash — бэкап и авторестор**
`clash-watchdog.sh` каждые 30 минут перезаписывает единственный файл бэкапа (`config.yaml.backup`) если Clash работает нормально. При недоступности порта 7894 ждёт до 3 минут, пробует рестарт, при неудаче откатывается к последнему рабочему конфигу. Один бэкап — никакого накопления файлов.

**Защита от NTP Boot Loop**
OpenWrt по умолчанию использует `*.openwrt.pool.ntp.org`. Эти домены не входят в `fake-ip-filter` → Mihomo возвращает фиктивный IP 198.18.x.x → NTP не синхронизируется при каждом старте роутера. `setup-cf-optimizer.sh` заменяет NTP-серверы на `time.google.com`, `time.cloudflare.com`, `0.pool.ntp.org` — все они явно прописаны в `fake-ip-filter` и получают реальные IP.

**DPI bypass через MSS clamping**
`99-cf-dpi-bypass.nft` снижает TCP MSS до 150 байт для исходящего трафика Mihomo (routing-mark=2) на портах 443, 2053, 2083, 2087, 2096. TLS ClientHello с SNI разбивается на несколько сегментов — DPI-инспектор не видит имя сервера целиком. MSS регулируется через LuCI (40–1460 байт).

**Telegram MTProto через прокси**
Telegram использует хардкодные IP-адреса (`149.154.160.0/20`, `91.108.x.x/22`), а не домены. Обычный TPROXY их не перехватывает. `98-telegram-tproxy.nft` помечает эти пакеты флагом 0x1 с приоритетом -200 — раньше, чем срабатывает цепочка Mihomo. Итог: Telegram идёт через группу TELEGRAM, а не напрямую.

**Watchdog Mihomo**
`mihomo-watchdog.sh` каждые 10 минут обращается к `/version` и `/proxies` API. Два последовательных сбоя — перезапуск службы `clash`, ожидание восстановления до 30 секунд, затем перезапуск `cf-optimizer`. Счётчик сбоев хранится в `/var/run/mihomo-watchdog.fails`.

**VLESS+Reality VPN-сервер** *(опционально)*
Xray-core запускается как VLESS-сервер на порту 443 с маскировкой под `www.microsoft.com` (XTLS-Vision). Все подключения проходят через Mihomo SOCKS5 `:7891` — к ним применяются те же правила что и к LAN-трафику. Позволяет подключаться к роутеру как к VPN извне. Управление: `xray-vless-ctl.sh {start|stop|status}`.

**Xray TLS Fragment** *(опционально)*
Отдельный SOCKS5-прокси на порту 10801, который фрагментирует TLS ClientHello через протокол freedom с режимом `tlshello`. Подключается через `dialer-proxy: xray-fragment` в config.yaml. Массово добавить или убрать из всех прокси — одной кнопкой в LuCI.

**SNI-оптимизация** *(отключена по умолчанию, только для CF-прокси)*
`sni-scan.sh` ежесуточно перебирает SNI-варианты через реальный SOCKS5-тоннель `:7891` и обновляет `sni:` у прокси с горячим релоадом Mihomo.

---

## Архитектура

### DNS

```text
Устройство (UDP/TCP :53)
    │
    ▼
AdGuard Home  :53  @ 192.168.1.1       ← блокировка рекламы и трекеров
    │  upstream → 127.0.0.1:1053
    ▼
Mihomo DNS  :1053  (fake-ip, 198.18.0.0/16)
    │
    ├── домен в fake-ip-filter (*.ru, *.ya.ru, *.yandex.ru и др.)
    │       → реальный IP → клиент → DIRECT через fw4 NAT
    │
    └── всё остальное
            → fake-ip 198.18.x.x → клиент → TPROXY → Mihomo → прокси-группа
```

### Трафик

```text
Telegram (149.154.x.x / 91.108.x.x)
    → inet telegram_tproxy  priority -200  →  mark=0x1
    → inet clash proxy  TPROXY :7894
    → Mihomo: IP-CIDR → TELEGRAM group

Остальной трафик (fake-ip 198.18.x.x + реальные IP без fake-ip-filter)
    → inet clash  CLASH_MARK
        ├── UDP :443  → REJECT  (гасим QUIC, форсируем TCP)
        └── остальное  → mark=0x1  → TPROXY :7894
            → Mihomo: rules → GEMINI / MAIN-PROXY / DIRECT / REJECT
```

> **Важно:** CLASH_MARK маркирует весь TCP/UDP трафик, не только диапазон 198.18.0.0/16. Домены в `fake-ip-filter` получают реальные IP, но без общей маркировки они обходят TPROXY и уходят напрямую — не через прокси.

### Порядок старта сервисов

```text
AGH (START=19) → dnsmasq (20) → SSClash/Mihomo (21) → cf-optimizer (96)
```

`cf-optimizer` ждёт готовности Mihomo API (максимум 120 сек), только потом применяет nftables-правила и запускает latency-monitor.

---

## Установка

### Шаг 1. Подготовить config.yaml

Взять готовый `config.yaml` от провайдера подписки. Обязательные параметры:

```yaml
mixed-port: 7890
socks-port: 7891
tproxy-port: 7894
routing-mark: 2

dns:
  listen: 0.0.0.0:1053
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.pool.ntp.org"
    - "time.google.com"
    - "time.cloudflare.com"
    - "+.ru"
    - "+.github.com"
    - "+.githubusercontent.com"
    - "+.github.io"
    - "+.microsoft.com"
```

### Шаг 2. Запустить установку

`install.sh` — единый скрипт установки. Последовательно запускает `setup-clash.sh` → `setup-adguardhome.sh` → `setup-cf-optimizer.sh`, спрашивает пароль для SSH/LuCI и AdGuard Home, умеет работать как с локальными файлами, так и загружать всё с GitHub.

**Способ А — одна строка прямо на роутере** (нужен интернет):

```sh
curl -fsSL https://raw.githubusercontent.com/RostislavKis/Router/master/install.sh | sh
```

**Способ Б — с ПК через scp** (если интернет на роутере ещё не настроен):

```sh
# Сначала скопировать config.yaml в корень репозитория
scp -r . root@192.168.1.1:/tmp/router/
ssh root@192.168.1.1 "sh /tmp/router/install.sh"
```

После завершения открыть `http://192.168.1.1:3000` — AdGuard Home попросит задать upstream DNS: `127.0.0.1:1053`.

### Safe Install — автоматический откат при ошибках

При обновлении только Proxy Optimizer на уже работающем роутере используй `safe-install.sh` вместо прямого вызова `setup-cf-optimizer.sh`. Если что-то сломается — роутер сам вернётся в исходное состояние.

```sh
scp -r patches/ root@192.168.1.1:/tmp/cf-optimizer-deploy/
ssh root@192.168.1.1 "sh /tmp/cf-optimizer-deploy/safe-install.sh"
```

Что делает предохранитель:

1. Снимает бэкап `/etc/config/{dhcp,firewall,network,system}` и crontab
2. Фиксирует baseline: Mihomo работает? AGH работает? Ping 8.8.8.8? DNS?
3. Запускает `setup-cf-optimizer.sh`
4. Ждёт 15 секунд, повторяет те же 4 проверки
5. При провале: удаляет кастомные nftables-таблицы, восстанавливает UCI из бэкапа, перезапускает `network`/`dnsmasq`/`firewall`
6. При успехе: удаляет временные бэкапы

---

## Все скрипты — что и зачем

| Скрипт | Запуск | Задача |
| --- | --- | --- |
| `latency-monitor.sh` | cron каждую минуту (полный цикл раз в 5 мин) + 1-мин триггер | Тестирует прокси в GEMINI группе (Selector); валидирует геодоступность через `gl=` код Google; переключает с гистерезисом 30% |
| `clash-watchdog.sh` | cron каждые 30 мин + @reboot | Перезаписывает единственный бэкап config.yaml если Clash работает; при недоступности :7894 — рестарт, при неудаче — откат к бэкапу |
| `mihomo-watchdog.sh` | cron каждые 10 мин | Проверяет `/version` + `/proxies` API; 2 сбоя подряд → перезапуск Mihomo → перезапуск cf-optimizer |
| `sni-scan.sh` | cron 02:30 *(откл.)* | Перебирает SNI-варианты через реальный SOCKS5-тоннель `:7891`; обновляет `sni:` у прокси с горячим релоадом |
| `xray-control.sh` | init.d + LuCI | Старт/стоп Xray fragment SOCKS5 на `:10801`; PID-верификация через `/proc/$pid/cmdline` |
| `xray-apply-config.sh` | LuCI кнопки | Batch-добавление/удаление `dialer-proxy: xray-fragment` у всех прокси в config.yaml |
| `latency-start.sh` | LuCI кнопка | Кладёт `/var/run/latency-trigger` и выходит — обходит 60-сек таймаут rpcd-subreaper |
| `geo-update.sh` | cron вс 04:00 | Скачивает geoip.dat, geosite.dat, country.mmdb с MetaCubeX; если обновилось — перезапуск Mihomo |
| `log-rotate.sh` | cron 03:00 | Обрезает лог-файлы в tmpfs (RAM) до 500 строк |
| `99-cf-dpi-bypass.nft` | при старте cf-optimizer | MSS clamping 150 байт для mark=2 трафика на портах 443/2053/2083/2087/2096 |
| `98-telegram-tproxy.nft` | при старте, после Mihomo API | Помечает Telegram IP-диапазоны mark=0x1 с приоритетом -200 |

Все скрипты с параллельным запуском защищены PID-based lock-файлами в `/var/run/`. Если процесс мёртв — lock удаляется автоматически. Логи: `/var/log/{script-name}.log` (tmpfs, не переживают перезагрузку).

Статусные файлы (читаются LuCI):

```text
/var/run/latency-monitor.status    — текущий прокси, задержка, время последнего запуска
/var/run/mihomo-watchdog.status    — статус watchdog, счётчик сбоев
/var/run/xray-fragment.status      — статус Xray, PID
```

Персистентная копия статуса (переживает перезагрузку): `/etc/cf-optimizer.status`

---

## LuCI: Сервисы → Proxy Optimizer

**Вкладка Overview** — дашборд с авто-обновлением раз в 5 секунд:

- Текущий прокси GEMINI-группы + задержка (зелёный / красный)
- Статус Mihomo Watchdog: healthy / warning / failed + счётчик сбоев
- Статус Xray Fragment: running / stopped / not_installed + PID
- Кнопка «Запустить мониторинг» (через триггер-файл, без блокировки UI)
- Кнопки управления Xray и dialer-proxy

**Вкладка Settings** — UCI-форма `/etc/config/cf_optimizer`:

- Включение/выключение каждого компонента независимо
- Имена прокси-групп, порог переключения (%)
- MSS value, Xray fragment length/interval
- Mihomo API URL, секрет, SOCKS5 для SNI-тестов

---

## Обновление прошивки (Sysupgrade)

`/opt/clash/` смонтирован на отдельном ext4-разделе Flint 2 — `config.yaml` и данные AdGuard Home переживают прошивку автоматически.

Скрипты и cron хранятся в rootfs и сотрутся. Перед прошивкой убедиться, что в `/etc/sysupgrade.conf` есть:

```text
/etc/config/cf_optimizer
/etc/cf-optimizer/
/etc/init.d/cf-optimizer
/etc/sysctl.conf
/usr/local/bin/
/etc/crontabs/root
```

После прошивки — повторить Шаг 3 (`setup-cf-optimizer.sh`). Конфиг UCI и скрипты обновятся, `config.yaml` останется нетронутым.

---

## Частые ситуации

### Кнопка «Запустить мониторинг» нажалась, но ничего не происходит минуту

Это нормально. Кнопка только создаёт триггер-файл. Cron подхватывает его в течение минуты и запускает `latency-monitor.sh` уже вне контекста rpcd.

### Gemini продолжает показывать геоблок

1. Проверить активный прокси: `curl -s http://127.0.0.1:9090/proxies` + имя GEMINI-группы
2. Проверить нет ли IPv6 на устройстве — IPv6-трафик TPROXY не перехватывает, он идёт в обход прокси напрямую
3. Проверить DNS: устройство должно получать DNS только с `192.168.1.1` (AGH)

### Mihomo не стартует, NTP зависает при загрузке

```sh
uci get system.ntp.server
# Должны быть: time.google.com time.cloudflare.com 0.pool.ntp.org 1.pool.ntp.org
```

Если там `*.openwrt.pool.ntp.org` — запустить `setup-cf-optimizer.sh` заново.

### После смены config.yaml Clash не поднимается

Clash-watchdog автоматически откатится к `config.yaml.backup` через 3 минуты. Но если хочется не ждать:

```sh
cp /opt/clash/config.yaml.failed /tmp/config-broken.yaml   # сохранить для анализа
cp /opt/clash/config.yaml.backup /opt/clash/config.yaml
/etc/init.d/clash restart
```

### Посмотреть логи в реальном времени

```sh
logread -f | grep -E 'cf-optimizer|clash|adguard'
tail -f /var/log/latency-monitor.log
tail -f /var/log/clash-watchdog.log
```
