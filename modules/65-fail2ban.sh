#!/usr/bin/env bash
# 65-fail2ban — brute-force jails (bantime 1h + escalating increment).
source "$MD_ROOT/lib/common.sh"
step_guard 65-fail2ban || exit 0

# fail2ban-firewalld is an EL-only packaging split (the firewallcmd-ipset
# action file it provides ships inside the base fail2ban package on Debian --
# fail2ban's action.d/ files are part of its own upstream source, not
# repackaged per-distro, so there's nothing separate to install there).
if [ "$PKG_MGR" = apt ]; then
  pkg_install fail2ban
else
  pkg_install fail2ban fail2ban-firewalld
fi

# Written to jail.d/, NOT jail.local. jail.local is upstream fail2ban's own
# documented convention for *operator* customization -- rendering it whole
# here destroyed whatever the admin had put there. On the reference host that
# meant a re-run would have wiped a hand-written proftpd jail (with a custom
# multi-line failregex), webmin-auth, roundcube-auth, a [postfix] jail, and
# per-jail backend/logpath/maxretry tuning on all three apache jails -- none
# of which this module writes, so none of which it may delete. Same bug class
# as the rbl.conf and firewalld clobbering.
#
# Load order is jail.conf -> jail.d/*.conf -> jail.local -> jail.d/*.local,
# later winning (verified empirically on the 24.04 box: bantime in jail.local
# overrode the same key in a jail.d/*.conf drop-in). So this drop-in supplies
# our defaults and the admin's jail.local still overrides them, which is the
# right way round. On a fresh host no jail.local exists, so these apply as-is.
if [ -s /etc/fail2ban/jail.local ]; then
  log_warn "/etc/fail2ban/jail.local exists and takes precedence over our jail.d drop-in -- leaving it untouched; reconcile by hand if a setting below does not take effect"
fi

write_file /etc/fail2ban/jail.d/00-ilexa.conf 644 <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
banaction = firewallcmd-ipset

[sshd]
enabled = true
port    = $SSH_PORT

[postfix-sasl]
enabled = true

[dovecot]
enabled = true

# Stock apache-auth/-overflows default to \$WEB_LOG_DIR/error_log -- the
# PLAIN vhost's log. Every host this installer produces serves everything
# over HTTPS (templates/web/apache-web.conf.tmpl), so the traffic these two
# jails actually need to see -- Basic-Auth failures for ilexa/rspamd-proxy/
# webmin, and request-size/overflow errors -- lands in the SSL vhost's own
# error log instead, which the stock jail definition never looks at. Same
# reasoning for apache-badbots and the access log. Confirmed live on hawking
# 2026-08-21: these three jails had been silently catching nothing since
# setup for exactly this reason -- see the [[fail2ban_dovecot_gap]] writeup.
#
# EL's stock ssl.conf names the error log "ssl_error_log"; Debian's
# default-ssl.conf has no equivalent rename (unlike CustomLog, which
# modules/50-web.sh already renames to match) and keeps sharing the plain
# vhost's "error.log" -- list both candidates so this is correct on either
# distro. logpath accepts multiple paths; fail2ban skips whichever does not
# exist on this host rather than erroring.
[apache-auth]
enabled = true
logpath = $WEB_LOG_DIR/ssl_error_log
          $WEB_LOG_DIR/error.log

[apache-badbots]
enabled = true
logpath = $WEB_LOG_DIR/ssl_access_log

[apache-overflows]
enabled = true
logpath = $WEB_LOG_DIR/ssl_error_log
          $WEB_LOG_DIR/error.log

# Long-term ban for repeat offenders across all jails (watches fail2ban's log).
[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 5
EOF

svc_enable fail2ban

mark_done 65-fail2ban
log_info "fail2ban configured (ssh port $SSH_PORT)"
