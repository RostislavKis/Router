#!/bin/sh
# latency-start.sh — запускает latency-monitor.sh в фоне.
# Вызывается из LuCI (fs.exec) — должен завершиться немедленно.
/usr/local/bin/latency-monitor.sh </dev/null >> /var/log/latency-monitor.log 2>&1 &
