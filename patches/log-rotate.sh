#!/bin/sh
# log-rotate.sh
# Trims CF Optimizer log files on OpenWrt.
#
# /var/log is tmpfs (RAM) — no standard logrotate available.
# This script keeps only the last MAX_LINES lines of each log.
#
# Run daily from cron:
#   0 3 * * * /usr/local/bin/log-rotate.sh

MAX_LINES=500

rotate_log() {
    local f="$1"
    [ -f "$f" ] || return
    local lines
    lines=$(wc -l < "$f" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LINES" ]; then
        tail -n "$MAX_LINES" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        logger -t "log-rotate" "Trimmed ${f}: ${lines} -> ${MAX_LINES} lines"
    fi
}

rotate_log /var/log/latency-monitor.log
rotate_log /var/log/cf-ip-update.log
rotate_log /var/log/sni-scan.log
rotate_log /var/log/mihomo-watchdog.log
