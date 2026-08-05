'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

var callStatus = rpc.declare({
	object: 'fancontrol',
	method: 'status',
	expect: {}
});

var callRestart = rpc.declare({
	object: 'fancontrol',
	method: 'restart',
	expect: {}
});

function restartController() {
	return callRestart().then(function(reply) {
		if (!reply || reply.ok !== true)
			throw new Error((reply && reply.error) || _('Fan controller restart failed.'));
		return callStatus();
	});
}

function statusText(status) {
	if (status.error)
		return _('Unavailable: %s').format(status.error);
	if (status.running)
		return _('Running — %s°C, %s%% duty (%s/255), %s mode').format(status.temperature, status.duty, status.pwm, status.mode);
	if (status.disabled)
		return _('Disabled');
	return _('Stopped (safe PWM: %s/255)').format(status.safe_pwm || 255);
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('fancontrol'), callStatus() ]);
	},

	render: function(data) {
		var status = data[1] || {};
		var statusNode = E('p', { 'class': 'cbi-value-description' }, statusText(status));
		var m = new form.Map('fancontrol', _('Fan Control'), _('Configure automatic CPU cooling. The controller resolves pwmfan and CPU thermal paths on every start.'));
		var s = m.section(form.NamedSection, 'settings', 'fancontrol');
		var o;

		o = s.option(form.Flag, 'enable', _('Enable fan control'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('silent', _('Silent'));
		o.value('balanced', _('Balanced'));
		o.value('performance', _('Performance'));
		o.value('custom', _('Custom curve'));
		o.value('manual', _('Manual duty'));
		o.default = 'balanced';
		o.rmempty = false;

		o = s.option(form.Value, 'manual_speed', _('Manual duty (%)'));
		o.datatype = 'range(0,100)';
		o.default = '50';

		o = s.option(form.Value, 'interval', _('Polling interval (seconds)'));
		o.datatype = 'range(1,60)';
		o.default = '5';

		[ 'silent', 'balanced', 'performance', 'custom' ].forEach(function(name) {
			o = s.option(form.Value, 'curve_' + name, _('%s curve').format(name));
			o.description = _('Comma-separated temperature:duty points, for example 30:20,45:40,60:65,75:100. Temperatures must increase and duty must be 0–100.');
			o.validate = function(section_id, value) {
				var previous = -1;
				var valid = value.split(',').every(function(point) {
					var match = point.match(/^(\d+):(\d+)$/);
					if (!match)
						return false;
					var temperature = +match[1];
					var duty = +match[2];
					var ordered = temperature > previous;
					previous = temperature;
					return ordered && temperature <= 130 && duty <= 100;
				});
				return valid || _('Use increasing temperature:duty points with duty between 0 and 100.');
			};
		});

		m.handleSaveApply = function() {
			return this.save().then(function() {
				return ui.changes.apply();
			}).then(function() {
				return restartController();
			}).then(function(updated) {
				ui.addNotification(null, E('p', _('Configuration applied and fan controller restarted.')), 'info');
				statusNode.textContent = statusText(updated || {});
			}).catch(function(error) {
				ui.addNotification(null, E('p', _('Could not apply fan configuration: %s').format(error.message || error)), 'error');
				throw error;
			});
		};

		return m.render().then(function(node) {
			var restart = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					restartController().then(function(updated) {
						statusNode.textContent = statusText(updated || {});
						ui.addNotification(null, E('p', _('Fan controller restarted.')), 'info');
					}).catch(function(error) {
						ui.addNotification(null, E('p', _('Could not restart fan controller: %s').format(error.message || error)), 'error');
					});
				}
			}, [ _('Restart fan controller') ]);
			node.appendChild(E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ _('Status') ]), statusNode, restart ]));
			return node;
		});
	}
});
