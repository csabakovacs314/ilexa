#!/usr/bin/env bash
# 05-base — repos, core packages, mtagroup, swap, sysctl, crypto policy.
source "$MD_ROOT/lib/common.sh"
step_guard 05-base || exit 0

# MAIL_HOSTNAME was collected but never applied, so Postfix's myhostname and the
# system hostname could disagree after a fresh install.
if [ "$DRY_RUN" != 1 ] && [ -n "${MAIL_HOSTNAME:-}" ]; then
  if [ "$(hostnamectl --static 2>/dev/null)" != "$MAIL_HOSTNAME" ]; then
    hostnamectl set-hostname "$MAIL_HOSTNAME" && log_info "hostname set: $MAIL_HOSTNAME" \
      || log_warn "could not set hostname to $MAIL_HOSTNAME"
  fi
  # Setting the hostname without a matching /etc/hosts entry leaves the name
  # unresolvable locally: `hostname -f` fails and EVERY sudo call first does a
  # failing DNS lookup, printing "sudo: unable to resolve host <name>" and
  # pausing while it times out. Observed on a real install -- harmless but it
  # contaminates the output of every helper the console shells out to.
  #
  # 127.0.1.1 is Debian's own convention for the primary hostname (its
  # installer writes exactly this), kept separate from the 127.0.0.1 localhost
  # line so neither entry clobbers the other. Idempotent: an existing line for
  # this FQDN is replaced rather than appended to, so re-runs and FQDN changes
  # do not accumulate stale entries.
  if [ -n "${MAIL_FQDN:-}" ] && ! grep -qE "^127\.0\.1\.1[[:space:]]+${MAIL_FQDN}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    backup /etc/hosts
    sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
    printf '127.0.1.1\t%s %s\n' "$MAIL_FQDN" "$MAIL_HOSTNAME" >> /etc/hosts
    log_info "/etc/hosts: 127.0.1.1 -> $MAIL_FQDN $MAIL_HOSTNAME"
  fi
fi

