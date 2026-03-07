'use strict';
'require view';
'require form';
'require fs';
'require ui';

function parseStatus(text) {
	const s = {};
	(text || '').split('\n').forEach(function(line) {
		const m = line.match(/^([A-Z_]+)=(.+)$/);
		if (m) s[m[1]] = m[2];
	});
	return s;
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.read('/var/run/latency-monitor.status').catch(function() { return ''; }),
			fs.read('/var/run/mihomo-watchdog.status').catch(function() { return ''; })
		]);
	},

	render: function(data) {
		const lat = parseStatus(data[0]);
		const wd  = parseStatus(data[1]);

		const geminiOk  = lat['GEMINI_STATUS'] === 'ok';
		const hasRun    = !!lat['LAST_RUN'];
		const wdStatus  = wd['WATCHDOG_STATUS'] || '';
		const wdColor   = wdStatus === 'healthy' || wdStatus === 'recovered' ? '#4caf50'
		                : wdStatus === 'warning'    ? '#ff9800'
		                : wdStatus === 'failed'     ? '#f44336'
		                : wdStatus === 'restarting' ? '#ff9800'
		                : '#9e9e9e';

		/* ── Latency Monitor card ── */
		const latCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Latency Monitor — статус')),
			E('table', { 'class': 'table', 'style': 'width:100%;margin-bottom:10px' }, [
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'width:200px;font-weight:bold' }, _('Последний запуск')),
					E('td', { 'class': 'td' }, hasRun ? lat['LAST_RUN'] : _('Ещё не запускался'))
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('GEMINI — прокси')),
					E('td', { 'class': 'td' }, lat['GEMINI_PROXY']
						? [
							E('strong', {}, lat['GEMINI_PROXY']),
							E('span', {
								'style': 'margin-left:8px;color:' + (geminiOk ? '#4caf50' : '#f44336')
							}, lat['GEMINI_DELAY'] || '')
						  ]
						: _('—'))
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Main — прокси')),
					E('td', { 'class': 'td' }, lat['MAIN_PROXY']
						? lat['MAIN_PROXY'] + '  (' + (lat['MAIN_DELAY'] || '') + ')'
						: _('—'))
				])
			]),
			E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, function() {
					return fs.exec('/usr/local/bin/latency-start.sh', []).then(function() {
						ui.addNotification(null, E('p',
							_('Latency monitor запущен в фоне. Результат появится через ~1 мин.')),
							'info');
					}).catch(function(err) {
						ui.addNotification(null, E('p', _('Ошибка запуска: ') + err.message), 'error');
					});
				})
			}, '▶ ' + _('Запустить мониторинг сейчас'))
		]);

		/* ── Watchdog card ── */
		const wdCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Mihomo Watchdog — статус')),
			E('table', { 'class': 'table', 'style': 'width:100%;margin-bottom:10px' }, [
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'width:200px;font-weight:bold' }, _('Последняя проверка')),
					E('td', { 'class': 'td' }, wd['WATCHDOG_LAST_CHECK'] || _('Ещё не запускался'))
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Состояние')),
					E('td', { 'class': 'td' }, [
						E('span', { 'style': 'font-weight:bold;color:' + wdColor },
							wdStatus || _('—'))
					])
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Сбоев подряд')),
					E('td', { 'class': 'td' }, wd['WATCHDOG_FAILS'] || '0')
				])
			])
		]);

		/* ── UCI форма ── */
		const m = new form.Map('cf_optimizer', _('CF IP Optimizer'),
			_('Управление оптимизаторами прокси для Mihomo.'));

		let s, o;

		/* Включить / Выключить */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('Включить / Выключить'));
		s.addremove = false;
		s.anonymous = true;

		s.option(form.Flag, 'latency_enabled', _('Latency Monitor'),
			_('Тестировать прокси через Mihomo API и переключать GEMINI на лучший (каждые 2 часа)'));

		s.option(form.Flag, 'dpi_bypass_enabled', _('DPI Bypass (nftables MSS)'),
			_('Разбивать TLS ClientHello. Только трафик Mihomo (mark=2), порты 443/2053/2083/2087/2096'));

		s.option(form.Flag, 'watchdog_enabled', _('Mihomo Watchdog'),
			_('Перезапускать Mihomo если API не отвечает 2 проверки подряд (каждые 10 мин)'));

		s.option(form.Flag, 'geo_update_enabled', _('Geo Update'),
			_('Обновлять geoip.dat / geosite.dat / country.mmdb раз в неделю (воскресенье 04:00)'));

		s.option(form.Flag, 'ip_updater_enabled', _('CF IP Updater'),
			_('Только если прокси стоят за Cloudflare CDN'));

		s.option(form.Flag, 'sni_scanner_enabled', _('SNI Scanner'),
			_('Только если прокси стоят за Cloudflare CDN'));

		/* Настройки прокси-групп */
		s = m.section(form.NamedSection, 'main', 'cf_optimizer',
			_('Настройки прокси-групп'));
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

		o = s.option(form.Value, 'mss_value', _('MSS Value (DPI bypass)'));
		o.placeholder = '150';
		o.datatype = 'range(40, 1460)';
		o.description = _('40 = максимум защиты, 150 = рекомендуется, 200 = минимальный эффект');

		o = s.option(form.Value, 'worker_url', _('CF Worker API URL'));
		o.placeholder = 'https://YOUR.workers.dev';
		o.description = _('Только для CF IP Updater и SNI Scanner');

		o = s.option(form.Value, 'regions', _('Регионы CF edge'));
		o.placeholder = 'FI,DE,NL';
		o.description = _('Коды стран через запятую');

		o = s.option(form.Value, 'update_threshold', _('Порог обновления IP (%)'));
		o.placeholder = '20';
		o.datatype = 'range(1, 100)';
		o.description = _('Обновлять IP только если новый быстрее на X%');

		/* Mihomo API */
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

		return m.render().then(function(mapEl) {
			return E('div', {}, [latCard, wdCard, mapEl]);
		});
	},

	handleSaveApply: null,
	handleReset: null
});
