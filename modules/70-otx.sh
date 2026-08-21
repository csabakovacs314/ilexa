#!/usr/bin/env bash
# 70-otx — AlienVault OTX threat-intel suite: IP block (firewalld ipset),
# URI->rspamd scoring, and rbldnsd port-25 DNSBL fed to postscreen.
# Soft-fail everywhere: OTX never blocks legit mail on its own.
source "$MD_ROOT/lib/common.sh"

# The OTX *URI* feed scores message URL hosts via an rspamd multimap rule
# (symbol FEED_OTX_URI, type = "url"), the same shape as the URLhaus feed —
# reconnected 2026-08-15 after a stretch running against SpamAssassin, which
# this installer no longer deploys (rspamd replaced it). See the multimap/
# groups.conf wiring below, appended after 40-rspamd has rendered its base
# config.
: "${ENABLE_OTX_URI:=no}"
step_guard 70-otx || exit 0

if [ "$ENABLE_OTX" != yes ]; then
  log_info "OTX disabled — skipping"; mark_done 70-otx; exit 0
fi

pkg_install rbldnsd unbound jq

# --- API key (0600) + trusted CIDRs ---
if [ -n "$OTX_API_KEY" ] && [ "$DRY_RUN" != 1 ]; then
  install -m 600 /dev/null /etc/ilexa/secrets/otx_api_key
  printf '%s' "$OTX_API_KEY" > /etc/ilexa/secrets/otx_api_key
  log_info "stored OTX API key at /etc/ilexa/secrets/otx_api_key (0600)"
elif [ "$DRY_RUN" != 1 ] && [ ! -s /etc/ilexa/secrets/otx_api_key ]; then
  log_warn "no OTX API key provided — set /etc/ilexa/secrets/otx_api_key (0600) before the cron loaders run"
fi

# --- install the suite ---
if [ "$DRY_RUN" != 1 ]; then
  install -m 700 "$MD_ASSETS/otx/load-otx.sh"      /usr/local/sbin/load-otx.sh
  [ "$ENABLE_OTX_URI" = yes ] && install -m 700 "$MD_ASSETS/otx/load-otx-uri.sh" /usr/local/sbin/load-otx-uri.sh
  for s in update-otx.sh update-otx-uri.sh update-otx-whitelist.sh cron-alert.sh \
           otx-rbldnsd-sync.sh rbldnsd-liveness.sh firewall-report.sh; do
    install -m 755 "$MD_ASSETS/otx/$s" "/usr/bin/$s"
  done
fi

# --- extra trusted CIDRs appended to the manual whitelist ---
if [ -n "$OTX_TRUSTED_CIDRS" ] && [ "$DRY_RUN" != 1 ]; then
  { echo "# operator-supplied trusted CIDRs (mail-deploy)"; printf '%s\n' $OTX_TRUSTED_CIDRS; } \
    >> /var/lib/ilexa/otx-whitelist.txt
fi

# --- rbldnsd (port-25 DNSBL) + unbound stub ---
# rbldnsd/unbound package names are identical on both platforms (confirmed
# live on a real 24.04 host, including rspamd.com's own apt repo shipping
# rbldnsd for noble). Our custom rbldnsd-otx.service unit hardcodes
# ExecStart=/sbin/rbldnsd rather than reading the OS-packaged sysconfig
# file at all -- /sbin/rbldnsd still resolves on Debian because Ubuntu is
# usr-merged (/sbin -> usr/sbin, confirmed live), so no path change is
# needed there. Two real path divergences remain: the sysconfig-equivalent
# file's location, and unbound's conf.d directory name (Debian's own
# packaged unbound.conf includes "unbound.conf.d/*.conf", not "conf.d/*.conf"
# the way EL's does).
if [ "$PKG_MGR" = apt ]; then
  rbldnsd_sysconfig=/etc/default/rbldnsd
  unbound_confd=/etc/unbound/unbound.conf.d
else
  rbldnsd_sysconfig=/etc/sysconfig/rbldnsd
  unbound_confd="${UNBOUND_CONFD:-/etc/unbound/conf.d}"