# ---- canonical directories (+ migration off /root) -------------------------
# The installer used to scatter executable loaders, downloaded geoip zone data
# and 0600 API keys directly into /root. Nothing there was reachable by the web
# user, but /root is the root account's home -- not a place for software state,
# and impossible to reason about at a glance. Everything now lands in
# $ILEXA_SBIN / $ILEXA_STATE / $ILEXA_SECRETS (see lib/common.sh); /root keeps
# only operator-facing output (the credentials dump and the generated DNS
# records).
#
# The move is done here rather than left to each module because an ALREADY
# INSTALLED host has live files in the old places, and its cron entries are
# rewritten later in this same run. Relocating first means every later module
# and every regenerated cron file agrees on one layout.
if [ "$DRY_RUN" != 1 ]; then
  install -d -m 0755 -o root -g root "$ILEXA_STATE" "$ILEXA_GEOIP"
  # 0700: the key directory must be unreadable to the web user by construction,
  # not merely because each file inside happens to be 0600. /etc/ilexa itself is
  # 0755 and holds world-readable config, so the keys get their own directory.
  install -d -m 0700 -o root -g root "$ILEXA_SECRETS"

  _migrated=0
  # secrets: dotfile in /root -> plain name in the secrets dir
  for _k in otx_api_key abuse_api_key abuseipdb_key vt_api_key; do
    if [ -s "/root/.$_k" ] && [ ! -s "$ILEXA_SECRETS/$_k" ]; then
      install -m 0600 -o root -g root "/root/.$_k" "$ILEXA_SECRETS/$_k" \
        && rm -f "/root/.$_k" && _migrated=$((_migrated + 1))
    fi
  done
  # loaders: executables
  for _f in load-otx.sh load-otx-uri.sh load-urlhaus.sh load-spamhaus-drop.sh \
            load-abuse-c2.sh load-countries.sh; do
    if [ -f "/root/$_f" ]; then
      rm -f "/root/$_f" && _migrated=$((_migrated + 1))   # reinstalled by 70-otx/72-feeds/60-firewalld
    fi
  done
  # state the loaders build and read back
  for _s in otx-whitelist.txt otx-whitelist-auto.txt otx-uri-whitelist.txt; do
    if [ -e "/root/$_s" ] && [ ! -e "$ILEXA_STATE/$_s" ]; then
      mv -f "/root/$_s" "$ILEXA_STATE/$_s" && _migrated=$((_migrated + 1))
    fi
  done
  # geoip zone files (firewall-report.sh reads these, so they are moved, not dropped)
  for _z in /root/*.zone; do
    [ -e "$_z" ] || continue
    mv -f "$_z" "$ILEXA_GEOIP/" && _migrated=$((_migrated + 1))
  done
  [ "$_migrated" -gt 0 ] && log_info "relocated $_migrated legacy file(s) out of /root (-> $ILEXA_SBIN, $ILEXA_STATE, $ILEXA_SECRETS)"
  unset _migrated _k _f _s _z
fi

# ---- system timezone -------------------------------------------------------
# TIMEZONE was collected and handed to the console's config.php, but nothing
# ever applied it to the HOST. That produced a split: the console displayed one
# timezone while the system clock, mail-log timestamps, cron schedules and
# MariaDB all used another. Worse than simply being wrong, it made the
# dashboard's "today" boundary disagree with the day boundary in the very logs
# it counts. Observed on the Ubuntu test host: console and system both on UTC
# while the operator read them as CEST, two hours out.
if [ "$DRY_RUN" != 1 ] && [ -n "${TIMEZONE:-}" ] && command -v timedatectl >/dev/null 2>&1; then
  _tz_now="$(timedatectl show -p Timezone --value 2>/dev/null || echo)"
  if [ "$_tz_now" != "$TIMEZONE" ]; then
    # Validate before applying: timedatectl rejects an unknown zone, but a typo
    # should say so plainly rather than leave the host on whatever it had.
    if [ -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
      if timedatectl set-timezone "$TIMEZONE"; then
        log_info "system timezone: $_tz_now -> $TIMEZONE"
        # Long-running services cache the zone at start-up. On a FRESH install
        # this module runs before any of them exist, so they inherit it -- but
        # on a re-run that CHANGES the zone they would keep the old one, and
        # rsyslog in particular would then stamp mail.log in a different
        # timezone from the one `date` reports. qa-blocked-stats.sh matches
        # log timestamps against date output to decide what counts as "today",
        # so that split silently mis-counts the dashboard. Restart only what is
        # already running; svc_try never aborts if a unit is absent.
        for _u in rsyslog "${MYSQL_SVC:-mariadb}" "${CLAMD_SVC:-clamd@scan}" crond cron; do
          systemctl is-active --quiet "$_u" 2>/dev/null \
            && { systemctl restart "$_u" >/dev/null 2>&1 \
                 && log_info "  restarted $_u to pick up the new timezone" \
                 || log_warn "  could not restart $_u after the timezone change"; }
        done
        unset _u
      else
        log_warn "could not set system timezone to $TIMEZONE"
      fi
    else
      log_warn "TIMEZONE='$TIMEZONE' is not a known zone (/usr/share/zoneinfo) — leaving the host on $_tz_now"
    fi
  fi
  unset _tz_now
fi

if [ "$PKG_MGR" = apt ]; then
  # apt has no dnf-style auto-refresh-if-stale; every install needs a current
  # index or it fails on a package that genuinely exists. Once per run, here,
  # since this is the first module that installs anything.
  # Lock timeout: see pkg_try() in lib/common.sh.
if [ "$DRY_RUN" != 1 ]; then
  if [ "${MD_PROGRESS_ACTIVE:-0}" = 1 ]; then
    apt-get -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" update -qq >>"$MD_LOG" 2>&1
  else
    apt-get -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" update -qq
  fi
fi
  # rbldnsd/prometheus-node-exporter/whiptail live in universe on Ubuntu (all
  # confirmed via packages.ubuntu.com); most cloud images ship it enabled
  # already, but this is a no-op when it is, not a guess either way.
  if [ "$DRY_RUN" != 1 ]; then
    pkg_try software-properties-common >/dev/null 2>&1 \
      && add-apt-repository -y universe >/dev/null 2>&1 || true
  fi
else
  # EPEL + PHP module stream (EL only -- no equivalent concept on Debian).
  pkg_install epel-release
  # EL10 has NO modular content at all (RHEL 10 dropped Application Streams
  # entirely -- PHP ships as a plain AppStream RPM there, confirmed via
  # repoquery). Attempting the enable on EL10 isn't just a no-op: a leftover
  # "php:8.2" module definition still exists in EL10's own repo metadata as an
  # @modulefailsafe entry that depends on module(platform:el9), and a real
  # repoquery transaction against it produced a modular dependency conflict --
  # so this must be skipped outright on EL10, not merely tolerated via
  # log_warn the way it was on EL9.
  if [ "$DRY_RUN" != 1 ] && [ "${OS_VERSION:-9}" != 10 ]; then
    dnf -y module enable php:8.2 || log_warn "php:8.2 module enable failed"
  fi
fi

# policycoreutils (SELinux tooling) has no Debian equivalent needed here --
# this host's own HARDEN_SELINUX default is "no", and Debian doesn't use
# SELinux at all. bind-utils/newt are RPM-specific split names; dig/host and
# whiptail's runtime lib come from different packages on Debian.
if [ "$PKG_MGR" = apt ]; then
  # acl (setfacl) is pulled in as a dependency on EL but is NOT installed by
  # default on a minimal Ubuntu image. 55-ilexa uses setfacl to grant the web
  # user read access to the Apache log directory, which is 0700 root; without
  # it that step degrades to a warning and the console's Audit > Logins view is
  # permanently empty. Observed on the Ubuntu 24.04 test host.
  pkg_install curl wget tar rsync git bind9-dnsutils \
    firewalld ipset whiptail acl
else
  pkg_install curl wget tar rsync git policycoreutils bind-utils \
    firewalld ipset newt
fi

# mtagroup: shared gid so postfix, clamd and rspamd can reach the clamd socket
# queue dirs and the Bayes dir.
if [ "$DRY_RUN" != 1 ]; then getent group mtagroup >/dev/null || groupadd -g 1000 mtagroup || groupadd mtagroup; fi

# swap for fts_xapian / scanner headroom
swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${swap_kb:-0}" -lt 2000000 ] && [ "$DRY_RUN" != 1 ]; then
  if [ ! -e /swapfile ]; then
    log_info "adding 2G /swapfile"
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
fi

# kernel tuning (matches reference box)
write_file /etc/sysctl.d/99-mail.conf 644 <<'EOF'
vm.swappiness = 10
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
[ "$DRY_RUN" != 1 ] && sysctl -p /etc/sysctl.d/99-mail.conf >/dev/null 2>&1 || true

# system crypto policy: DEFAULT (TLS1.2+), not LEGACY. EL/Fedora-only tool --
# no Debian equivalent, already degrades to a harmless no-op there via ||true.
[ "$DRY_RUN" != 1 ] && update-crypto-policies --set DEFAULT >/dev/null 2>&1 || true

mark_done 05-base
log_info "base setup complete"
