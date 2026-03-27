# AmneziaWG 2.0 — Свой VPN-сервер на роутере GL-iNet Flint 2

> Это руководство написано для людей без опыта программирования.
> Каждый шаг объясняет **что делать**, **где искать результат** и **что должно получиться**.

---

## Что в итоге получится

Ваш телефон будет подключаться к роутеру через зашифрованный AWG-туннель.
Весь трафик телефона (все приложения, браузер, мессенджеры) пойдёт через
роутер и затем — по правилам: Telegram через один путь, иностранные сервисы
через другой, российские сайты — напрямую.

```
Телефон (приложение Amnezia)
        │
        │  зашифрованный UDP-трафик, выглядит как случайные данные
        ▼
   Ваш роутер
        │
        ├──  Telegram           → через защищённый канал
        ├──  YouTube, Google    → через прокси
        ├──  ВКонтакте, Яндекс → напрямую
        └──  всё остальное      → через прокси
```

---

## Часть 1 — Подготовка на вашем компьютере (Windows)

### Шаг 1.1 — Установить язык программирования Go

Go нужен только один раз, чтобы собрать программу AWG из исходного кода.
Готового скачиваемого файла не существует — нужно собирать самому.

1. Откройте браузер и перейдите на сайт: <https://go.dev/dl/>
2. Скачайте файл с именем вида `go1.XX.X.windows-amd64.msi`
   (последняя версия, `.msi` — установщик для Windows)
3. Запустите скачанный файл и нажимайте «Next» до конца установки
4. После установки **закройте и снова откройте** PowerShell (если был открыт)

**Проверить что Go установился:**

Нажмите `Win + R`, введите `powershell`, нажмите Enter.
В открывшемся синем окне напечатайте:

```
go version
```

Нажмите Enter. Должно появиться что-то вроде:

```
go version go1.23.4 windows/amd64
```

Если появилась ошибка — перезагрузите компьютер и попробуйте снова.

---

### Шаг 1.2 — Установить Git

Git нужен чтобы скачать исходный код AWG.

1. Откройте: <https://git-scm.com/>
2. Нажмите большую кнопку «Download for Windows»
3. Запустите скачанный `.exe` — нажимайте «Next» везде
4. После установки снова закройте и откройте PowerShell

**Проверить:**

```
git --version
```

Ответ должен быть: `git version 2.XX.X`

---

### Шаг 1.3 — Скачать и собрать программу AWG

В PowerShell выполните команды **одну за другой**, нажимая Enter после каждой:

**1. Перейти в удобное место (Рабочий стол):**

```powershell
cd "$env:USERPROFILE\Desktop"
```

**2. Скачать исходный код:**

```powershell
git clone https://github.com/amnezia-vpn/amneziawg-go.git
```

Это создаст папку `amneziawg-go` прямо на Рабочем столе.
Процесс займёт 10–30 секунд, покажет несколько строк текста.

**3. Зайти в эту папку:**

```powershell
cd amneziawg-go
```

**4. Собрать программу для роутера (Linux, ARM64):**

```powershell
$env:CGO_ENABLED = "0"
$env:GOOS        = "linux"
$env:GOARCH      = "arm64"
go build -ldflags="-s -w" -o amneziawg-go .
```

Последняя команда занимает 1–3 минуты, прогресса не показывает — просто ждите.
Когда строка с `>` появится снова — готово.

**Где найти результат:**

Откройте Проводник → Рабочий стол → папка `amneziawg-go`.
Там появился файл `amneziawg-go` (без расширения, ~7 МБ).
Это и есть программа, которую нужно загрузить на роутер.

---

### Шаг 1.4 — Загрузить программу на роутер

Скопируйте и вставьте в PowerShell **весь блок целиком**:

```powershell
py -3 -c "
import paramiko, sys

HOST = '<ROUTER_IP>'   # адрес роутера
USER = 'root'
PASS = '<SSH_PASS>'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PASS)

sftp = c.open_sftp()
sftp.put('amneziawg-go', '/usr/local/bin/amneziawg-go')
sftp.close()

c.exec_command('chmod +x /usr/local/bin/amneziawg-go')
c.close()
print('Готово — файл загружен на роутер')
"
```

> Перед запуском замените `<ROUTER_IP>` и `<SSH_PASS>` на реальные значения.

Убедитесь, что вы сейчас находитесь в папке `amneziawg-go` на Рабочем столе
(туда мы перешли на шаге 1.3). Именно там лежит файл `amneziawg-go`,
который мы загружаем.

---

## Часть 2 — Настройка роутера

### Как подключиться к роутеру через терминал

Все следующие команды нужно вводить на **роутере**, а не на компьютере.
Подключение происходит через SSH — это защищённый текстовый терминал.

В PowerShell на вашем компьютере:

```powershell
ssh root@<ROUTER_IP>
```

Введите пароль когда попросит. Курсор при вводе пароля не двигается — это нормально.

Вы увидите приглашение роутера:

```
root@GL-MT6000:~#
```

Теперь все команды выполняются **на роутере**.

---

### Шаг 2.1 — Установить необходимые пакеты

