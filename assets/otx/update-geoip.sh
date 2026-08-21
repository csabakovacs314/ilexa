#!/bin/bash
# Refresh the firewalld 'geoblock' ipset and apply it to the running firewall.
set -euo pipefail

/usr/local/sbin/load-countries.sh
firewall-cmd --check-config
firewall-cmd --reload
