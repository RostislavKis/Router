#!/bin/sh
# setup-adguardhome.sh
# Patches AdGuard Home config to work with Mihomo (SSClash) fake-ip DNS chain.
#
# What this does:
#   1. Sets AGH upstream DNS → Mihomo on 127.0.0.1:1053 (fake-ip mode)
#   2. Disables AAAA queries (Mihomo runs with ipv6: false)
#   3. Sets AGH admin login and password
#   4. Removes non-working LuCI tabs (Filters, Query Log, Settings)
#
# Usage:
#   chmod +x setup-adguardhome.sh
#   ./setup-adguardhome.sh
#
# Run on the router via SSH:
#   scp patches/setup-adguardhome.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 "chmod +x /tmp/setup-adguardhome.sh && /tmp/setup-adguardhome.sh"

set -e

AGH_CONFIG="/etc/adguardhome/adguardhome.yaml"

# ============================================================
# CONFIGURE YOUR LOGIN AND PASSWORD BELOW
# Generate bcrypt hash:
#   htpasswd -bnBC 10 "" YOUR_PASSWORD | tr -d ':\n'
# ============================================================
AGH_USER="root"
AGH_PASSWORD_HASH='$2y$10$REPLACE_THIS_WITH_YOUR_BCRYPT_HASH'
# ============================================================

echo "==> Patching AdGuard Home config: $AGH_CONFIG"

if [ ! -f "$AGH_CONFIG" ]; then
    echo "ERROR: $AGH_CONFIG not found. Is AdGuard Home installed?"
    exit 1
fi

# Backup
cp "$AGH_CONFIG" "${AGH_CONFIG}.bak"
echo "    Backup saved: ${AGH_CONFIG}.bak"

# 1. Set upstream DNS to Mihomo port 1053
if grep -q 'upstream_dns:' "$AGH_CONFIG"; then
    # Replace the first upstream entry with Mihomo DNS
    awk '
        /upstream_dns:/ { print; in_upstream=1; next }
        in_upstream && /^    - / {
            if (!replaced) { print "    - 127.0.0.1:1053"; replaced=1 }
            next
        }
        in_upstream && !/^    - / { in_upstream=0; replaced=0 }
        { print }
    ' "$AGH_CONFIG" > "${AGH_CONFIG}.tmp" && mv "${AGH_CONFIG}.tmp" "$AGH_CONFIG"
    echo "    upstream_dns → 127.0.0.1:1053"
else
    echo "WARNING: upstream_dns key not found, skipping"
fi

# 2. Disable AAAA queries (Mihomo ipv6: false)
sed -i 's/aaaa_disabled: false/aaaa_disabled: true/' "$AGH_CONFIG"
echo "    aaaa_disabled → true"

# 3. Set admin user and password
if grep -q 'users:' "$AGH_CONFIG"; then
    # Replace name and password under users section
    awk -v user="$AGH_USER" -v hash="$AGH_PASSWORD_HASH" '
        /^users:/ { print; in_users=1; next }
        in_users && /^  - name:/ { print "  - name: " user; next }
        in_users && /^    password:/ { print "    password: " hash; in_users=0; next }
        { print }
    ' "$AGH_CONFIG" > "${AGH_CONFIG}.tmp" && mv "${AGH_CONFIG}.tmp" "$AGH_CONFIG"
    echo "    admin user → $AGH_USER"
    echo "    password hash → set"
else
    echo "WARNING: users section not found, skipping password setup"
fi

echo ""
echo "==> Restarting AdGuard Home..."
/etc/init.d/adguardhome restart

echo ""
echo "==> Removing extra AdGuard Home tabs from LuCI..."
echo "    (Overview, Filters, Query Log, Settings — оставляем только кнопку открытия)"

MENU_SRC="$(dirname "$0")/luci/menu.d/luci-app-adguardhome.json"
MENU_DST="/usr/share/luci/menu.d/luci-app-adguardhome.json"

if [ -f "$MENU_SRC" ]; then
    cp "$MENU_SRC" "$MENU_DST"
    chmod 644 "$MENU_DST"
    echo "    Заменён menu.d/luci-app-adguardhome.json (только → Open Dashboard)"
else
    cat > "$MENU_DST" << 'MENUJSON'
{
	"admin/services/adguardhome": {
		"title": "AdGuard Home",
		"order": 15,
		"action": {
			"type": "view",
			"path": "adguardhome/dashboard"
		},
		"depends": {
			"acl": [ "luci-app-adguardhome" ]
		}
	}
}
MENUJSON
    chmod 644 "$MENU_DST"
    echo "    Заменён menu.d/luci-app-adguardhome.json (inline fallback)"
fi

rm -rf /tmp/luci-*
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
echo "    LuCI кэш очищен, rpcd/uhttpd перезапущены"

echo ""
echo "==> Done. Verify with:"
echo "    nslookup gemini.google.com 127.0.0.1"
echo "    # Expected: Address: 198.18.x.x (fake-ip → proxied)"
echo ""
echo "    nslookup yandex.ru 127.0.0.1"
echo "    # Expected: real IP (direct)"
echo ""
