#!/bin/bash
# Refresh the OTX -> rspamd URI-scoring map.
#
# Wraps /usr/local/sbin/load-otx-uri.sh, which atomically installs the new host list to
# /etc/rspamd/local.d/maps.d/otx_uri_hosts.inc. Nothing else to do here: rspamd
# watches that file's mtime and hot-reloads it on its own, so there is no
# restart step (unlike the old SpamAssassin/MailScanner path this replaced,
# where this wrapper's whole job was a conditional `systemctl restart
# mailscanner`).
#
# Invoked from cron via /usr/bin/cron-alert.sh (journal on success, mail on
# non-zero exit). Companion to /usr/bin/update-otx.sh (the IP-block path).
#
# Exit non-zero (=> cron-alert mails root) on any HARD failure:
#   - loader guard abort (whitelist unreadable, <500 cleaned entries): last-
#     good map is kept, exit code passed through unchanged (75 = soft/
#     transient — see SOFT_FAIL_RC in this job's crontab entry).
#   - the loader reported success (exit 0) but the map file is missing or
#     empty afterward: should not happen: caught here as a hard stop rather
#     than silently ignored.
#
# NO 'set -e': failures are handled explicitly.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

map="/etc/rspamd/local.d/maps.d/otx_uri_hosts.inc"
loader="/usr/local/sbin/load-otx-uri.sh"

[ -r "$loader" ] || { echo "otx-uri: loader $loader not readable" >&2; exit 2; }

bash "$loader"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "otx-uri: loader failed (rc=$rc) — last-good map kept" >&2
  exit "$rc"
fi

if [ ! -s "$map" ]; then
  echo "otx-uri: loader exited 0 but $map is missing or empty" >&2
  exit 1
fi

echo "otx-uri: map refreshed at $map — rspamd will hot-reload on the next mtime check" >&2
exit 0