Введите на роутере (каждую команду — Enter):

```sh
apk update
apk add wireguard-tools socat
modprobe tun
echo "tun" >> /etc/modules
```

Что делают эти команды:

- `apk update` — обновляет список пакетов
- `wireguard-tools` — нужен для генерации ключей
- `socat` — нужен для настройки AWG через специальный канал
- `modprobe tun` — включает виртуальный сетевой адаптер в ядре

---

### Шаг 2.2 — Создать папку для ключей и сгенерировать ключи

```sh
mkdir -p /etc/awg-server
wg genkey | tee /etc/awg-server/server.key | wg pubkey > /etc/awg-server/server.pub
wg genkey | tee /etc/awg-server/client1.key | wg pubkey > /etc/awg-server/client1.pub
chmod 600 /etc/awg-server/*.key
```

Это создаёт 4 файла в папке `/etc/awg-server/`:

| Файл | Что это |
| ---- | ------- |
| `server.key` | Секретный ключ сервера (никому не показывать) |
| `server.pub` | Публичный ключ сервера (дать клиенту) |
| `client1.key` | Секретный ключ телефона (вставить в Amnezia) |
| `client1.pub` | Публичный ключ телефона (нужен серверу) |

**Посмотреть содержимое ключей** (понадобится позже):

```sh
echo "=== Публичный ключ СЕРВЕРА (для Amnezia) ===" && cat /etc/awg-server/server.pub
echo "=== Приватный ключ КЛИЕНТА (для Amnezia) ===" && cat /etc/awg-server/client1.key
```

Скопируйте и сохраните оба значения — они нужны при настройке телефона.

---

### Шаг 2.3 — Создать скрипт запуска AWG-сервера

Скрипт — это текстовый файл с командами. На роутере нет графического
редактора, поэтому используем команду `cat` — она записывает текст в файл.

**Скопируйте и вставьте весь блок целиком** (от первой до последней строки):

```sh
cat > /usr/local/bin/awg-server-start.sh << 'SCRIPT_END'
#!/bin/sh
set -e

IFACE=awg0
PORT=51820
WG_SOCK=/var/run/wireguard/${IFACE}.sock
PID_FILE=/var/run/awg-server.pid
LOG=/var/log/awg-server.log

b64_to_hex() { base64 -d | hexdump -v -e '/1 "%02x"' ; }

SERVER_KEY_HEX=$(cat /etc/awg-server/server.key | b64_to_hex)
CLIENT_PUB_HEX=$(cat /etc/awg-server/client1.pub | b64_to_hex)

echo "Запускаем AWG демон..."
/usr/local/bin/amneziawg-go $IFACE >> $LOG 2>&1 &
echo $! > $PID_FILE
sleep 2

echo "Настраиваем интерфейс через IPC..."
{
printf 'set=1\n'
printf 'private_key=%s\n'  "$SERVER_KEY_HEX"
printf 'listen_port=%d\n'  "$PORT"
printf 'junkpacketcount=4\n'
printf 'junkpacketminsize=40\n'
printf 'junkpacketmaxsize=70\n'
printf 'initpacketjunksize=50\n'
printf 'responsepacketjunksize=100\n'
printf 'initpacketmagicheader=1234567890\n'
printf 'responsepacketmagicheader=2345678901\n'
printf 'underloadpacketmagicheader=3456789012\n'
printf 'transportpacketmagicheader=4567890123\n'
printf 'public_key=%s\n'     "$CLIENT_PUB_HEX"
printf 'allowed_ip=10.8.0.2/32\n'
printf '\n'
} | socat - UNIX-CONNECT:$WG_SOCK

ip address add 10.8.0.1/24 dev $IFACE 2>/dev/null || true
ip link set $IFACE up

logger -t awg-server "started PID=$(cat $PID_FILE) port=$PORT"
echo "AWG-сервер запущен на порту $PORT"
SCRIPT_END

chmod +x /usr/local/bin/awg-server-start.sh
echo "Скрипт создан: /usr/local/bin/awg-server-start.sh"
```

**Где находится скрипт:** `/usr/local/bin/awg-server-start.sh`

**Как запустить:** `awg-server-start.sh` (можно с любого места в терминале,
потому что `/usr/local/bin/` — это системный каталог исполняемых файлов)

---

### Шаг 2.4 — Создать правила маршрутизации (nftables)

Этот файл указывает роутеру, что делать с трафиком подключённого телефона —
отправлять его через Mihomo, чтобы работали все правила (Telegram, прокси и т.д.).

```sh
cat > /etc/cf-optimizer/97-awg-server.nft << 'NFT_END'
table inet awg_server {

    chain prerouting {
        type filter hook prerouting priority mangle - 5; policy accept;

        # Не трогать трафик из интернета и уже помеченный
        iifname "pppoe-wan" return
        meta mark 0x00000001 return
        meta mark 0x00000002 return

        # Весь трафик с телефона (интерфейс awg0) → в Mihomo
        iifname "awg0" meta l4proto { tcp, udp } meta mark set 0x00000001
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # NAT для прямых подключений (российские сайты)
        iifname "awg0" oifname "pppoe-wan" masquerade
    }
}
NFT_END

echo "Файл создан: /etc/cf-optimizer/97-awg-server.nft"
```

