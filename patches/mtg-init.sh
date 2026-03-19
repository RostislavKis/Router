#!/bin/sh /etc/rc.common
# /etc/init.d/mtg — MTProxy (mtg v2) autostart
# Deploy: cp patches/mtg-init.sh /etc/init.d/mtg && chmod +x /etc/init.d/mtg
#         /etc/init.d/mtg enable && /etc/init.d/mtg restart
#
# Secret generation:
#   mtg generate-secret --hex google.com    # fake-TLS domain fronting
#
# Chain: Telegram client → mtg:443 (fake-TLS) → Telegram напрямую
# Telegram доступен напрямую (разблокирован), AWG не нужен — лишний hop.
# TCP 149.154.167.91:443 connect=55ms напрямую без потерь.

START=96
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/mtg simple-run \
        -i prefer-ipv4 \
        -n 1.1.1.1 \
        -c 8192 \
        -t 15s \
        0.0.0.0:443 \
        7hk3Z6AyCsbpu4aLoUPQ9J1nb29nbGUuY29t
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile=65535
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
