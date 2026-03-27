#!/bin/sh
# clash-watchdog.sh — Clash config backup and auto-recovery watchdog
#
# Dual role:
#   1. Backup mode  (Clash running):  overwrite single backup file and exit immediately.
#   2. Recovery mode (Clash down):    wait up to 3 min, restart, rollback to backup if needed.
#
# Backup file: /opt/clash/config.yaml.backup  (single file, always overwritten — no accumulation)
# Failed file: /opt/clash/config.yaml.failed  (last failed config, for debugging)
#
# Cron (every 30 min):
#   */30 * * * * /usr/local/bin/clash-watchdog.sh >> /var/log/clash-watchdog.log 2>&1
#
# On boot (180s delay — wait for Clash initial startup):
#   @reboot sleep 180 && /usr/local/bin/clash-watchdog.sh >> /var/log/clash-watchdog.log 2>&1
#
# Standalone usage:
#   /usr/local/bin/clash-watchdog.sh
#   tail -f /var/log/clash-watchdog.log

BACKUP=/opt/clash/config.yaml.backup
CONFIG=/opt/clash/config.yaml
FAILED=/opt/clash/config.yaml.failed
TAG="clash-watchdog"

# Check if Clash TPROXY port is open
is_listening() {
    netstat -tlnp 2>/dev/null | grep -q ":7894 "
}

# Wait for Clash to come up on :7894 (timeout in seconds)
wait_for_clash() {
    local timeout=${1:-120}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if is_listening; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

# Overwrite single backup file (no timestamped copies — one backup only)
save_backup() {
    cp "$CONFIG" "$BACKUP"
    logger -t $TAG "backup saved ($(wc -c < "$CONFIG") bytes)"
}

# Restore backup: move current config to .failed, restore backup
restore_backup() {
    if [ ! -f "$BACKUP" ]; then
        logger -t $TAG "ERROR: no backup found, cannot rollback"
        return 1
    fi
    cp "$CONFIG" "$FAILED"
    cp "$BACKUP" "$CONFIG"
    logger -t $TAG "rolled back to backup config"
}

# ── Main logic ──────────────────────────────────────────────────────────────

# Clash is running — just refresh the backup and exit
if is_listening; then
    save_backup
    exit 0
fi

# Clash is not on :7894 — wait up to 3 min (handles slow initial startup)
logger -t $TAG "port 7894 not ready, waiting up to 180s..."
if wait_for_clash 180; then
    logger -t $TAG "Clash came up OK"
    save_backup
    exit 0
fi

# Still down after wait — try a restart
logger -t $TAG "timeout, trying restart..."
/etc/init.d/clash restart

if wait_for_clash 120; then
    logger -t $TAG "Clash started after restart"
    save_backup
    exit 0
fi

# Restart failed — roll back to last known-good config
logger -t $TAG "restart failed, rolling back to backup config..."
restore_backup || exit 1

/etc/init.d/clash restart

if wait_for_clash 120; then
    logger -t $TAG "ROLLBACK SUCCESS — backup config running"
    # Do NOT save backup here: the current config is already the backup
else
    logger -t $TAG "CRITICAL: even backup config failed to start"
fi
