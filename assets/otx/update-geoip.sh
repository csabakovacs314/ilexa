#!/bin/bash
# Refresh the firewalld 'geoblock' ipset and apply it to the running firewall.
set -euo pipefail

/usr/local/sbin/load-countries.sh
firewall-cmd --check-config
# Reload through the wrapper, so the Fail2Ban bans this reload would otherwise
# discard (they are runtime rich rules) get re-asserted afterwards. Falls back
# to a plain reload if 60-firewalld has not installed the wrapper.
if [ -x /usr/local/sbin/firewalld-reload.sh ]; then
  /usr/local/sbin/firewalld-reload.sh
else
  firewall-cmd --reload
fi
