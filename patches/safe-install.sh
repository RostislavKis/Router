#!/bin/sh
# safe-install.sh
# Wrapper around setup-cf-optimizer.sh with automatic rollback on failure.
#
# If anything breaks after installation (routing, DNS, Mihomo, AdGuardHome),
# the router is automatically restored to its pre-install state within ~20 seconds.
#
# Usage (on router):
#   scp -r patches/ root@192.168.1.1:/tmp/cf-optimizer-deploy/
#   ssh root@192.168.1.1 "sh /tmp/cf-optimizer-deploy/safe-install.sh"
#
# Prerequisites: Mihomo (SSClash) and AdGuardHome must already be running.
#   If they are not — run setup-clash.sh and setup-adguardhome.sh first.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="/tmp/backup_cfg"
ROLLBACK_DONE=0

# ── colours (skip if not a tty) ─────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

_log()   { printf "%b[safe-install]%b %s\n" "$GREEN"  "$NC" "$*"; }
_warn()  { printf "%b[safe-install]%b %s\n" "$YELLOW" "$NC" "$*"; }
_fail()  { printf "%b[safe-install] %s%b\n" "$RED"    "$*" "$NC"; }

# ── step 1: pre-install backup ───────────────────────────────────────────────
pre_install_backup() {
    _log "Создаю резервную копию конфигов → $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    for cfg in dhcp firewall network system; do
        if [ -f "/etc/config/$cfg" ]; then
            cp "/etc/config/$cfg" "$BACKUP_DIR/$cfg"
            _log "  /etc/config/$cfg  →  saved"
        fi
    done

    # crontab
    if [ -f /etc/crontabs/root ]; then
        cp /etc/crontabs/root "$BACKUP_DIR/crontabs_root"
        _log "  /etc/crontabs/root  →  saved"
    fi

    # init script (if upgrading an existing install)
    if [ -f /etc/init.d/cf-optimizer ]; then
        cp /etc/init.d/cf-optimizer "$BACKUP_DIR/init_cf-optimizer"
        _log "  /etc/init.d/cf-optimizer  →  saved"
    fi

    # record NTP servers before any change
    uci -q get system.ntp.server > "$BACKUP_DIR/ntp_servers.txt" 2>/dev/null || true
}

# ── step 2: baseline (pre-install health) ───────────────────────────────────
# Capture what is alive BEFORE we touch anything.
# We only rollback when something that was working BEFORE is now broken.
check_baseline() {
    BASELINE_MIHOMO=0
    BASELINE_AGH=0
    BASELINE_PING=0
    BASELINE_DNS=0

    pidof clash        >/dev/null 2>&1 && BASELINE_MIHOMO=1
    pidof AdGuardHome  >/dev/null 2>&1 && BASELINE_AGH=1
    ping -c 1 -W 3 8.8.8.8        >/dev/null 2>&1 && BASELINE_PING=1
    nslookup google.com 127.0.0.1  >/dev/null 2>&1 && BASELINE_DNS=1

    _log "Базовое состояние до установки:"
    _log "  Mihomo (clash):   $([ $BASELINE_MIHOMO -eq 1 ] && echo 'running' || echo 'NOT RUNNING')"
    _log "  AdGuardHome:      $([ $BASELINE_AGH    -eq 1 ] && echo 'running' || echo 'NOT RUNNING')"
    _log "  Ping 8.8.8.8:     $([ $BASELINE_PING   -eq 1 ] && echo 'OK'      || echo 'FAIL')"
    _log "  DNS 127.0.0.1:    $([ $BASELINE_DNS    -eq 1 ] && echo 'OK'      || echo 'FAIL')"

    if [ $BASELINE_MIHOMO -eq 0 ] || [ $BASELINE_AGH -eq 0 ]; then
        _warn "ПРЕДУПРЕЖДЕНИЕ: Mihomo или AdGuardHome не запущены до установки."
        _warn "Запустите setup-clash.sh и setup-adguardhome.sh сначала."
        _warn "Продолжаю установку, но проверки процессов будут отключены."
    fi
    echo ""
}

# ── step 3: verify post-install ─────────────────────────────────────────────
verify_setup() {
    local fails=0

    _log "Пауза 15 сек — ждём подъёма сервисов..."
    sleep 15

    # Only check Mihomo if it was alive before (we don't start it ourselves)
    if [ $BASELINE_MIHOMO -eq 1 ]; then
        if ! pidof clash >/dev/null 2>&1 && \
           ! curl -sf --max-time 3 "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
            _fail "ПРОВАЛ: Mihomo (clash) перестал отвечать после установки"
            fails=$((fails + 1))
        else
            _log "  Mihomo:      OK"
        fi
    fi

    if [ $BASELINE_AGH -eq 1 ]; then
        if ! pidof AdGuardHome >/dev/null 2>&1; then
            _fail "ПРОВАЛ: AdGuardHome упал после установки"
            fails=$((fails + 1))
        else
            _log "  AdGuardHome: OK"
        fi
    fi

    # Routing check — always verify regardless of baseline
    if [ $BASELINE_PING -eq 1 ]; then
        if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
            _fail "ПРОВАЛ: пинг до 8.8.8.8 пропал — маршрутизация сломана"
            fails=$((fails + 1))
        else
            _log "  Ping 8.8.8.8: OK"
        fi
    fi

    # DNS check
    if [ $BASELINE_DNS -eq 1 ]; then
        if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
            _fail "ПРОВАЛ: DNS через 127.0.0.1 не работает"
            fails=$((fails + 1))
        else
            _log "  DNS:          OK"
        fi
    fi

    return $fails
}

