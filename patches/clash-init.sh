#!/bin/sh /etc/rc.common
# /etc/init.d/clash — Mihomo TPROXY service
#
# FAIL-SAFE design:
#   TPROXY nftables rules are applied ONLY after Mihomo API responds.
#   If Mihomo fails to start (bad config, missing geo files, crash) —
#   TPROXY is NOT applied and internet works directly.
#   This prevents the "no internet after reboot" problem.

START=90
STOP=10
EXTRA_COMMANDS="status"
EXTRA_HELP="	status		Check if Mihomo is running"

PROG=/opt/clash/bin/mihomo
CONF=/opt/clash/config.yaml
WORKDIR=/opt/clash
TPROXY_NFT=/etc/nftables.d/clash-tproxy.nft
PIDFILE=/var/run/clash.pid
LOGFILE=/opt/clash/logs/mihomo.log

_setup_routing() {
    ip rule add fwmark 1 table 100 2>/dev/null || true
    ip route add local default dev lo table 100 2>/dev/null || true
}

_teardown_routing() {
    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route del local default dev lo table 100 2>/dev/null || true
    nft delete table inet clash_tproxy 2>/dev/null || true
}

start() {
    if [ ! -f "$CONF" ]; then
        logger -t clash "ERROR: $CONF not found — skipping start, internet works directly"
        return 1
    fi
    if [ ! -x "$PROG" ]; then
        logger -t clash "ERROR: $PROG not found or not executable — skipping start"
        return 1
    fi

    mkdir -p /opt/clash/logs

    # Run everything in background — boot sequence is NOT blocked
    (
        # Start Mihomo
        "$PROG" -d "$WORKDIR" -f "$CONF" >> "$LOGFILE" 2>&1 &
        MPID=$!
        echo "$MPID" > "$PIDFILE"
        logger -t clash "Mihomo starting (PID $MPID)"

        # Wait for API — max 60s (FAIL-SAFE timeout)
        waited=0
        while ! curl -sf --max-time 3 http://127.0.0.1:9090/version >/dev/null 2>&1; do
            if [ $waited -ge 60 ]; then
                logger -t clash "FAIL: Mihomo API not responding after 60s"
                logger -t clash "TPROXY NOT applied — internet works directly"
                exit 0
            fi
            sleep 2
            waited=$((waited + 2))
        done

        # Mihomo is ready — NOW setup routing + TPROXY
        _setup_routing
        if nft -f "$TPROXY_NFT"; then
            logger -t clash "TPROXY active (PID $MPID, port $(_get_port))"
        else
            logger -t clash "ERROR: TPROXY nft load failed — removing routing"
            _teardown_routing
        fi
    ) &

    logger -t clash "start sequence launched (background)"
}

_get_port() {
    grep -o 'tproxy-port:[[:space:]]*[0-9]*' "$CONF" 2>/dev/null | grep -o '[0-9]*$' || echo 7894
}

stop() {
    _teardown_routing
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        kill "$PID" 2>/dev/null || true
        rm -f "$PIDFILE"
        logger -t clash "stopped (PID $PID), TPROXY removed"
    else
        killall mihomo 2>/dev/null || true
        logger -t clash "stopped (killall), TPROXY removed"
    fi
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "clash running (PID $(cat $PIDFILE))"
        return 0
    else
        echo "clash stopped"
        return 1
    fi
}
