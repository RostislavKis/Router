'use strict';
'require view';

return view.extend({
    render: function() {
        var url = 'http://' + window.location.hostname + ':3000';

        return E('div', { style: 'padding: 24px 0; max-width: 480px;' }, [
            E('h3', { style: 'margin: 0 0 12px; font-size: 16px;' }, 'AdGuard Home'),
            E('p', { style: 'margin: 0 0 20px; color: #555;' },
                'AdGuard Home runs on port 3000. Click the button below to open it in a new tab.'),
            E('a', {
                href: url,
                target: '_blank',
                style: [
                    'display: inline-block',
                    'padding: 9px 20px',
                    'background: #1b7cd4',
                    'color: #fff',
                    'border-radius: 4px',
                    'text-decoration: none',
                    'font-weight: bold',
                    'font-size: 14px'
                ].join(';')
            }, '\u2192 Open AdGuard Home Dashboard')
        ]);
    },
    handleSave:      null,
    handleSaveApply: null,
    handleReset:     null
});
