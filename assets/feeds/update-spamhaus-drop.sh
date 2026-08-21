#!/bin/bash
# Refresh the firewalld 'spamhaus_drop' ipset from Spamhaus DROP and apply it.
# Loader exits 75 (EX_TEMPFAIL) on a degraded fetch / below-floor result; set -e
# then stops before the reload so the last-good set stays live, and cron-alert
# (SOFT_FAIL_RC=75) edge-triggers instead of mailing on a single transient miss.
set -euo pipefail

/usr/local/sbin/load-spamhaus-drop.sh
firewall-cmd --check-config
firewall-cmd --reload
