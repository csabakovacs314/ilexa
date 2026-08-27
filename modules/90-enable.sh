#!/usr/bin/env bash
# 90-enable — enable + (re)start all core services in a sane order.
source "$MD_ROOT/lib/common.sh"
step_guard 90-enable || exit 0

# CLAMD_SVC belongs here as much as clamav-freshclam does: freshclam only
# downloads signatures, clamd is what rspamd's antivirus module actually talks
# to. Omitting it meant clamd was never enabled at boot, so even a host where
# it had been started by hand came back from a reboot with no virus scanning
# and rspamd reporting CLAM_VIRUS_FAIL on every message.
CORE=("${MYSQL_SVC:-mariadb}" opendkim opendmarc postfix dovecot clamav-freshclam \
      "${CLAMD_SVC:-clamd@scan}" "${WEB_SVC:-httpd}" fail2ban "${FIREWALL_SVC:-firewalld}")
[ "$ENABLE_OTX" = yes ] && CORE+=(unbound rbldnsd-otx)
# Both of these were EL unit names applied to every platform, so on Debian they
# named units that do not exist and 90-enable logged "could not enable ..."
# while the real service went unmanaged.
#
# Unattended updates: 80-unattended installs dnf-automatic on EL, but on Debian
# it configures unattended-upgrades via /etc/apt/apt.conf.d/20auto-upgrades,
# which is driven by apt-daily-upgrade.timer (shipped enabled by the package).
# Metrics: 82-metrics already resolves the name per platform -- apt's package
# ships prometheus-node-exporter.service, EPEL's ships node_exporter.service --
# but modules do not share a shell, so that resolution cannot reach here.
if [ "$ENABLE_UNATTENDED" = yes ]; then
  [ "$PKG_MGR" = apt ] && CORE+=(apt-daily-upgrade.timer) || CORE+=(dnf-automatic.timer)
fi
if [ "$ENABLE_METRICS" = yes ]; then
  [ "$PKG_MGR" = apt ] && CORE+=(prometheus-node-exporter) || CORE+=(node_exporter)
fi
# Same unit name on both families. 21-greylist already restarted it with the
# real config; this is what makes it survive a reboot. If the package was not
# available the loop below warns and moves on -- main.cf's default_action=DUNNO
# means mail still flows without greylisting.
if [ "${ENABLE_GREYLISTING:-yes}" = yes ]; then
  CORE+=(postgrey)
fi

for u in "${CORE[@]}"; do
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] enable --now $u"; continue; fi
  systemctl enable --now "$u" >/dev/null 2>&1 && log_info "enabled $u" \
    || log_warn "could not enable $u (may not be installed / different unit name)"
done

# `enable --now` is not enough, and the gap is silent.
#
# On Debian/Ubuntu a package STARTS its service the moment it is installed,
# using the distribution's default config. Every module then writes the real
# config -- seconds later. `enable --now` does nothing whatsoever to a unit
# that is already running, and nothing else here restarts anything, so a fresh
# install finishes with daemons running configuration nobody intended.
#
# Both instances found on a fresh Ubuntu 24.04 install 2026-08-17 failed
# without erroring anywhere:
#   * dovecot started 21:45:19, its quota config landed 21:45:21, so the
#     quota-status socket Postfix talks to was never created. Every message
#     from an external sender was rejected "451 4.3.5 ... Server configuration
#     error". Local mail worked, because permit_mynetworks short-circuits
#     before the policy service -- so the box looked healthy.
#   * opendkim/opendmarc started before their configs too, kept the packaged
#     unix sockets, and Postfix's TCP milter calls were refused. With
#     milter_default_action=accept, mail was delivered unsigned and with no
#     DMARC evaluation.
# In both cases `systemctl is-active` reported "active" throughout.
#
# try-restart, not restart: it only touches units that are actually running,
# so a unit that legitimately failed to start is left alone for the verify
# step to report rather than being masked by a second start attempt. On a
# re-run of an already-correct host this costs one brief restart per service,
# which is the right trade against shipping a server whose config never took
# effect.
for u in "${CORE[@]}"; do
  [ "$DRY_RUN" = 1 ] && continue
  systemctl try-restart "$u" >/dev/null 2>&1 \
    && log_info "restarted $u so it runs the config this install wrote" \
    || true
done

mark_done 90-enable
log_info "services enabled"
