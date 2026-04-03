#!/bin/sh
# mem-cleanup.sh — nightly RAM cleanup for OpenWrt routers
#
# Actions:
#   1. Truncate AGH querylog (grows indefinitely in tmpfs)
#   2. Truncate large log files in /var/log/ (>1MB)
#   3. Drop kernel page/dentry/inode caches
#   4. Log freed memory
#
# Cron (daily at 04:00):
#   0 4 * * * /usr/local/bin/mem-cleanup.sh >> /var/log/mem-cleanup.log 2>&1
#
# Standalone:
#   /usr/local/bin/mem-cleanup.sh

TAG="mem-cleanup"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
MEM_BEFORE=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)

# ── 1. AGH querylog (can grow to 50-100MB in tmpfs) ────────────────────────
QUERYLOG="/var/lib/adguardhome/data/querylog.json"
if [ -f "$QUERYLOG" ]; then
    size=$(wc -c < "$QUERYLOG" 2>/dev/null || echo 0)
    if [ "$size" -gt 1048576 ]; then
        rm -f "$QUERYLOG"
        logger -t $TAG "querylog removed ($(( size / 1024 / 1024 ))MB)"
    fi
fi

# ── 2. Truncate large logs in /var/log/ (>1MB) ────────────────────────────
for logfile in /var/log/*.log; do
    [ -f "$logfile" ] || continue
    size=$(wc -c < "$logfile" 2>/dev/null || echo 0)
    if [ "$size" -gt 1048576 ]; then
        tail -200 "$logfile" > "${logfile}.tmp" 2>/dev/null
        mv "${logfile}.tmp" "$logfile"
        logger -t $TAG "$(basename "$logfile") trimmed (was $(( size / 1024 ))KB)"
    fi
done

# ── 3. Drop kernel caches ─────────────────────────────────────────────────
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# ── 4. Report ─────────────────────────────────────────────────────────────
MEM_AFTER=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
FREED=$(( MEM_AFTER - MEM_BEFORE ))

logger -t $TAG "done: ${MEM_BEFORE}MB -> ${MEM_AFTER}MB (freed ${FREED}MB)"
echo "[$NOW] ${MEM_BEFORE}MB -> ${MEM_AFTER}MB (freed ${FREED}MB)"
