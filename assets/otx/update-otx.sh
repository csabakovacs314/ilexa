#!/bin/bash
# Refresh the firewalld 'otx_block' ipset from AlienVault OTX and apply it.
set -euo pipefail

/usr/local/sbin/load-otx.sh
firewall-cmd --check-config
# Reload through the wrapper, so the Fail2Ban bans this reload would otherwise
# discard (they are runtime rich rules) get re-asserted afterwards. Falls back
# to a plain reload if 60-firewalld has not installed the wrapper.
if [ -x /usr/local/sbin/firewalld-reload.sh ]; then
  /usr/local/sbin/firewalld-reload.sh
else
  firewall-cmd --reload
fi

# Regenerate the postscreen DNSBL zone (otx.rbl) from the freshly-installed
# ipset and reload rbldnsd. Keeps the port-25 soft-weight DNSBL in sync with
# the firewalld block set. Below-floor → non-zero exit → cron-alert emails.
/usr/bin/otx-rbldnsd-sync.sh
