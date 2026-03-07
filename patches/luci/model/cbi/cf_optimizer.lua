-- CF IP Optimizer LuCI CBI Model
-- Размещается: /usr/lib/lua/luci/model/cbi/cf_optimizer.lua

local sys = require "luci.sys"
local fs  = require "nixio.fs"

-- Читаем файл статуса
local function read_status(path)
    local f = fs.open(path or "/var/run/cf-optimizer.status", "r")
    if not f then return nil end
    local data = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.+)$")
        if k then data[k] = v end
    end
    f:close()
    return data
end

-- Читаем последние строки лога
local function read_log(path, lines)
    lines = lines or 8
    local out = sys.exec(string.format("tail -n %d %s 2>/dev/null", lines, path))
    return out ~= "" and out or "(лог пуст)"
end

-- Проверяем, активны ли nftables-правила DPI
local function dpi_active()
    local r = sys.exec("nft list table inet cf_dpi_bypass 2>/dev/null | wc -l")
    return tonumber(r) and tonumber(r) > 0
end

local status   = read_status("/var/run/cf-optimizer.status")
local lat_stat = read_status("/var/run/latency-monitor.status")

-- ============================================================
-- Основная карта
-- ============================================================
local m = Map("cf_optimizer",
    translate("CF IP Optimizer"),
    translate("Автоматический выбор оптимальных Cloudflare edge IP для Mihomo. " ..
              "Все изменения применяются через graceful hot-reload — соединения не разрываются."))

-- ============================================================
-- Секция: Текущий статус
-- ============================================================
local s_status = m:section(NamedSection, "main", "cf_optimizer", translate("Статус"))
s_status.addremove = false
s_status.anonymous = true

local function status_val(key, default)
    return (status and status[key]) and status[key] or (default or "—")
end

local dv_ip = s_status:option(DummyValue, "_ip", translate("Текущий IP"))
dv_ip.rawhtml = true
dv_ip.cfgvalue = function()
    local ip   = status_val("CURRENT_IP")
    local port = status_val("CURRENT_PORT")
    local ping = status_val("CURRENT_PING")
    if ip == "—" then
        return "<em style='color:#aaa'>Обновление ещё не запускалось</em>"
    end
    return string.format("<strong>%s:%s</strong> &nbsp; <span style='color:#4caf50'>%s мс</span>", ip, port, ping)
end

local dv_sni = s_status:option(DummyValue, "_sni", translate("Текущий SNI"))
dv_sni.cfgvalue = function() return status_val("CURRENT_SNI") end

local dv_upd = s_status:option(DummyValue, "_updated", translate("Последнее обновление"))
dv_upd.cfgvalue = function() return status_val("LAST_UPDATE") end

local dv_dpi = s_status:option(DummyValue, "_dpi", translate("DPI Bypass (nftables)"))
dv_dpi.rawhtml = true
dv_dpi.cfgvalue = function()
    if dpi_active() then
        return "<span style='color:#4caf50'>&#9679; Активно (MSS=" ..
               (m.uci:get("cf_optimizer", "main", "mss_value") or "150") .. ")</span>"
    else
        return "<span style='color:#f44336'>&#9679; Не активно</span>"
    end
end

-- Кнопки ручного запуска
local dv_btns = s_status:option(DummyValue, "_btns", translate("Действия"))
dv_btns.rawhtml = true
dv_btns.cfgvalue = function()
    local base = luci.dispatcher.build_url("admin/services/cf_optimizer")
    return string.format(
        '<a class="btn cbi-button cbi-button-apply" href="%s/run_ip_update">&#9654; Обновить IP сейчас</a>&nbsp;&nbsp;' ..
        '<a class="btn cbi-button" href="%s/run_sni_scan" style="margin-left:8px">&#9654; Сканировать SNI</a>',
        base, base)
end

-- ============================================================
-- Секция: Latency Monitor (прокси-группы)
-- ============================================================
local s_lat = m:section(NamedSection, "main", "cf_optimizer", translate("Latency Monitor"))
s_lat.addremove = false
s_lat.anonymous = true

local function lat_val(key, default)
    return (lat_stat and lat_stat[key]) and lat_stat[key] or (default or "—")
end

local dv_lat_run = s_lat:option(DummyValue, "_lat_run", translate("Последний запуск"))
dv_lat_run.cfgvalue = function() return lat_val("LAST_RUN") end

local dv_gem = s_lat:option(DummyValue, "_gem", translate("GEMINI (текущий)"))
dv_gem.rawhtml = true
dv_gem.cfgvalue = function()
    local proxy  = lat_val("GEMINI_PROXY")
    local delay  = lat_val("GEMINI_DELAY")
    local st     = lat_val("GEMINI_STATUS")
    if proxy == "—" then
        return "<em style='color:#aaa'>Ещё не запускался</em>"
    end
    local color = (st == "ok") and "#4caf50" or "#f44336"
    return string.format("<strong>%s</strong> &nbsp; <span style='color:%s'>%s</span>",
        luci.util.pcdata(proxy), color, luci.util.pcdata(delay))
end

local dv_main_lat = s_lat:option(DummyValue, "_main_lat", translate("PrvtVPN Auto (текущий)"))
dv_main_lat.rawhtml = true
dv_main_lat.cfgvalue = function()
    local proxy = lat_val("MAIN_PROXY")
    local delay = lat_val("MAIN_DELAY")
    if proxy == "—" then
        return "<em style='color:#aaa'>—</em>"
    end
    return string.format("%s &nbsp; <span style='color:#4caf50'>%s</span>",
        luci.util.pcdata(proxy), luci.util.pcdata(delay))
