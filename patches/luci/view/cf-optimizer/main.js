'use strict';
'require view';
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

		const wdStatus  = wd['WATCHDOG_STATUS'] || '';
		const wdColor   = wdStatus === 'healthy' || wdStatus === 'recovered' ? '#4caf50'
		                : wdStatus === 'failed'                               ? '#f44336'
		                : wdStatus === 'warning' || wdStatus === 'restarting' ? '#ff9800'
		                : '#9e9e9e';

		const xrStatus    = xr['XRAY_STATUS'] || '';
		const xrInstalled = xr['XRAY_INSTALLED'] === '1';
		const xrRunning   = xrStatus === 'running';
		const xrColor     = xrRunning                 ? '#4caf50'
		                  : xrStatus === 'not_installed' ? '#9e9e9e'
		                  : xrStatus === 'failed'        ? '#f44336'
		                  : '#ff9800';

		/* ── CARD 1: Latency Monitor ── */
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
					var prevLastRun = lat['LAST_RUN'] || '';
					return fs.exec('/usr/local/bin/latency-start.sh', []).then(function() {
						ui.addNotification(null, E('p',
							_('Latency monitor запущен. Страница обновится автоматически (~1 мин.).')),
							'info');
						var poll = window.setInterval(function() {
							fs.read('/var/run/latency-monitor.status').catch(function() { return ''; }).then(function(txt) {
								var s = parseStatus(txt);
								if (s['LAST_RUN'] && s['LAST_RUN'] !== prevLastRun) {
									window.clearInterval(poll);
									// Monitor writes LAST_RUN first, then proxy data (~12s later).
									// Wait 20s before reload so all fields are written.
									window.setTimeout(function() { window.location.reload(); }, 20000);
								}
							});
						}, 10000);
						window.setTimeout(function() { window.clearInterval(poll); }, 180000);
					}).catch(function(err) {
						ui.addNotification(null, E('p', _('Ошибка: ') + err.message), 'error');
					});
				})
			}, '▶ ' + _('Запустить мониторинг сейчас'))
		]);

		/* ── CARD 2: Mihomo Watchdog ── */
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

		/* ── CARD 3: Xray Fragment ── */
		const xrButtons = xrInstalled
			? [
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

		return E('div', {}, [latCard, wdCard, xrCard]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
