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
		return fs.read('/var/run/latency-monitor.status').catch(function() { return ''; });
	},

	render: function(content) {
		const lat = parseStatus(content);
		const geminiOk = lat['GEMINI_STATUS'] === 'ok';
		const hasRun   = !!lat['LAST_RUN'];

		/* ── Карточка статуса ── */
		const statusCard = E('div', { 'class': 'cbi-section' }, [
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

		o = s.option(form.Value, 'update_threshold', _('Порог обновления (%)'));
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
			return E('div', {}, [statusCard, mapEl]);
		});
	},

	handleSaveApply: null,
	handleReset: null
});
