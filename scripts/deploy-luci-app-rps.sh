#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

MODE="${1:-enable}"
case "$MODE" in
	enable)
		PACKET_STEERING=2
		STEERING_FLOWS=128
		;;
	disable)
		PACKET_STEERING=0
		STEERING_FLOWS=0
		;;
	*)
		echo "Usage: $0 [enable|disable]" >&2
		exit 1
		;;
esac

[ "$(id -u)" = "0" ] || {
	echo "This script must run as root." >&2
	exit 1
}

[ -f /etc/config/network ] || {
	echo "OpenWrt network configuration not found." >&2
	exit 1
}

TMPDIR="$(mktemp -d /tmp/luci-app-rps.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/rps.js" <<'RPS_JS'
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
RPS_JS

cat > "$TMPDIR/menu.json" <<'MENU_JSON'
{
	"admin/system/rps": {
		"title": "RPS",
		"order": 35,
		"action": {
			"type": "view",
			"path": "rps"
		},
		"depends": {
			"acl": [ "luci-app-rps" ]
		}
	}
}
MENU_JSON

cat > "$TMPDIR/acl.json" <<'ACL_JSON'
{
	"luci-app-rps": {
		"description": "Grant access to RPS configuration",
		"read": {
			"uci": [ "network" ]
		},
		"write": {
			"uci": [ "network" ]
		}
	}
}
ACL_JSON

mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d \
	/www/luci-static/resources/view /etc/sysctl.d
cp "$TMPDIR/menu.json" /usr/share/luci/menu.d/luci-app-rps.json
cp "$TMPDIR/acl.json" /usr/share/rpcd/acl.d/luci-app-rps.json
cp "$TMPDIR/rps.js" /www/luci-static/resources/view/rps.js
chmod 0644 /usr/share/luci/menu.d/luci-app-rps.json \
	/usr/share/rpcd/acl.d/luci-app-rps.json \
	/www/luci-static/resources/view/rps.js

uci -q set network.globals="globals"
uci -q set network.@globals[0].packet_steering="$PACKET_STEERING"
uci -q set network.@globals[0].steering_flows="$STEERING_FLOWS"
uci -q commit network

printf 'net.core.rps_sock_flow_entries=32768\n' > /etc/sysctl.d/12-rps.conf
[ -w /proc/sys/net/core/rps_sock_flow_entries ] &&
	echo 32768 > /proc/sys/net/core/rps_sock_flow_entries

/etc/init.d/packet_steering restart
/etc/init.d/rpcd restart

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true

CPUS="$(grep -c '^processor' /proc/cpuinfo)"
case "$CPUS" in
	2) EXPECTED_MASK=3 ;;
	4) EXPECTED_MASK=f ;;
	*)
		if [ "$CPUS" -ge 1 ] && [ "$CPUS" -le 32 ]; then
			EXPECTED_MASK="$(printf '%x' "$(( (1 << CPUS) - 1 ))")"
		else
			EXPECTED_MASK=unknown
		fi
		;;
esac

echo "RPS: CPU cores=$CPUS, expected all-core mask=$EXPECTED_MASK"
for dev in eth0 lan1 lan2 lan3 pon0; do
	[ -d "/sys/class/net/$dev/queues" ] || continue
	printf '%s: ' "$dev"
	cat /sys/class/net/"$dev"/queues/rx-*/rps_cpus 2>/dev/null |
		sort | uniq -c | tr '\n' ' '
	echo
done

echo "RPS: state=$PACKET_STEERING flows=$STEERING_FLOWS global_flow=$(cat /proc/sys/net/core/rps_sock_flow_entries)"
echo "LuCI: System -> RPS is available at /cgi-bin/luci/admin/system/rps"