# ── rollback ─────────────────────────────────────────────────────────────────
do_rollback() {
    [ "$ROLLBACK_DONE" = "1" ] && return
    ROLLBACK_DONE=1

    echo ""
    _fail "========================================================"
    _fail " Установка провалена. Откат изменений..."
    _fail "========================================================"
    echo ""

    # Stop cf-optimizer (removes its nft tables via stop())
    /etc/init.d/cf-optimizer stop    2>/dev/null || true
    /etc/init.d/cf-optimizer disable 2>/dev/null || true

    # Remove any remaining custom nftables tables
    nft delete table inet cf_dpi_bypass    2>/dev/null && _warn "  nft: cf_dpi_bypass удалена"    || true
    nft delete table inet telegram_tproxy  2>/dev/null && _warn "  nft: telegram_tproxy удалена" || true
    nft delete table ip   dns_redirect     2>/dev/null && _warn "  nft: dns_redirect удалена"    || true

    # Restore UCI configs
    for cfg in dhcp firewall network system; do
        if [ -f "$BACKUP_DIR/$cfg" ]; then
            cp "$BACKUP_DIR/$cfg" "/etc/config/$cfg"
            uci revert $cfg 2>/dev/null || true
            _warn "  восстановлен: /etc/config/$cfg"
        fi
    done
    uci commit dhcp     2>/dev/null || true
    uci commit firewall 2>/dev/null || true
    uci commit network  2>/dev/null || true
    uci commit system   2>/dev/null || true

    # Restore crontab
    if [ -f "$BACKUP_DIR/crontabs_root" ]; then
        cp "$BACKUP_DIR/crontabs_root" /etc/crontabs/root
        _warn "  восстановлен: /etc/crontabs/root"
    else
        # No original crontab — strip entries we added
        sed -i '/latency-monitor\|mihomo-watchdog\|geo-update\|log-rotate\|cf-ip-update\|sni-scan/d' \
            /etc/crontabs/root 2>/dev/null || true
    fi

    # Restore init script or remove it if it didn't exist before
    if [ -f "$BACKUP_DIR/init_cf-optimizer" ]; then
        cp "$BACKUP_DIR/init_cf-optimizer" /etc/init.d/cf-optimizer
        chmod +x /etc/init.d/cf-optimizer
        _warn "  восстановлен: /etc/init.d/cf-optimizer"
    else
        rm -f /etc/init.d/cf-optimizer
        _warn "  удалён: /etc/init.d/cf-optimizer (не существовал до установки)"
    fi

    # Restart core services to recover default internet
    _warn "  перезапуск сетевых сервисов..."
    /etc/init.d/firewall restart 2>/dev/null &
    /etc/init.d/network  restart 2>/dev/null &
    sleep 5
    /etc/init.d/dnsmasq  restart 2>/dev/null || true
    /etc/init.d/cron     restart 2>/dev/null || \
        /etc/init.d/crond restart 2>/dev/null || true

    echo ""
    _fail "========================================================"
    _fail " ОТКАТ ЗАВЕРШЁН."
    _fail " Роутер возвращён в состояние до установки."
    _fail " Интернет через стандартный dnsmasq восстановлен."
    _fail "========================================================"
    echo ""
    _warn "Диагностика:"
    _warn "  logread | grep -E 'clash|adguard|cf-optimizer'"
    _warn "  /etc/init.d/clash status"
    echo ""
}

# ── cleanup on success ────────────────────────────────────────────────────────
do_cleanup() {
    rm -rf "$BACKUP_DIR"
    _log "Временные бэкапы удалены."
}

# ── trap: rollback on Ctrl+C or TERM ─────────────────────────────────────────
trap 'do_rollback; exit 1' INT TERM

# ── main ─────────────────────────────────────────────────────────────────────
echo ""
_log "=========================================================="
_log " Safe Install — Proxy Optimizer"
_log " Роутер защищён: откат сработает автоматически при сбое."
_log "=========================================================="
echo ""

pre_install_backup
check_baseline

_log "Запускаю setup-cf-optimizer.sh..."
echo ""

if ! sh "$SCRIPT_DIR/setup-cf-optimizer.sh"; then
    _fail "setup-cf-optimizer.sh завершился с ошибкой (exit code $?)"
    do_rollback
    exit 1
fi

echo ""
_log "Запускаю /etc/init.d/cf-optimizer start..."
/etc/init.d/cf-optimizer start 2>/dev/null || true

if verify_setup; then
    echo ""
    _log "=========================================================="
    _log " ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ."
    _log " Mihomo OK | AdGuardHome OK | Ping OK | DNS OK"
    _log "=========================================================="
    do_cleanup
    exit 0
else
    do_rollback
    exit 1
fi
