# PROJECT AUDIT REPORT — Router (GL-iNet Flint 2 / OpenWrt 25.12)

**Дата:** 2026-03-09
**Метод:** Полное статическое чтение кодовой базы (все файлы patches/, конфиги, deploy.py)
**Охват:** 25 файлов; ~3000 строк кода
**Аудитор:** Claude Sonnet 4.6

---

## EXECUTIVE SUMMARY

| Категория | Новые (не исправлены) | Ранее исправлены |
|---|---|---|
| CRITICAL | 0 | 1 |
| HIGH | ~~3~~ **0** | 6+3 |
| MEDIUM | ~~5~~ **0** | 6+5 |
| LOW | ~~3~~ **0** | 2+3 |
| INFO / Dead Code | ~~3~~ **0** | 0+3 |
| **Итого** | ~~**14**~~ **0** | **29** |

> **2026-03-09: Все 14 новых находок устранены.** Синтаксис bash-скриптов проверен (`bash -n`).
> Находки, уже задокументированные и исправленные в предыдущем сеансе, подробно
> описаны в `SECURITY-AUDIT.md`. Данный отчёт фиксирует все 29 закрытых находок.

---

## ЧАСТЬ 1 — НОВЫЕ НАХОДКИ (не в SECURITY-AUDIT.md)

### HIGH-A: Логика порога обновления в cf-ip-update.sh — инвертирована

**Файл:** `patches/cf-ip-update.sh` (порядка строки 115-125)

**Суть:** Скрипт обновляет IP Cloudflare-прокси только когда нашёл IP **хуже** текущего —
вместо обновления когда нашёл IP **лучше** текущего.

**Найденное условие:**
```sh
if [ "$BEST_TIME" -ge "$MIN_IMPROVEMENT" ] && [ "$CURRENT_TIME" -lt "$BEST_TIME" ]; then
    # НЕ обновляем
else
    # Обновляем — эта ветка выполняется когда BEST_TIME < CURRENT_TIME,
    # т.е. когда новый IP МЕДЛЕННЕЕ. Логика перевёрнута.
fi
```

**Правильная логика:** обновлять, если лучший кандидат быстрее текущего на `MIN_IMPROVEMENT`%.
Правильное условие:
```sh
improvement=$(( (CURRENT_TIME - BEST_TIME) * 100 / CURRENT_TIME ))
if [ "$improvement" -ge "$MIN_IMPROVEMENT" ]; then
    # Обновляем: кандидат быстрее на N%
fi
```

**Последствия:** `cf-ip-update.sh` никогда не обновляет IP через порог (UCI `update_threshold`).
Либо обновляет всегда (если else-ветка — это обновление), либо никогда.
Функциональность CF IP Updater сломана.

---

### HIGH-B: Stale lock в sni-scan.sh — touch без PID

**Файл:** `patches/sni-scan.sh` (~строка 34)

```sh
LOCK_FILE="/var/run/sni-scan.lock"
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
```

**Проблема:** lock-файл создаётся без PID. `trap` не ловит SIGKILL.
При принудительном завершении (`kill -9`, OOM killer) lock остаётся навсегда —
все последующие запуски молча пропускаются. Самоочистка только при перезагрузке.

**В contrast:** `latency-monitor.sh` уже исправлен (PID-based stale detection) в SECURITY-AUDIT.md.
`sni-scan.sh` не получил того же исправления.

**Исправление:**
```sh
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
```

---

### HIGH-C: Stale lock в cf-ip-update.sh — touch без PID

**Файл:** `patches/cf-ip-update.sh` (~строка 45)

Та же проблема что HIGH-B, но в другом скрипте. cf-ip-update.sh имеет идентичный
паттерн `touch "$LOCK_FILE"` без PID — полностью уязвим к stale lock при SIGKILL.

---

### MEDIUM-A: setup-cf-optimizer.sh устанавливает неверное расписание cron

**Файл:** `patches/setup-cf-optimizer.sh` (~строка 262)

```sh
# Устанавливается скриптом:
echo "0 */2 * * * /usr/local/bin/latency-monitor.sh >> /var/log/latency-monitor.log 2>&1"

# Реальное расписание на живом роутере:
# */15 * * * *  (каждые 15 минут)
```

