-- CF IP Optimizer LuCI Controller
-- Размещается: /usr/lib/lua/luci/controller/cf_optimizer.lua
-- Добавляет пункт "CF IP Optimizer" в меню Services LuCI

module("luci.controller.cf_optimizer", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/cf_optimizer") then return end

    entry(
        {"admin", "services", "cf_optimizer"},
        cbi("cf_optimizer"),
        _("CF IP Optimizer"),
        35
    ).dependent = false

    -- Действие: запустить обновление IP вручную
    entry(
        {"admin", "services", "cf_optimizer", "run_ip_update"},
        call("action_run_ip_update"),
        nil
    ).leaf = true

    -- Действие: запустить SNI-сканирование вручную
    entry(
        {"admin", "services", "cf_optimizer", "run_sni_scan"},
        call("action_run_sni_scan"),
        nil
    ).leaf = true

    -- Действие: запустить latency monitor вручную
    entry(
        {"admin", "services", "cf_optimizer", "run_latency"},
        call("action_run_latency"),
        nil
    ).leaf = true

    -- Действие: переключить DPI bypass
    entry(
        {"admin", "services", "cf_optimizer", "toggle_dpi"},
        call("action_toggle_dpi"),
        nil
    ).leaf = true
end

-- Запустить обновление IP (фоновый процесс)
function action_run_ip_update()
    luci.sys.exec("/usr/local/bin/cf-ip-update.sh >> /var/log/cf-ip-update.log 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/cf_optimizer"))
end

-- Запустить SNI-сканирование (фоновый процесс)
function action_run_sni_scan()
    luci.sys.exec("/usr/local/bin/sni-scan.sh >> /var/log/sni-scan.log 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/cf_optimizer"))
end

-- Запустить latency monitor (фоновый процесс)
function action_run_latency()
    luci.sys.exec("/usr/local/bin/latency-monitor.sh >> /var/log/latency-monitor.log 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/cf_optimizer"))
end

-- Включить/выключить DPI bypass
function action_toggle_dpi()
    local enabled = luci.sys.exec("uci -q get cf_optimizer.main.dpi_bypass_enabled"):gsub("%s+", "")
    if enabled == "1" then
        luci.sys.exec("uci set cf_optimizer.main.dpi_bypass_enabled=0 && uci commit cf_optimizer")
        luci.sys.exec("nft delete table inet cf_dpi_bypass 2>/dev/null || true")
    else
        luci.sys.exec("uci set cf_optimizer.main.dpi_bypass_enabled=1 && uci commit cf_optimizer")
        luci.sys.exec("nft -f /etc/nftables.d/99-cf-dpi-bypass.nft 2>/dev/null || true")
    end
    luci.http.redirect(luci.dispatcher.build_url("admin/services/cf_optimizer"))
end
