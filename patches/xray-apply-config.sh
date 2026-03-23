#!/bin/sh
# xray-apply-config.sh
# Adds or removes "dialer-proxy: xray-fragment" to/from all proxy entries
# in the "proxies:" section of Mihomo config.yaml.
#
# Usage: xray-apply-config.sh {add|remove|status}
#
# HOW IT WORKS:
#   - Only touches the "proxies:" top-level section (not proxy-groups)
#   - Detects each proxy by the "  - name:" pattern (2 spaces + dash)
#   - Inserts "    dialer-proxy: xray-fragment" right after each "  - name:" line
#   - Before any modification a backup is saved: config.yaml.xray-bak
#   - After modification triggers Mihomo hot-reload (PUT /configs?force=false)

MIHOMO_CONFIG=$(uci -q get cf_optimizer.main.mihomo_config)
MIHOMO_API=$(uci -q get cf_optimizer.main.mihomo_api)
MIHOMO_SECRET=$(uci -q get cf_optimizer.main.mihomo_secret)

MIHOMO_CONFIG="${MIHOMO_CONFIG:-/opt/clash/config.yaml}"
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"

reload_mihomo() {
    if [ -n "$MIHOMO_SECRET" ]; then
        curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $MIHOMO_SECRET" \
            -d '{}' --max-time 10 \
            "${MIHOMO_API}/configs?force=false" >/dev/null 2>&1
    else
        curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -d '{}' --max-time 10 \
            "${MIHOMO_API}/configs?force=false" >/dev/null 2>&1
    fi
}

count_proxies() {
    awk '
        /^proxies:/                         { in_p=1; next }
        /^[a-zA-Z]/ && !/^proxies:/        { in_p=0 }
        in_p && /^  - name:/               { c++ }
        END { print c+0 }
    ' "$MIHOMO_CONFIG"
}

count_with_dialer() {
    awk '
        /^proxies:/                                     { in_p=1; next }
        /^[a-zA-Z]/ && !/^proxies:/                    { in_p=0 }
        in_p && /^    dialer-proxy: xray-fragment/      { c++ }
        END { print c+0 }
    ' "$MIHOMO_CONFIG"
}

# ----------------------------------------------------------------

case "$1" in

    status)
        if [ ! -f "$MIHOMO_CONFIG" ]; then
            echo "Config not found: $MIHOMO_CONFIG"
            exit 1
        fi
        total=$(count_proxies)
        with=$(count_with_dialer)
        echo "Config: $MIHOMO_CONFIG"
        echo "Total proxies: $total"
        echo "With dialer-proxy: xray-fragment: $with"
        echo "Without: $((total - with))"
        ;;

    add)
        if [ ! -f "$MIHOMO_CONFIG" ]; then
            echo "ERROR: config not found: $MIHOMO_CONFIG"
            exit 1
        fi
        cp "$MIHOMO_CONFIG" "${MIHOMO_CONFIG}.xray-bak"

        # Pass 1: strip existing dialer-proxy: xray-fragment (prevent duplicates)
        awk '
            /^proxies:/                                     { in_p=1 }
            /^[a-zA-Z]/ && !/^proxies:/                    { in_p=0 }
            in_p && /^    dialer-proxy: xray-fragment/      { next }
            { print }
        ' "$MIHOMO_CONFIG" > "${MIHOMO_CONFIG}.tmp"

        # Pass 2: insert dialer-proxy after each "  - name:" in proxies section,
        # skipping: xray-fragment itself and wireguard/amnezia-wg type proxies
        # (xray-fragment is TCP-only SOCKS5; WireGuard uses UDP → incompatible)
        awk '
            BEGIN { in_p=0; buf=""; is_skip=0 }

            /^proxies:/                         { in_p=1; print; next }
            in_p && /^[a-zA-Z]/ && !/^proxies:/ {
                if (buf != "") { out_block(buf, is_skip); buf=""; is_skip=0 }
                in_p=0; print; next
            }
            in_p && /^  - name:/ {
                if (buf != "") { out_block(buf, is_skip); buf=""; is_skip=0 }
                buf=$0 "\n"
                is_skip=($0 ~ /"xray-fragment"/)
                next
            }
            in_p && buf != "" && /type: wireguard|type: amnezia-wg|<<: \*warp/ {
                is_skip=1; buf=buf $0 "\n"; next
            }
            in_p && buf != "" { buf=buf $0 "\n"; next }
            { print }
            END { if (buf != "") out_block(buf, is_skip) }

            function out_block(b, skip,    lines, n, i) {
                n=split(b, lines, "\n")
                print lines[1]
                if (!skip) print "    dialer-proxy: xray-fragment"
                for (i=2; i<n; i++) print lines[i]
            }
        ' "${MIHOMO_CONFIG}.tmp" > "$MIHOMO_CONFIG"

        rm -f "${MIHOMO_CONFIG}.tmp"

        # Ensure xray-fragment proxy definition exists at top of proxies section
        if ! grep -q '^  - name: "xray-fragment"' "$MIHOMO_CONFIG"; then
            awk '
                /^proxies:/ && !done {
                    print
                    print "  - name: \"xray-fragment\""
                    print "    type: socks5"
                    print "    server: 127.0.0.1"
                    print "    port: 10801"
                    print ""
                    done=1
                    next
                }
                { print }
            ' "$MIHOMO_CONFIG" > "${MIHOMO_CONFIG}.tmp"
            mv "${MIHOMO_CONFIG}.tmp" "$MIHOMO_CONFIG"
        fi

        total=$(count_proxies)
        # Subtract 1 for xray-fragment itself
        actual=$((total - 1))
        echo "OK: dialer-proxy: xray-fragment added to ${actual} proxies"
        echo "Backup saved: ${MIHOMO_CONFIG}.xray-bak"

        if reload_mihomo; then
            echo "Mihomo config reloaded (hot-reload, no reconnects)"
        else
            echo "WARNING: Mihomo reload failed — restart manually: /etc/init.d/clash restart"
        fi
        ;;

    remove)
        if [ ! -f "$MIHOMO_CONFIG" ]; then
            echo "ERROR: config not found: $MIHOMO_CONFIG"
            exit 1
        fi
        cp "$MIHOMO_CONFIG" "${MIHOMO_CONFIG}.xray-bak"

        # Pass 1: remove dialer-proxy: xray-fragment lines from proxies section
        awk '
            /^proxies:/                                     { in_p=1 }
            /^[a-zA-Z]/ && !/^proxies:/                    { in_p=0 }
            in_p && /^    dialer-proxy: xray-fragment/      { next }
            { print }
        ' "$MIHOMO_CONFIG" > "${MIHOMO_CONFIG}.tmp"

        # Pass 2: remove the xray-fragment proxy definition block
        awk '
            /^  - name: "xray-fragment"/ { skip=1; next }
            skip && /^  - name:/         { skip=0 }
            skip && /^[^ \t]/            { skip=0 }
            skip                         { next }
            { print }
        ' "${MIHOMO_CONFIG}.tmp" > "$MIHOMO_CONFIG"

        rm -f "${MIHOMO_CONFIG}.tmp"

        echo "OK: dialer-proxy: xray-fragment removed from all proxies"
        echo "Backup saved: ${MIHOMO_CONFIG}.xray-bak"

        if reload_mihomo; then
            echo "Mihomo config reloaded (hot-reload, no reconnects)"
        else
            echo "WARNING: Mihomo reload failed — restart manually: /etc/init.d/clash restart"
        fi
        ;;

    *)
        echo "Usage: $0 {status|add|remove}"
        exit 1
        ;;
esac