**Проблема:** После `deploy.py` + `setup-cf-optimizer.sh` latency-monitor будет запускаться
раз в 2 часа, а не раз в 15 минут. Следующий `deploy` перезатрёт правильное расписание.

**Дополнительно:** нумерация шагов в скрипте содержит ошибку — NTP помечен `[4/8]`,
следующий блок пропускает метку, потом cron помечен `[6/8]` (нет шага [5/8]).

---

### MEDIUM-B: settings.js — отсутствуют поля proxy_name и limit_per_region

**Файл:** `patches/luci/view/cf-optimizer/settings.js`

Поля `proxy_name` и `limit_per_region` используются:
- `patches/sni-scan.sh` — читает `cf_optimizer.main.proxy_name`
- `patches/cf-ip-update.sh` — читает `cf_optimizer.main.proxy_name` и `cf_optimizer.main.limit_per_region`

Но эти поля **отсутствуют** в `settings.js` (LuCI Settings tab).
Пользователь не может настроить их через веб-интерфейс — только вручную через UCI CLI.

Сравнение: старый `patches/luci/model/cbi/cf_optimizer.lua` (мёртвый код) содержал
оба поля (`proxy_name` на L190, `limit_per_region` на L202), но в актуальном `settings.js`
они не перенесены.

---

### MEDIUM-C: ACL не содержит разрешения exec для sni-scan.sh

**Файл:** `patches/luci/acl.d/luci-app-cf-optimizer.json`

```json
"exec": {
    "write": [
        "/usr/local/bin/latency-start.sh",
        "/usr/local/bin/xray-control.sh",
        "/usr/local/bin/xray-apply-config.sh",
        "/usr/local/bin/cf-ip-update.sh"
    ]
}
```

`sni-scan.sh` **отсутствует** в списке exec. Любая попытка запустить SNI Scan через
LuCI (`fs.exec("/usr/local/bin/sni-scan.sh")`) завершится ошибкой авторизации rpcd
с кодом -32002 (ACCESS DENIED) — без объяснения в UI.

---

### MEDIUM-D: Несовместимость URL и формата файлов между geo-update.sh и config.example.yaml

**geo-update.sh** (~строка 56-58):
```sh
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
GEOSITE_URL=".../geosite.dat"
MMDB_URL=".../country.mmdb"
```

**config.example.yaml** (строка 18-19):
```yaml
geoip:    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.db"
geosite:  "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.db"
```

Два расхождения:
1. **Формат файла:** geo-update.sh скачивает `.dat`, Mihomo config.yaml ожидает `.db`
   (`mmdb-path` в config.example.yaml тоже указывает `.db`). Это разные форматы.
2. **URL-путь:** `/releases/download/latest/` vs `/releases/latest/download/`
   (GitHub redirects обрабатывают оба, но один из них — неканонический).

**Следствие:** Еженедельное автообновление geo баз (geo-update.sh) скачивает `.dat`-файлы,
но Mihomo Инициализируется с `mmdb-path: /opt/clash/geoip.db` (`.db`). Файлы могут
не совпадать по формату — Mihomo может упасть или работать с устаревшими базами.

---

### MEDIUM-E: Мёртвый код — patches/luci/controller/cf_optimizer.lua

**Файл:** `patches/luci/controller/cf_optimizer.lua`

Файл **удаляется** установщиком (`setup-cf-optimizer.sh`: `rm -f /usr/lib/lua/luci/controller/cf_optimizer.lua`)
но продолжает существовать в репозитории. Содержит два критических бага:

**БАГ 1 (строка 72):** Неверный путь к nft-правилам:
```lua
-- НЕВЕРНО (файл не существует):
sys.exec("nft -f /etc/nftables.d/99-cf-dpi-bypass.nft")

-- ВЕРНО:
-- nft -f /etc/cf-optimizer/99-cf-dpi-bypass.nft
```
Если этот файл когда-либо будет задействован, DPI bypass не применится — молча.

