#!/bin/sh
# latency-start.sh — writes trigger file for cron-based execution.
# Called from LuCI (fs.exec via rpcd) — must exit instantly.
# rpcd is a subreaper: background processes get reparented to it,
# causing XHR timeout. Solution: just touch a trigger file and return.
# Cron (* * * * *) picks it up within 1 min and runs latency-monitor.sh
# outside rpcd's subreaper scope.
touch /var/run/latency-trigger
