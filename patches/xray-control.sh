#!/bin/sh
# xray-control.sh
# Manages Xray fragment proxy (DPI bypass alternative to nftables MSS).
#
# Generates config from UCI on each start:
#   cf_optimizer.main.xray_fragment_length   (default "10-30" bytes)
#   cf_optimizer.main.xray_fragment_interval (default "10-20" ms)
#
# Usage:
#   xray-control.sh {start|stop|restart|status}
#
# LuCI calls start/stop via fs.exec.
# Init script calls start when xray_fragment_enabled=1.
#
# NOTE: Requires Mihomo config.yaml to have:
#   dialer-proxy: xray-fragment
# on each proxy entry you want to fragment.

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/tmp/xray-fragment.json"
XRAY_PID="/var/run/xray-fragment.pid"
STATUS_FILE="/var/run/xray-fragment.status"
LOG_FILE="/var/log/xray-fragment.log"

# ----------------------------------------------------------------

write_status() {
    local st="$1" pid="${2:-0}" inst="${3:-0}"
    {
        echo "XRAY_STATUS=$st"
        echo "XRAY_PID=$pid"
        echo "XRAY_INSTALLED=$inst"
    } > "$STATUS_FILE"
}

is_installed() { [ -x "$XRAY_BIN" ]; }

is_running() {
    [ -f "$XRAY_PID" ] && \
    kill -0 "$(cat "$XRAY_PID")" 2>/dev/null && \
    grep -q xray /proc/$(cat "$XRAY_PID")/cmdline 2>/dev/null
}

generate_conf() {
    local length interval
    length=$(uci -q get cf_optimizer.main.xray_fragment_length)
    interval=$(uci -q get cf_optimizer.main.xray_fragment_interval)
    length="${length:-10-30}"
    interval="${interval:-10-20}"

    cat > "$XRAY_CONF" << EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": 10801,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "fragment-out",
      "settings": {
        "fragment": {
          "packets": "tlshello",
          "length": "${length}",
          "interval": "${interval}"
        }
      },
      "streamSettings": {
        "sockopt": { "tcpNoDelay": true }
      }
    }
  ]
}
EOF
}

# ----------------------------------------------------------------

case "$1" in

    start)
        if ! is_installed; then
            logger -t xray-fragment "ERROR: Xray binary not found — run xray-install.sh"
            write_status "not_installed" "" "0"
            exit 1
        fi
        if is_running; then
            logger -t xray-fragment "Already running (PID=$(cat "$XRAY_PID"))"
            write_status "running" "$(cat "$XRAY_PID")" "1"
            exit 0
        fi
        generate_conf
        "$XRAY_BIN" -c "$XRAY_CONF" </dev/null >> "$LOG_FILE" 2>&1 &
        xpid=$!
        echo "$xpid" > "$XRAY_PID"
        sleep 1
        if kill -0 "$xpid" 2>/dev/null; then
            logger -t xray-fragment "Started (PID=$xpid)"
            write_status "running" "$xpid" "1"
        else
            logger -t xray-fragment "ERROR: Xray failed to start (check $LOG_FILE)"
            rm -f "$XRAY_PID"
            write_status "failed" "" "1"
            exit 1
        fi
        ;;

    stop)
        if is_running; then
            kill "$(cat "$XRAY_PID")" 2>/dev/null
            sleep 1
        fi
        rm -f "$XRAY_PID"
        write_status "stopped" "" "$(is_installed && echo 1 || echo 0)"
        logger -t xray-fragment "Stopped"
        ;;

    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;

    status)
        if ! is_installed; then
            write_status "not_installed" "" "0"
            echo "not_installed"
        elif is_running; then
            write_status "running" "$(cat "$XRAY_PID")" "1"
            echo "running (PID=$(cat "$XRAY_PID"))"
        else
            write_status "stopped" "" "1"
            echo "stopped"
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