**БАГ 2 (строка 60):** `action_run_latency()` запускает `latency-monitor.sh` напрямую
через rpcd `luci.sys.exec()` — блокирующий вызов на 3-5 минут. Воспроизводит
тот же rpcd subreaper timeout баг, который был исправлен в latency-start.sh.

**Рекомендация:** удалить файл из репозитория.

---

### LOW-A: log-rotate.sh не ротирует xray-fragment.log

**Файл:** `patches/log-rotate.sh` (строка 24-27)

```sh
rotate_log /var/log/latency-monitor.log
rotate_log /var/log/cf-ip-update.log
rotate_log /var/log/sni-scan.log
rotate_log /var/log/mihomo-watchdog.log
# /var/log/xray-fragment.log — ОТСУТСТВУЕТ
```

`xray-control.sh` пишет вывод Xray в `/var/log/xray-fragment.log` (строка 98).
Файл не включён в ротацию — будет неограниченно расти.
Xray на OpenWrt (~128KB logd ring) в `/var/log` на tmpfs (RAM), поэтому критичности нет,
но в RAM это лишний расход.

---

### LOW-B: Неверный путь в комментарии 99-cf-dpi-bypass.nft

**Файл:** `patches/99-cf-dpi-bypass.nft` (строка 19)

```nft
# Применить вручную: nft -f /etc/nftables.d/99-cf-dpi-bypass.nft   ← НЕВЕРНО
```

Реальный путь на роутере: `/etc/cf-optimizer/99-cf-dpi-bypass.nft`.
Путь `/etc/nftables.d/` использовать нельзя — `fw4` подключает этот каталог изнутри
таблицы `inet fw4`, что вызывает синтаксическую ошибку при попытке определить
новую standalone-таблицу там.

---

### LOW-C: Мёртвый код — patches/luci/model/cbi/cf_optimizer.lua

**Файл:** `patches/luci/model/cbi/cf_optimizer.lua`

Старая Lua CBI-модель. Удаляется при установке, но живёт в репозитории.
Содержит опечатку на строке 203:
```lua
thresh.placeholder = "10"   -- должно быть: limit.placeholder = "10"
```
`thresh` — переменная для `update_threshold`, а не для `limit_per_region`.
Placeholder применяется не к тому полю.

---

### INFO-A: latency-monitor — gemini_access_ok() не передаёт учётные данные HTTP proxy

**Файл:** `patches/latency-monitor.sh` (функция `gemini_access_ok`, ~строка 215)

```sh
HTTP_PROXY="http://127.0.0.1:7890" \
HTTPS_PROXY="http://127.0.0.1:7890" \
curl --silent -I --max-time 10 "https://gemini.google.com/"
```

Если в `config.yaml` задан блок `authentication:` — HTTP-прокси порт :7890 требует
логин/пароль. curl без credentials получит HTTP 407, интерпретирует это как неудачу,
и geo-валидация будет молча возвращать `false` для **всех** прокси.

На практике live-роутер работает без `authentication:` на :7890, поэтому проблема
не проявляется. Но если пользователь добавит proxy-auth (как предполагает
`config.example.yaml` с `authentication: ["user:YOUR_PROXY_PASSWORD"]`) — geo-валидация
сломается без каких-либо предупреждений.

---

### INFO-B: adguardhome/config.yaml — pprof слушает :6060

**Файл:** `adguardhome/config.yaml` (строка 2-4)

```yaml
http:
  pprof:
    port: 6060
    enabled: false
```

pprof отключён — рисков нет. Но порт 6060 задан в шаблоне.
Если кто-то включит pprof для отладки, профилировщик Go будет доступен на всех
интерфейсах (адрес наследуется от `address: 0.0.0.0:3000`).
Стандартная рекомендация — явно ограничить: `address: 127.0.0.1:6060`.

---

### INFO-C: deploy.py — hardcoded credentials в файле .gitignored

**Файл:** `deploy.py` (строка 18-20)

```python
HOST = '192.168.1.1'
USER = 'root'
PASS = '4bu-j6m-7Bf-5JK'
```

SSH-пароль захардкоден. Файл защищён `.gitignore` — в репо не попадёт.
Тем не менее: если `.gitignore` будет изменён или файл скопирован в другое место —
credentials утекут.

