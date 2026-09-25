/* SPDX-License-Identifier: GPL-2.0-only */

'use strict';
'require form';
'require uci';
'require view';

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('network', _('RPS'), _('解决一核有难，多核围观'));

		s = m.section(form.NamedSection, 'globals', 'globals');
		s.anonymous = true;

		o = s.option(form.Flag, 'packet_steering', _('Enable RPS'));
		o.enabled = '2';
		o.disabled = '0';
		o.default = '2';
		o.rmempty = false;
		o.description = _('Automatically distributes receive processing across all CPU cores. an7581 uses mask f (4 cores), an7583 uses mask 3 (2 cores).');
		o.write = function(section_id, formvalue) {
			return Promise.all([
				uci.set('network', section_id, 'packet_steering', formvalue),
				uci.set('network', section_id, 'steering_flows', formvalue == '2' ? '128' : '0')
			]);
		};

		return m.render();
	}
});
