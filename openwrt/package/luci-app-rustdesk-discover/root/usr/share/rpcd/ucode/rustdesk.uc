#!/usr/bin/env ucode

'use strict';

import { access, readfile } from 'fs';

const OUTPUT_FILE = '/tmp/rustdesk_peers.json';
const PID_FILE = '/var/run/rustdesk-discoveryd.pid';

function daemon_running() {
	// procd writes the pidfile while the service instance is running.
	if (access(PID_FILE))
		return true;

	// Fallback: match the full command line of the daemon binary. The
	// "[r]" bracket keeps pgrep from matching its own pgrep invocation.
	return system('pgrep -f "[r]ustdesk-discoveryd" >/dev/null 2>&1') == 0;
}

const methods = {
	peers: {
		call: function() {
			let obj = { updated_ms: 0, peers: [], running: daemon_running() };

			if (access(OUTPUT_FILE)) {
				const data = readfile(OUTPUT_FILE);

				if (data) {
					const parsed = json(data);

					if (parsed)
						obj = parsed;
				}
			}

			return {
				updated_ms: obj.updated_ms ?? 0,
				peers: obj.peers ?? [],
				running: obj.running ?? daemon_running()
			};
		}
	},

	restart: {
		call: function() {
			return {
				ok: system([ '/etc/init.d/rustdesk-discoveryd', 'restart' ]) == 0
			};
		}
	}
};

return { 'luci.rustdesk': methods };