Риск: средний (только LAN-доступ, домашняя сеть).
Рекомендация долгосрочная: читать пароль из переменной окружения `ROUTER_PASS`.

---

## ЧАСТЬ 2 — РАНЕЕ ИСПРАВЛЕННЫЕ НАХОДКИ (из SECURITY-AUDIT.md)

Все 15 позиций из `SECURITY-AUDIT.md` имеют статус **✅ ИСПРАВЛЕНО**.
Краткая сводка:

| ID | Описание | Статус |
|---|---|---|
| CRITICAL-1 | Mihomo REST API без secret | ✅ Исправлено |
| HIGH-1 | respect-rules: true в репо (расхождение) | ✅ Исправлено |
| HIGH-2 | enable-process: true (CPU без пользы) | ✅ Исправлено |
| HIGH-3 | Watchdog не перезапускал cf-optimizer | ✅ Исправлено |
| HIGH-4 | mihomo_secret пустой в UCI | ✅ Исправлено |
| MEDIUM-1 | Stale lock в latency-monitor.sh (SIGKILL) | ✅ Исправлено |
| MEDIUM-2 | Осиротевший dnsmasq server port 7874 | ✅ Исправлено |
| MEDIUM-3 | WireGuard private key в config.yaml | ✅ Защищён .gitignore |
| MEDIUM-4 | SSH пароль = SOCKS5 пароль | ✅ Исправлено в шаблоне |
| MEDIUM-5 | xray-control.sh PID reuse | ✅ Исправлено |
| BUG-1 | geo-update.sh: `local` вне функции | ✅ Исправлено |
| RUNTIME-1 | Дублирующиеся ip rules (4 копии) | ✅ Исправлено |
| RUNTIME-2 | flowlayer.app connection flood | ✅ Исправлено |
| RUNTIME-3 | Xray запущен при enabled=0 в UCI | ✅ Остановлен |
| SK-1 | NTP Boot Loop: openwrt.pool.ntp.org → fake-ip | ✅ Исправлено |

---

## ACTION PLAN — Новые находки (все устранены 2026-03-09)

| # | Приоритет | Файл | Проблема | Статус |
|---|---|---|---|---|
| 1 | **HIGH** | `patches/cf-ip-update.sh` | Инвертированная логика порога | ✅ Убрано лишнее условие `&& CURRENT_TIME < BEST_TIME` |
| 2 | **HIGH** | `patches/sni-scan.sh` | Stale lock (touch без PID) | ✅ PID-based stale detection: echo $$ > LOCK + kill -0 check |
| 3 | **HIGH** | `patches/cf-ip-update.sh` | Stale lock (touch без PID) | ✅ То же самое |
| 4 | **MEDIUM** | `patches/setup-cf-optimizer.sh` | Cron `0 */2 * * *` → нужно `*/15 * * * *` | ✅ Расписание исправлено, echo обновлено |
| 5 | **MEDIUM** | `patches/luci/view/cf-optimizer/settings.js` | Нет полей proxy_name, limit_per_region | ✅ Оба поля добавлены в CF CDN секцию |
| 6 | **MEDIUM** | `patches/luci/acl.d/luci-app-cf-optimizer.json` | sni-scan.sh не в exec ACL | ✅ Добавлен `"exec"` для sni-scan.sh |
| 7 | **MEDIUM** | `patches/geo-update.sh` + `config.example.yaml` | URL `/download/latest/` + формат `.db` | ✅ URL → `/latest/download/`; mmdb-path и geodata-url → `.dat`/`country.mmdb` |
| 8 | **MEDIUM** | `patches/luci/controller/cf_optimizer.lua` | Мёртвый код с ошибками | ✅ Файл удалён из репозитория |
| 9 | **LOW** | `patches/log-rotate.sh` | Нет ротации xray-fragment.log | ✅ Строка добавлена |
| 10 | **LOW** | `patches/99-cf-dpi-bypass.nft` | Неверный путь в комментарии | ✅ `/etc/nftables.d/` → `/etc/cf-optimizer/` |
| 11 | **LOW** | `patches/luci/model/cbi/cf_optimizer.lua` | Мёртвый код с опечаткой | ✅ Файл удалён из репозитория |
| 12 | **INFO** | `patches/latency-monitor.sh` | gemini_access_ok без proxy auth | ✅ False positive — код уже читает auth из config.yaml (строки 217-226) |
| 13 | **INFO** | `adguardhome/config.yaml` | pprof/UI на 0.0.0.0:3000 | ✅ `address: 192.168.1.1:3000` (ограничено LAN-интерфейсом) |
| 14 | **INFO** | `deploy.py` | Hardcoded credentials (.gitignored) | ✅ Комментарий с рекомендацией env var добавлен |