fi
if [ "$DRY_RUN" != 1 ]; then
  install -d -o rbldnsd -g rbldnsd /var/lib/rbldnsd 2>/dev/null || mkdir -p /var/lib/rbldnsd
  install -m 644 "$MD_ASSETS/otx/rbldnsd.sysconfig"    "$rbldnsd_sysconfig"
  install -m 644 "$MD_ASSETS/otx/rbldnsd-otx.service"  /etc/systemd/system/rbldnsd-otx.service
  install -d "$unbound_confd"
  install -m 644 "$MD_ASSETS/otx/otx-rbl.unbound.conf" "$unbound_confd/otx-rbl.conf"
  # rbldnsd ABORTS at startup when a zone file is missing ("unable to open
  # file" -> "zone loading errors, aborting"), and nothing here creates
  # otx.rbl: it is written by otx-rbldnsd-sync.sh, which runs further down and
  # only when an OTX API key is present. So on any install without a key the
  # unit was enabled but permanently dead, and even WITH a key the first start
  # below still preceded the sync. 99-verify reported it as a hard service
  # failure on the Ubuntu test host.
  #
  # Seed a valid empty zone instead. rbldnsd accepts a comment-only ip4set
  # (verified: loads as e32/24/16/8=0/0/0/0 and serves), so the service starts
  # clean and simply answers "not listed" until the first sync fills it in.
  if [ ! -s /var/lib/rbldnsd/otx.rbl ]; then
    # Same shape otx-rbldnsd-sync.sh writes, minus the OTX entries: SOA/NS/TTL,
    # the A-record template, and the permanent liveness sentinel 127.0.0.2.
    #
    # The sentinel is the point. rbldnsd-liveness.sh probes 2.0.0.127.otx.rbl
    # every 15 minutes and expects 127.0.0.2; an earlier version of this seed
    # wrote only comments, so on any host without an OTX API key the probe
    # failed forever -- restarting the service every quarter hour and mailing
    # root about a DNSBL that was working perfectly well. The sentinel is a
    # liveness marker, not feed data, so it belongs here from the start:
    # the probe then tests what it is for (is rbldnsd answering?) rather than
    # whether anyone has configured a key.
    {
      echo "\$SOA 1800 ns.otx.rbl. hostmaster.otx.rbl. 0 3600 1800 604800 1800"
      echo "\$NS 1800 ns.otx.rbl."
      echo "\$TTL 1800"
      echo ":127.0.0.2:OTX listed (AlienVault malicious IP)"
      echo "# No OTX entries yet — /usr/bin/otx-rbldnsd-sync.sh fills these in"
      echo "# once an API key is present in /etc/ilexa/secrets/otx_api_key."
      echo "127.0.0.2"
    } > /var/lib/rbldnsd/otx.rbl
    chown rbldnsd:rbldnsd /var/lib/rbldnsd/otx.rbl 2>/dev/null || true
    chmod 644 /var/lib/rbldnsd/otx.rbl
    log_info "seeded /var/lib/rbldnsd/otx.rbl (no entries yet, liveness sentinel included) so rbldnsd-otx can start and answer its probe"
  fi
  systemctl daemon-reload
fi
svc_enable unbound
svc_try rbldnsd-otx 2>/dev/null || log_warn "rbldnsd-otx not started yet (zone may be empty until first sync)"

# --- bootstrap whitelist + initial loads ---
if [ "$DRY_RUN" != 1 ]; then
  /usr/bin/update-otx-whitelist.sh || log_warn "CF/Google whitelist bootstrap failed (retries via cron)"
  if [ -s /etc/ilexa/secrets/otx_api_key ]; then
    /usr/local/sbin/load-otx.sh        || log_warn "initial OTX IP load failed"
    if [ "$ENABLE_OTX_URI" = yes ]; then
      /usr/local/sbin/load-otx-uri.sh  || log_warn "initial OTX URI load failed"
    fi
    /usr/bin/otx-rbldnsd-sync.sh || log_warn "initial rbldnsd sync failed"
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
fi

