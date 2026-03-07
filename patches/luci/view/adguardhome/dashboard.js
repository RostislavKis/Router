'use strict';
'require view';

return view.extend({
    render: function() {
        var url = 'http://' + window.location.hostname + ':3000';

        return E('div', { style: 'margin: 0; padding: 0;' }, [
            E('div', { style: 'text-align: right; padding: 2px 8px;' }, [
                E('a', {
                    href: url,
                    target: '_blank',
                    style: 'font-size: 12px; color: #3c8dbc; text-decoration: none;'
                }, '\u2192 Open Dashboard')
            ]),
            E('iframe', {
                src: url,
                style: [
                    'width: 100%',
                    'height: calc(100vh - 80px)',
                    'border: none',
                    'display: block'
                ].join(';')
            })
        ]);
    },
    handleSave:      null,
    handleSaveApply: null,
    handleReset:     null
});