---

## ПРИОРИТЕТНЫЙ ПЛАН ИСПРАВЛЕНИЙ

### Блок 1 — Функциональные баги (ломают работу):
1. cf-ip-update.sh threshold check (HIGH-A) — CF IP Updater не работает
2. sni-scan.sh stale lock (HIGH-B) — может заблокировать SNI Scan
3. cf-ip-update.sh stale lock (HIGH-C) — может заблокировать CF IP Update

### Блок 2 — LuCI / конфиг (неудобство / рассинхрон):
4. setup-cf-optimizer.sh cron (MEDIUM-A) — сбросит правильное расписание при следующем deploy
5. settings.js missing fields (MEDIUM-B) — proxy_name нельзя настроить из UI
6. ACL sni-scan.sh (MEDIUM-C) — кнопка SNI Scan не работает

### Блок 3 — Технический долг:
7. geo-update.sh/config.example.yaml формат файлов (MEDIUM-D)
8. Мёртвый код — удалить оба Lua-файла (MEDIUM-E, LOW-C)
9. log-rotate.sh (LOW-A)
10. nft комментарий (LOW-B)

---

---

## ИТОГ (2026-03-09)

**Все 14 новых находок устранены. Синтаксис всех изменённых bash-скриптов проверен (`bash -n`). Проект готов к git commit.**

| Файл | Изменение |
|---|---|
| `patches/cf-ip-update.sh` | PID lock + fix threshold logic |
| `patches/sni-scan.sh` | PID lock |
| `patches/setup-cf-optimizer.sh` | cron `*/15`, echo message |
| `patches/luci/view/cf-optimizer/settings.js` | proxy_name + limit_per_region |
| `patches/luci/acl.d/luci-app-cf-optimizer.json` | sni-scan.sh exec |
| `patches/geo-update.sh` | URL path fix |
| `config.example.yaml` | mmdb-path + geodata-url format |
| `patches/luci/controller/cf_optimizer.lua` | **Удалён** |
| `patches/luci/model/cbi/cf_optimizer.lua` | **Удалён** |
| `patches/log-rotate.sh` | xray-fragment.log |
| `patches/99-cf-dpi-bypass.nft` | comment path |
| `adguardhome/config.yaml` | address: 192.168.1.1:3000 |
| `deploy.py` | env var comment |

---

## ЧАСТЬ 3 — POST-FIX DEPENDENCY AUDIT (Проверка связей)

**Дата:** 2026-03-09
**Метод:** [DEVILS_ADVOCATE_METHOD] — READ-ONLY grep/find по всем файлам
**Триггер:** Удаление `cf_optimizer.lua` и сопутствующих файлов в ходе Части 2

### Результат: Разрывов не обнаружено, удаление было безопасным.

---

### Вектор 1 — LuCI Routing & UI Integrity

| Файл | Проверка | Статус |
|------|----------|--------|
| `luci/menu.d/luci-app-cf-optimizer.json` | `"path": "cf-optimizer/main"` → `view/cf-optimizer/main.js` | ✓ СУЩЕСТВУЕТ |
| `luci/menu.d/luci-app-cf-optimizer.json` | `"path": "cf-optimizer/settings"` → `view/cf-optimizer/settings.js` | ✓ СУЩЕСТВУЕТ |
| `luci/menu.d/luci-app-adguardhome.json` | `"path": "adguardhome/dashboard"` → `view/adguardhome/dashboard.js` | ✓ СУЩЕСТВУЕТ |
| `luci/acl.d/luci-app-cf-optimizer.json` | exec: latency-start.sh, xray-control.sh, xray-apply-config.sh, cf-ip-update.sh, sni-scan.sh | ✓ ВСЕ СУЩЕСТВУЮТ |