end

local dv_lat_btn = s_lat:option(DummyValue, "_lat_btn", translate("Действие"))
dv_lat_btn.rawhtml = true
dv_lat_btn.cfgvalue = function()
    local base = luci.dispatcher.build_url("admin/services/cf_optimizer")
    return string.format(
        '<a class="btn cbi-button cbi-button-apply" href="%s/run_latency">&#9654; Запустить сейчас</a>',
        base)
end

-- ============================================================
-- Секция: Включение блоков
-- ============================================================
local s_enable = m:section(NamedSection, "main", "cf_optimizer", translate("Включить / Выключить"))
s_enable.addremove = false
s_enable.anonymous = true

s_enable:option(Flag, "latency_enabled",
    translate("Latency Monitor"),
    translate("Тестировать прокси через Mihomo API и переключать GEMINI на лучший (каждые 2 часа)"))

s_enable:option(Flag, "dpi_bypass_enabled",
    translate("DPI Bypass (nftables MSS)"),
    translate("Разбивать TLS ClientHello на части — DPI не видит SNI целиком. Только трафик Mihomo (mark=2)"))

s_enable:option(Flag, "ip_updater_enabled",
    translate("CF IP Updater"),
    translate("Автоматически находить лучший CF edge IP (только если прокси за Cloudflare CDN)"))

s_enable:option(Flag, "sni_scanner_enabled",
    translate("SNI Scanner"),
    translate("Тестировать SNI через реальный туннель Mihomo (только если прокси за Cloudflare CDN)"))

-- ============================================================
-- Секция: Настройки
-- ============================================================
local s_cfg = m:section(NamedSection, "main", "cf_optimizer", translate("Настройки"))
s_cfg.addremove = false
s_cfg.anonymous = true

local gem_grp = s_cfg:option(Value, "gemini_group", translate("GEMINI группа (имя в Mihomo)"))
gem_grp.placeholder = "🤖 GEMINI"
gem_grp.description = translate("Точное имя select-группы для Gemini. Latency Monitor переключает её автоматически.")

local main_grp = s_cfg:option(Value, "main_group", translate("Main группа (имя в Mihomo)"))
main_grp.placeholder = "PrvtVPN All Auto"
main_grp.description = translate("url-test группа — Mihomo управляет сам, мониторинг только читает.")

local wurl = s_cfg:option(Value, "worker_url", translate("Worker API URL"))
wurl.placeholder = "https://YOUR_WORKER.workers.dev"
wurl.description = translate("URL вашего Cloudflare Worker (Cloudflare-Country-Specific-IP-Filter)")

local reg = s_cfg:option(Value, "regions", translate("Регионы"))
reg.placeholder = "FI,DE,NL"
reg.description = translate("Коды стран через запятую. Пример: FI,DE,NL,SE")

local pname = s_cfg:option(Value, "proxy_name", translate("Имя прокси в Mihomo"))
pname.description = translate("Точное имя VLESS/Trojan прокси из config.yaml")

local mss = s_cfg:option(Value, "mss_value", translate("MSS Value"))
mss.placeholder = "150"
mss.datatype = "range(40,1460)"
mss.description = translate("40 = максимальная защита (+30 мс), 150 = рекомендуется, 200 = минимальное влияние")

local thresh = s_cfg:option(Value, "update_threshold", translate("Порог обновления (%)"))
thresh.placeholder = "20"
thresh.description = translate("Обновлять IP только если новый быстрее на X%. Защита от лишних hot-reload")

local limit = s_cfg:option(Value, "limit_per_region", translate("IP на регион"))
thresh.placeholder = "10"
limit.description = translate("Сколько IP получать от Worker API для каждого региона")

-- ============================================================
-- Секция: Mihomo API
-- ============================================================
local s_api = m:section(NamedSection, "main", "cf_optimizer", translate("Mihomo API"))
s_api.addremove = false
s_api.anonymous = true

local api_url = s_api:option(Value, "mihomo_api", translate("API URL"))
api_url.placeholder = "http://127.0.0.1:9090"

local api_secret = s_api:option(Value, "mihomo_secret", translate("API Secret"))
api_secret.password = true
api_secret.description = translate("Оставить пустым если secret не задан в config.yaml")

local socks = s_api:option(Value, "mihomo_socks", translate("SOCKS5 (для SNI тестов)"))
socks.placeholder = "127.0.0.1:7891"

local cfg_path = s_api:option(Value, "mihomo_config", translate("Путь к config.yaml"))
cfg_path.placeholder = "/opt/clash/config.yaml"

-- ============================================================
-- Секция: Последний лог
-- ============================================================
local s_log = m:section(NamedSection, "main", "cf_optimizer", translate("Последний лог"))
s_log.addremove = false
s_log.anonymous = true

local dv_log = s_log:option(DummyValue, "_log", translate("IP Updater"))
dv_log.rawhtml = true
dv_log.cfgvalue = function()
    local log = read_log("/var/log/cf-ip-update.log", 10)
    return "<pre style='font-size:11px;max-height:150px;overflow:auto;background:#1a1a2e;color:#a0f0a0;padding:8px;border-radius:4px'>" ..
           luci.util.pcdata(log) .. "</pre>"
end

return m