# --- rspamd wiring: groups.conf weight for the otx_uri multimap rule -------
# The rule itself now lives in templates/rspamd/multimap.conf.tmpl,
# unconditionally, alongside feed_firehol/feed_abuseipdb/feed_et. It used to
# be appended to local.d/multimap.conf from here, guarded by a grep so a
# re-run never double-appended -- but render() (see lib/common.sh) overwrites
# its destination unconditionally, so a bare `--only 40-rspamd` re-run wiped
# this rule while the map, the loader and the cron job all kept running.
# Confirmed on a real Ubuntu 24.04 host: enable otx_uri, re-run 40-rspamd
# alone, the rule is gone. 70-otx's grep-guard only restores it on a
# SUBSEQUENT `--only 70-otx`, which a normal re-run does not trigger once its
# own done-marker is set. Moving it into the template closes that class the
# same way it was closed for the other three feeds.
#
# groups.conf stays appended-to here: 40-rspamd never renders that file (see
# its render() calls), so nothing ever overwrites what 70-otx adds to it, and
# this half of the wiring was never at risk.
if [ "$ENABLE_OTX_URI" = yes ] && [ "$DRY_RUN" != 1 ]; then
  LOCALD=/etc/rspamd/local.d
  otx_uri_rspamd_changed=0
  touch "$LOCALD/groups.conf"
  if ! grep -q '"FEED_OTX_URI"' "$LOCALD/groups.conf"; then
    otx_uri_rspamd_changed=1
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "otx_uri" {
  symbols {
    "FEED_OTX_URI" {
      weight = 2.5;
      description = "URL host in AlienVault OTX subscribed-pulse indicators";
    }
  }
}
EOF
    log_info "appended otx_uri weight to $LOCALD/groups.conf"
  fi
  if [ "$otx_uri_rspamd_changed" = 1 ] && systemctl is-active --quiet rspamd; then
    rspamadm configtest >/dev/null 2>&1 && systemctl reload rspamd \
      && log_info "rspamd reloaded to pick up the new otx_uri weight" \
      || log_warn "otx_uri rspamd config did not pass configtest — NOT reloaded, check $LOCALD/groups.conf"
  fi
fi

# --- crontab (soft-fail edge-triggered alerting via cron-alert.sh) ---
write_file /etc/cron.d/otx 644 <<'EOF'
# OTX threat-intel refresh (soft-fail: SOFT_FAIL_RC=75 => alert only on 2nd
# consecutive below-floor run, never hard-fails the pipeline).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would bypass
# the console's notification setting entirely. All alerting goes through
# cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays silent until an
# address is configured in the Admin tab.
MAILTO=""
# The OTX API jobs are guarded on the key file: without a key they can only
# fail, and a cron job that fails every six hours trains an operator to ignore
# the mail. The guard is evaluated at RUN time, so dropping a key in later
# starts them on the next tick with no reinstall. rbldnsd-liveness is
# deliberately NOT guarded -- it monitors whether rbldnsd is answering at all,
# which matters even with an empty zone, since a hung instance stalls every
# postscreen lookup. update-geoip.sh (geoblock) is NOT scheduled here even
# though it lived in this file historically -- it belongs to 72-feeds.sh's
# gated /etc/cron.d/ilexa-feeds (qa-feeds-config.sh is-enabled geoblock &&
# ...), and having it unconditionally here too meant disabling geoblock from
# the console never actually stopped this second, ungated weekly run.
0 */6 * * *  root  [ -s /etc/ilexa/secrets/otx_api_key ] && SOFT_FAIL_RC=75 /usr/bin/cron-alert.sh otx-update /usr/bin/update-otx.sh
15 4 * * 1   root  [ -s /etc/ilexa/secrets/otx_api_key ] && /usr/bin/update-otx-whitelist.sh
*/15 * * * * root  /usr/bin/rbldnsd-liveness.sh
0 6 * * 1    root  /usr/bin/firewall-report.sh
EOF

# Appended separately so the heredoc above stays a literal crontab.
if [ "$ENABLE_OTX_URI" = yes ] && [ "$DRY_RUN" != 1 ]; then
  printf '30 3 * * *   root  [ -s /etc/ilexa/secrets/otx_api_key ] && SOFT_FAIL_RC=75 /usr/bin/cron-alert.sh otx-uri /usr/bin/update-otx-uri.sh\n' \
    >> /etc/cron.d/otx
fi

mark_done 70-otx
log_info "OTX suite installed (IP block + URI-rspamd + rbldnsd DNSBL)"
