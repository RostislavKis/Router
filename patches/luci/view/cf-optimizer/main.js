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

/* ── Small helper: coloured badge ── */
function badge(text, color) {
	return E('span', {
		'style': 'display:inline-block;padding:2px 8px;border-radius:3px;font-weight:bold;background:' + color + ';color:#fff'
	}, text);
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.read('/var/run/latency-monitor.status').catch(function() { return ''; }),
			fs.read('/var/run/mihomo-watchdog.status').catch(function() { return ''; }),
			fs.read('/var/run/xray-fragment.status').catch(function() { return ''; })
		]);
	},

	render: function(data) {
		const lat = parseStatus(data[0]);
		const wd  = parseStatus(data[1]);
		const xr  = parseStatus(data[2]);

		const geminiOk  = lat['GEMINI_STATUS'] === 'ok';
		const hasRun    = !!lat['LAST_RUN'];

		/* ── Watchdog colours ── */
		const wdStatus  = wd['WATCHDOG_STATUS'] || '';
		const wdColor   = wdStatus === 'healthy' || wdStatus === 'recovered' ? '#4caf50'
		                : wdStatus === 'failed'     ? '#f44336'
		                : wdStatus === 'warning' || wdStatus === 'restarting' ? '#ff9800'
		                : '#9e9e9e';

		/* ── Xray colours ── */
		const xrStatus  = xr['XRAY_STATUS'] || '';
		const xrInstalled = xr['XRAY_INSTALLED'] === '1';
		const xrRunning   = xrStatus === 'running';
		const xrColor   = xrRunning ? '#4caf50'
		                : xrStatus === 'not_installed' ? '#9e9e9e'
		                : xrStatus === 'failed'         ? '#f44336'
		                : '#ff9800';

		/* ══════════════════════════════════════════════
		   CARD 1: Latency Monitor
		══════════════════════════════════════════════ */
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
						ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
					});
				})
			}, '▶ ' + _('Запустить мониторинг сейчас'))
		]);

		/* ══════════════════════════════════════════════
		   CARD 2: Mihomo Watchdog
		══════════════════════════════════════════════ */
		const wdCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Mihomo Watchdog — статус')),
			E('table', { 'class': 'table', 'style': 'width:100%;margin-bottom:10px' }, [
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'width:200px;font-weight:bold' }, _('Последняя проверка')),
					E('td', { 'class': 'td' }, wd['WATCHDOG_LAST_CHECK'] || _('Ещё не запускался'))
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Состояние')),
					E('td', { 'class': 'td' }, [badge(wdStatus || '—', wdColor)])
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Сбоев подряд')),
					E('td', { 'class': 'td' }, wd['WATCHDOG_FAILS'] || '0')
				])
			])
		]);

		/* ══════════════════════════════════════════════
		   CARD 3: Xray Fragment
		══════════════════════════════════════════════ */
		const xrButtons = xrInstalled
			? [
				/* ── Start / Stop ── */
				E('div', { 'style': 'margin-bottom:12px' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'style': 'margin-right:8px',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec('/usr/local/bin/xray-control.sh', ['start']).then(function() {
								ui.addNotification(null, E('p', _('Xray запущен. Обновите страницу для проверки статуса.')), 'info');
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
							});
						})
					}, '▶ ' + _('Запустить Xray')),
					E('button', {
						'class': 'btn cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec('/usr/local/bin/xray-control.sh', ['stop']).then(function() {
								ui.addNotification(null, E('p', _('Xray остановлен.')), 'info');
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
							});
						})
					}, '■ ' + _('Остановить Xray'))
				]),
				/* ── config.yaml patch ── */
				E('p', { 'style': 'margin:4px 0 6px;font-size:0.9em;color:#555' },
					_('Автоматически добавить / удалить dialer-proxy: xray-fragment во всех прокси config.yaml (резервная копия создаётся автоматически):')),
				E('div', {}, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'style': 'margin-right:8px',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec('/usr/local/bin/xray-apply-config.sh', ['add']).then(function(res) {
								const msg = (res && res.stdout) ? res.stdout : _('dialer-proxy добавлен во все прокси. Mihomo перезагружен.');
								ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;font-size:0.9em' }, msg), 'info');
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
							});
						})
					}, '[+] ' + _('Применить ко всем прокси')),
					E('button', {
						'class': 'btn cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec('/usr/local/bin/xray-apply-config.sh', ['remove']).then(function(res) {
								const msg = (res && res.stdout) ? res.stdout : _('dialer-proxy удалён из всех прокси. Mihomo перезагружен.');
								ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;font-size:0.9em' }, msg), 'info');
							}).catch(function(err) {
								ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
							});
						})
					}, '[-] ' + _('Удалить из всех прокси'))
				])
			  ]
			: [
				E('p', { 'style': 'color:#ff9800;margin:8px 0' }, [
					_('⚠ Xray не установлен. Установить через SSH: '),
					E('code', {}, '/usr/local/bin/xray-install.sh')
				])
			  ];

		const xrCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Xray Fragment — DPI bypass (альтернатива nftables MSS)')),
			E('table', { 'class': 'table', 'style': 'width:100%;margin-bottom:10px' }, [
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'width:200px;font-weight:bold' }, _('Статус')),
					E('td', { 'class': 'td' }, [badge(xrStatus || '—', xrColor)])
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, 'PID'),
					E('td', { 'class': 'td' }, xr['XRAY_PID'] && xr['XRAY_PID'] !== '0' ? xr['XRAY_PID'] : '—')
				]),
				E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'font-weight:bold' }, _('Описание')),
					E('td', { 'class': 'td', 'style': 'font-size:0.9em;color:#666' },
						_('Слушает SOCKS5 :10801. Фрагментирует TLS ClientHello при коннекте к прокси. Требует dialer-proxy: xray-fragment в config.yaml.'))
				])
			]),
			E('div', {}, xrButtons)
		]);

		/* ══════════════════════════════════════════════
		   UCI FORM
		══════════════════════════════════════════════ */
		const m = new form.Map('cf_optimizer', _('Proxy Optimizer'),
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
			_('Запускать Xray SOCKS5 :10801 при старте системы. Требует: установить бинарник + dialer-proxy в config.yaml.'));

		s.option(form.Flag, 'geo_update_enabled', _('Geo Update'),
			_('Обновлять geoip.dat / geosite.dat / country.mmdb раз в неделю (вс 04:00).'));

		s.option(form.Flag, 'ip_updater_enabled', _('CF IP Updater'),
			_('Только если прокси стоят за Cloudflare CDN.'));

		s.option(form.Flag, 'sni_scanner_enabled', _('SNI Scanner'),
			_('Только если прокси стоят за Cloudflare CDN.'));

		/* ── Настройки Latency Monitor ── */
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

		/* ── Настройки DPI bypass ── */
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

		/* ── Настройки CF (CDN) ── */
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

		return m.render().then(function(mapEl) {
			return E('div', {}, [latCard, wdCard, xrCard, mapEl]);
		});
	},

	handleSaveApply: null,
	handleReset: null
});