**Применить правила прямо сейчас:**

```sh
nft -f /etc/cf-optimizer/97-awg-server.nft
echo "Правила nftables применены"
```

---

### Шаг 2.5 — Открыть порт 51820 в файерволе

```sh
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-AWG-Server'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='51820'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
echo "Порт 51820 UDP открыт"
```

---

### Шаг 2.6 — Разрешить передачу трафика от телефона

```sh
nft add rule inet fw4 forward iifname "awg0" accept
nft add rule inet fw4 forward oifname "awg0" accept
echo "Форвардинг для awg0 добавлен"
```

---

### Шаг 2.7 — Настроить автозапуск при перезагрузке роутера

Откройте файл автозапуска для редактирования:

```sh
nano /etc/rc.local
```

Откроется текстовый редактор `nano`. В нём уже есть строка `exit 0`.
Используйте стрелки чтобы встать **перед** этой строкой.
Добавьте две строки:

```sh
nft -f /etc/cf-optimizer/97-awg-server.nft
sleep 8 && /usr/local/bin/awg-server-start.sh &
```

Чтобы сохранить и выйти из nano:

1. Нажмите `Ctrl + O` (сохранить) → Enter
2. Нажмите `Ctrl + X` (выйти)

Файл `rc.local` должен выглядеть так:

```sh
#!/bin/sh
/usr/local/bin/xray-vless-ctl.sh start
nft -f /etc/cf-optimizer/97-awg-server.nft
sleep 8 && /usr/local/bin/awg-server-start.sh &
exit 0
```

---

### Шаг 2.8 — Первый запуск и проверка

```sh
awg-server-start.sh
```

Должно появиться:

```text
Запускаем AWG демон...
Настраиваем интерфейс через IPC...
AWG-сервер запущен на порту 51820
```

**Проверить что интерфейс создался:**

```sh
ip addr show awg0
```

Должна быть строка: `inet 10.8.0.1/24`

**Проверить что порт прослушивается:**

```sh
netstat -unp | grep 51820
```

---

## Часть 3 — Настройка телефона (Amnezia App)

### Установить приложение

- Android: Google Play → «Amnezia VPN»
- iOS: App Store → «Amnezia VPN»

### Добавить конфигурацию

1. Откройте Amnezia
2. Нажмите «+» → «Добавить сервер вручную» → «Файл конфигурации» (или «Текст»)
3. Вставьте конфигурацию ниже, заменив ключи на свои

```ini
[Interface]
PrivateKey = СЮДА_ВСТАВИТЬ_client1.key
Address    = 10.8.0.2/24
DNS        = 10.8.0.1

Jc    = 4
Jmin  = 40
Jmax  = 70
S1    = 50
S2    = 100
H1    = 1234567890
H2    = 2345678901
H3    = 3456789012
H4    = 4567890123

[Peer]
PublicKey           = СЮДА_ВСТАВИТЬ_server.pub
Endpoint            = <WAN_IP>:51820
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
```

**Где взять ключи** (выполнить на роутере):

```sh
echo "PrivateKey = $(cat /etc/awg-server/client1.key)"
echo "PublicKey  = $(cat /etc/awg-server/server.pub)"
```

### Исключить домашнюю Wi-Fi сеть

Чтобы дома телефон не пытался подключиться к самому себе через роутер:

В приложении Amnezia → настройки подключения → «Доверенные сети»
→ добавьте название вашей домашней Wi-Fi сети.

При подключении к этой сети VPN будет автоматически отключаться.

---

## Карта файлов

| Файл | Описание |
| ---- | -------- |
| `/usr/local/bin/amneziawg-go` | Программа AWG-сервера |
| `/usr/local/bin/awg-server-start.sh` | Скрипт запуска |
| `/etc/awg-server/server.key` | Приватный ключ сервера |
| `/etc/awg-server/server.pub` | Публичный ключ сервера |
| `/etc/awg-server/client1.key` | Приватный ключ телефона |
| `/etc/awg-server/client1.pub` | Публичный ключ телефона |
| `/etc/cf-optimizer/97-awg-server.nft` | Правила маршрутизации |
| `/etc/rc.local` | Автозапуск при загрузке |
| `/var/log/awg-server.log` | Лог работы сервера |
| `/var/run/awg-server.pid` | PID процесса (временный файл) |

---

## Диагностика проблем

**Сервер не стартует:**

```sh
cat /var/log/awg-server.log
```

**Нет интерфейса awg0:**

```sh
lsmod | grep tun
# Если пусто:
modprobe tun
```

**Телефон подключается, но интернета нет:**

```sh
# Проверить правила nftables
nft list table inet awg_server

# Проверить форвардинг
nft list chain inet fw4 forward | grep awg
```

**Посмотреть подключённые клиенты:**

```sh
printf 'get=1\n\n' | socat - UNIX-CONNECT:/var/run/wireguard/awg0.sock \
  | grep -E 'peer|last_handshake|rx_bytes'
```
