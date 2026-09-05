'use strict';
'require view';
'require ui';
'require rpc';

var callPeers = rpc.declare({
	object: 'luci.rustdesk',
	method: 'peers',
	params: [],
	expect: { }
});

var callRestart = rpc.declare({
	object: 'luci.rustdesk',
	method: 'restart',
	params: [],
	expect: { ok: true }
});

function renderStatus(s) {
	var badge = E('span', {
		'class': (s.running) ? 'label label-success' : 'label label-danger'
	}, [(s.running) ? _('Running') : _('Not running')]);

	var lastUpdate = '';
	if (s.updated_ms > 0) {
		var d = new Date(s.updated_ms);
		lastUpdate = E('small', {}, [
			' ', _('Last update'), ': ',
			E('strong', {}, [d.toLocaleString()])
		]);
	}

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', { 'class': 'cbi-section-node' }, [_('RustDesk LAN Discovery')]),
		E('div', { 'class': 'cbi-section-node' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Daemon')]),
				E('div', { 'class': 'cbi-value-field' }, [badge, lastUpdate])
			]),
			E('div', { 'class': 'cbi-value cbi-value-last' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Actions')]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							return callRestart().then(function() {
								ui.addNotification(null, E('p', {}, _('Scan restarted.')));
							});
						}
					}, [_('Rescan Now')])
				])
			])
		])
	]);
}

function renderTable(s) {
	var peers = s.peers || [];

	var table = E('table', { 'class': 'table' }, [
		E('thead', {}, [
			E('tr', {}, [
				E('th', {}, [_('RustDesk ID')]),
				E('th', {}, [_('Hostname')]),
				E('th', {}, [_('MAC Address')]),
				E('th', {}, [_('Username')]),
				E('th', {}, [_('Platform')]),
				E('th', {}, [_('IP Address')])
			])
		])
	]);

	var rows = [];
	if (peers.length === 0) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'colspan': '6', 'class': 'text-center' }, [_('No RustDesk peers discovered yet.')])
		]));
	}
	else {
		peers.forEach(function(p) {
			rows.push(E('tr', {}, [
				E('td', {'class': 'text-center'}, [E('strong', {}, [p.id || '-'])]),
				E('td', {'class': 'text-center'}, [p.hostname || '-']),
				E('td', {'class': 'text-center'}, [p.mac || '-']),
				E('td', {'class': 'text-center'}, [p.username || '-']),
				E('td', {'class': 'text-center'}, [p.platform || '-']),
				E('td', {'class': 'text-center'}, [p.ip || '-'])
			]));
		});
	}
	table.appendChild(E('tbody', {}, rows));

	return E('div', { 'class': 'cbi-section cbi-section-node' }, [
		E('h3', { 'class': 'cbi-section-node' }, [_('Discovered Peers (' + peers.length + ')')]),
		E('div', { 'class': 'cbi-section-node' }, [table])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ callPeers() ]);
	},

	render: function(data) {
		var s = data[0] || { running: false, peers: [] };
		return E('div', { 'class': 'cbi-map' }, [
			renderStatus(s),
			renderTable(s)
		]);
	},

	apidata: function() {
		return Promise.all([ callPeers() ]).then(function(d) {
			var s = d[0] || { running: false, peers: [] };
			return E('div', { 'class': 'cbi-map' }, [
				renderStatus(s),
				renderTable(s)
			]);
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
