#!/bin/bash
# Refresh the firewalld 'abuse_c2_block' ipset from abuse.ch ThreatFox+Feodo.
# Loader exits 75 on degraded fetch/below-floor; set -e stops before reload so the
# last-good set stays live and cron-alert (SOFT_FAIL_RC=75) soft-fails.
set -euo pipefail
/usr/local/sbin/load-abuse-c2.sh
firewall-cmd --check-config
# Reload through the wrapper, so the Fail2Ban bans this reload would otherwise
# discard (they are runtime rich rules) get re-asserted afterwards. Falls back
# to a plain reload if 60-firewalld has not installed the wrapper.
if [ -x /usr/local/sbin/firewalld-reload.sh ]; then
  /usr/local/sbin/firewalld-reload.sh
else
  firewall-cmd --reload
fi
