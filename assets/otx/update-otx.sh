#!/bin/bash
# Refresh the firewalld 'otx_block' ipset from AlienVault OTX and apply it.
set -euo pipefail

/usr/local/sbin/load-otx.sh
firewall-cmd --check-config
firewall-cmd --reload

# Regenerate the postscreen DNSBL zone (otx.rbl) from the freshly-installed
# ipset and reload rbldnsd. Keeps the port-25 soft-weight DNSBL in sync with
# the firewalld block set. Below-floor → non-zero exit → cron-alert emails.
/usr/bin/otx-rbldnsd-sync.sh
