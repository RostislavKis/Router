'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		const m = new form.Map('cf_optimizer', _('Proxy Optimizer — настройки'),
			_('Управление оптимизаторами Mihomo.'));

		let s, o;

		/* ── Включить / Выключить ── */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('Включить / Выключить'));
		s.addremove = false;
		s.anonymous = true;

		s.option(form.Flag, 'latency_enabled', _('Latency Monitor'),
			_('Тестировать прокси и переключать GEMINI на лучший (каждые 2 часа). Гистерезис — защита от лишних переключений.'));

		s.option(form.Flag, 'dpi_bypass_enabled', _('DPI Bypass — nftables MSS'),
			_('Разбивать TLS ClientHello через MSS clamp. Только трафик Mihomo (mark=2), порты 443/2053/2083/2087/2096.'));

		s.option(form.Flag, 'watchdog_enabled', _('Mihomo Watchdog'),
			_('Перезапускать Mihomo если API не отвечает 2 проверки подряд (каждые 10 мин). Не трогает выбор прокси.'));

		s.option(form.Flag, 'xray_fragment_enabled', _('Xray Fragment — DPI bypass'),
			_('Запускать Xray SOCKS5 :10801 при старте системы. Требует: dialer-proxy: xray-fragment в config.yaml.'));

		s.option(form.Flag, 'geo_update_enabled', _('Geo Update'),
			_('Обновлять geoip.dat / geosite.dat / country.mmdb раз в неделю (вс 04:00).'));

		s.option(form.Flag, 'ip_updater_enabled', _('CF IP Updater'),
			_('Только если прокси стоят за Cloudflare CDN.'));

		s.option(form.Flag, 'sni_scanner_enabled', _('SNI Scanner'),
			_('Только если прокси стоят за Cloudflare CDN.'));

		/* ── Latency Monitor ── */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('Latency Monitor — настройки'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'gemini_group', _('GEMINI группа'));
		o.placeholder = '🤖 GEMINI';
		o.description = _('Точное имя selector-группы из config.yaml (включая эмодзи)');

		o = s.option(form.Value, 'main_group', _('Main группа (мониторинг)'));
		o.placeholder = 'PrvtVPN All Auto';
		o.description = _('url-test группа — только мониторинг, Mihomo управляет ей сам');

		o = s.option(form.Value, 'switch_threshold', _('Порог переключения GEMINI (%)'));
		o.placeholder = '20';
		o.datatype = 'range(0, 50)';
		o.description = _('Переключить GEMINI только если новый прокси быстрее текущего на X%. 0 = всегда, 20 = рекомендуется');

		/* ── DPI bypass ── */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('DPI Bypass — настройки'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'mss_value', _('nftables MSS Value'));
		o.placeholder = '150';
		o.datatype = 'range(40, 1460)';
		o.description = _('40 = максимум защиты, 150 = рекомендуется, 200 = минимальный эффект. Применяется после перезапуска.');

		o = s.option(form.Value, 'xray_fragment_length', _('Xray — длина фрагментов (байт)'));
		o.placeholder = '10-30';
		o.description = _('Диапазон байт фрагментации TLS ClientHello. Применяется при следующем старте Xray.');

		o = s.option(form.Value, 'xray_fragment_interval', _('Xray — интервал (мс)'));
		o.placeholder = '10-20';
		o.description = _('Задержка между фрагментами в мс. Применяется при следующем старте Xray.');

		/* ── CF CDN ── */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('CF CDN — настройки (только для прокси за Cloudflare CDN)'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'worker_url', _('CF Worker API URL'));
		o.placeholder = 'https://YOUR.workers.dev';

		o = s.option(form.Value, 'regions', _('Регионы CF edge'));
		o.placeholder = 'FI,DE,NL';
		o.description = _('Коды стран через запятую');

		o = s.option(form.Value, 'update_threshold', _('Порог обновления IP (%)'));
		o.placeholder = '20';
		o.datatype = 'range(1, 100)';

		/* ── Mihomo API ── */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer', _('Mihomo API'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'mihomo_api', _('API URL'));
		o.placeholder = 'http://127.0.0.1:9090';

		o = s.option(form.Value, 'mihomo_secret', _('API Secret'));
		o.password = true;
		o.description = _('Оставить пустым если secret не задан в config.yaml');

		o = s.option(form.Value, 'mihomo_socks', _('SOCKS5 (SNI тесты)'));
		o.placeholder = '127.0.0.1:7891';

		return m.render();
	}
});