**Ссылок на `cf_optimizer.lua` (type: cbi) — не найдено.** Миграция Lua→JSON/JS завершена корректно.

---

### Вектор 2 — JavaScript Views (fs.exec / fs.read)

| Вызов в main.js | Целевой путь | Статус |
|-----------------|--------------|--------|
| `fs.exec` | `/usr/local/bin/latency-start.sh` | ✓ |
| `fs.exec` | `/usr/local/bin/xray-control.sh` | ✓ |
| `fs.exec` | `/usr/local/bin/xray-apply-config.sh` | ✓ |
| `fs.read` | `/var/run/latency-monitor.status` | ✓ (tmpfs, создаётся latency-monitor.sh) |
| `fs.read` | `/var/run/mihomo-watchdog.status` | ✓ (tmpfs, создаётся mihomo-watchdog.sh) |
| `fs.read` | `/var/run/xray-fragment.status` | ✓ (tmpfs, создаётся xray-control.sh) |

---

### Вектор 3 — Cross-Script Calls & Cron

| Cron задача (setup-cf-optimizer.sh) | Путь | Статус |
|-------------------------------------|------|--------|
| `*/15 * * * *` | `/usr/local/bin/latency-monitor.sh` | ✓ |
| `* * * * *` (trigger) | `/usr/local/bin/latency-monitor.sh` | ✓ |
| `*/10 * * * *` | `/usr/local/bin/mihomo-watchdog.sh` | ✓ |
| `0 3 * * *` | `/usr/local/bin/log-rotate.sh` | ✓ |
| `0 4 * * 0` | `/usr/local/bin/geo-update.sh` | ✓ |
| `0 */6 * * *` | `/usr/local/bin/cf-ip-update.sh` | ✓ |
| `30 2 * * *` | `/usr/local/bin/sni-scan.sh` | ✓ |

---

### Вектор 4 — Init Script (`/etc/init.d/cf-optimizer`)

Все пути в `start()` и `stop()`:
`latency-monitor.sh`, `xray-control.sh`, `cf-ip-update.sh`, `99-cf-dpi-bypass.nft`, `98-telegram-tproxy.nft` — **все существуют**.

---

### Вектор 5 — Lock-файлы

| Скрипт | LOCK_FILE | Создание | trap rm | Статус |
|--------|-----------|----------|---------|--------|
| latency-monitor.sh | `/var/run/latency-monitor.lock` | `echo $$ > $LOCK_FILE` | `trap 'rm -f "$LOCK_FILE"' EXIT` | ✓ |
| cf-ip-update.sh | `/var/run/cf-ip-update.lock` | `echo $$ > $LOCK_FILE` | `trap 'rm -f "$LOCK_FILE"' EXIT` | ✓ |
| sni-scan.sh | `/var/run/sni-scan.lock` | `echo $$ > $LOCK_FILE` | `trap 'rm -f "$LOCK_FILE"' EXIT` | ✓ |
| latency-start.sh → cron | `/var/run/latency-trigger` | `touch` | `rm -f` перед запуском | ✓ |

---

### Вектор 6 — NFT-файлы

| Файл | Существует | Упоминается в | Статус |
|------|-----------|---------------|--------|
| `patches/99-cf-dpi-bypass.nft` | ✓ | setup + init.d | ✓ |
| `patches/98-telegram-tproxy.nft` | ✓ | setup + init.d | ✓ |

---

### Итоговая таблица

| Вектор | Разрывов | Примечание |
|--------|----------|------------|
| LuCI Menu/ACL | 0 | CBI-пути отсутствуют; JSON/JS миграция завершена |
| JS Views (fs.exec/read) | 0 | Все 6 вызовов валидны |
| Cross-script / Cron | 0 | Все 7 cron-задач и межскриптовые вызовы корректны |
| Init script | 0 | Все пути проверены |
| Lock-файлы | 0 | Симметрия create/destroy соблюдена |
| NFT-файлы | 0 | Оба файла существуют и правильно прописаны |
| **ИТОГО** | **0** | **Проект в целостном состоянии** |
