#!/usr/bin/env bash
# OS profile.
#
# EL9 and EL10 are implemented (one profile function, version-branched -- see
# the note on os_profile_el() below for why this isn't two separate functions
# the way a genuinely different distro family would be). The point of this
# file is that adding Debian later should be writing one more profile
# function, not editing twenty modules: every name that differs between
# distributions is resolved here and nowhere else.
#
# Modules must use these variables rather than literals. If you find yourself
# typing "apache", "httpd", "dnf" or "/etc/httpd" in a module, it belongs here.

os_detect() {
  local id ver full_ver rel="${OS_RELEASE_FILE:-/etc/os-release}"
  [ -r "$rel" ] || die "cannot read $rel — unable to identify the operating system"
  id=$(. "$rel" && echo "${ID}${ID_LIKE:+ $ID_LIKE}")
  ver=$(. "$rel" && echo "${VERSION_ID%%.*}")

  case "$id" in
    *rhel*|*almalinux*|*rocky*|*centos*)
      case "$ver" in
        9|10) os_profile_el "$ver" ;;
        *) die "unsupported version '$ver' — EL9/EL10 only (EL8 and Debian profiles are not written yet)" ;;
      esac
      ;;
    *ubuntu*)
      # Ubuntu's VERSION_ID is YY.MM, not a simple major int like EL's, and a
      # non-LTS interim release (e.g. 24.10) would collide with 24.04 if only
      # the pre-dot part were compared -- so this branch reads the full
      # VERSION_ID directly rather than reusing the already-truncated $ver.
      full_ver=$(. "$rel" && echo "${VERSION_ID}")
      case "$full_ver" in
        22.04|24.04|26.04) os_profile_debian ubuntu "$full_ver" ;;
        *) die "unsupported Ubuntu version '$full_ver' — 22.04/24.04/26.04 LTS only" ;;
      esac
      ;;
    *debian*)
      die "Debian detected — only Ubuntu LTS is implemented today (22.04/24.04/26.04), not Debian proper. The seam exists (lib/os.sh, os_profile_debian) if that's ever needed."
      ;;
    *)
      die "unsupported OS '$id' — supported: RHEL/AlmaLinux/Rocky 9 or 10, Ubuntu 22.04/24.04/26.04 LTS"
      ;;
  esac
  export OS_FAMILY OS_ID OS_VERSION
  export PKG_MGR WEB_USER WEB_GROUP WEB_SVC WEB_CONFD WEB_LOG_DIR PHP_FPM_SVC PHP_FPM_SOCK
  export CLAMD_SVC CLAMD_SOCKET CLAMAV_USER DOVECOT_CONFD RSPAMD_LOCALD
  export MYSQL_SVC MYSQL_SOCK MYSQL_CONFD CRON_D FIREWALL_SVC HTPASSWD_BIN REDIS_PKG REDIS_SVC
  log_info "OS profile: $OS_FAMILY ($OS_ID $OS_VERSION)"
}

# EL9 and EL10 share this one function (version-branched at the bottom) rather
# than getting os_profile_el9()/os_profile_el10() the way Debian will get its
# own function later: verified against real repoquery output on both AlmaLinux
# 9.8 (this host) and a real AlmaLinux 10.2 BaseOS/AppStream/CRB + genuine
# EPEL 10 mirror (not the local "epel" repo ID, which stayed pinned to EL9's
# mirror even under --releasever=10 -- a real trap, caught by actually
# re-pointing at dl.fedoraproject.org/pub/epel/10/ and re-querying), every
# package this installer touches resolves under the SAME name on both
# versions -- postfix, dovecot(+mysql/+pigeonhole/+devel), opendkim, opendmarc,
# clamav/clamav-update/clamd, httpd/mod_ssl, php/php-fpm/php-mysqlnd/
# php-mbstring, fail2ban(+firewalld), rbldnsd, certbot, pypolicyd-spf,
# mariadb-server, unbound, firewalld/ipset -- so the ~20 vars below need no
# version branch at all. Only one real divergence turned up: RHEL 10 replaced
# Redis with Valkey (a drop-in-compatible fork); there is no "redis" package
# on EL10 at all, confirmed by repoquery, not assumed from release notes.
os_profile_el() { # ver (9 or 10)
  local ver="$1"
  OS_FAMILY="el$ver"
  OS_ID=$(. "${OS_RELEASE_FILE:-/etc/os-release}" && echo "$ID")
  OS_VERSION="$ver"

  PKG_MGR=dnf
  WEB_USER=apache
  WEB_GROUP=apache
  WEB_SVC=httpd
  WEB_CONFD=/etc/httpd/conf.d
  WEB_LOG_DIR=/var/log/httpd
  PHP_FPM_SVC=php-fpm
  PHP_FPM_SOCK=/run/php-fpm/www.sock
  CLAMD_SVC=clamd@scan
  CLAMD_SOCKET=/var/run/clamd.scan/clamd.sock
  CLAMAV_USER=clamscan
  DOVECOT_CONFD=/etc/dovecot/conf.d
  RSPAMD_LOCALD=/etc/rspamd/local.d
  MYSQL_SVC=mariadb
  MYSQL_SOCK=/var/lib/mysql/mysql.sock
  MYSQL_CONFD=/etc/my.cnf.d
  CRON_D=/etc/cron.d
  FIREWALL_SVC=firewalld
  HTPASSWD_BIN=/usr/bin/htpasswd

  if [ "$ver" = 10 ]; then
    REDIS_PKG=valkey
    REDIS_SVC=valkey
  else
    REDIS_PKG=redis
    REDIS_SVC=redis
  fi
}

# Ubuntu 22.04/24.04/26.04 LTS share this one function -- unlike EL9/EL10's
# split-by-real-divergence, here it's because every value below is version-
# generic (apt metapackage names like "php-fpm"/"php-mysql", not a pinned
# PHP/package version), so there's nothing to branch on. Confidence is NOT
# equal across the three: every value here, and every module that reads it,
# was verified for real against a live Ubuntu 24.04.4 LTS host (2026-08-15,
# SSH access to a disposable test box) -- actual `apt install`, not just
# `apt-cache policy`; actual service starts; actual doveconf/apachectl/
# rspamadm/firewall-cmd validation. jammy (22.04) and resolute (26.04) are
# still extrapolated from that, on the (unverified) assumption their
# same-named metapackages resolve the same way -- see docs/GUIDE.md.
#
# PHP_FPM_SVC and PHP_FPM_SOCK are deliberately left UNSET here rather than
# guessed: Debian/Ubuntu's PHP-FPM systemd unit is version-specific
# (php8.3-fpm.service on 24.04, confirmed live -- no stable alias exists),
# and the actual installed version isn't knowable at profile-detection time
# on a host where PHP hasn't been installed yet. 50-web.sh resolves both at
# install time (systemctl list-unit-files 'php*-fpm.service', plus the
# stable /run/php/php-fpm.sock alternatives symlink for the socket) and
# persists them via save_secret so later module subprocesses (55-ilexa) see
# the same value load_secrets already gives them for real secrets.
os_profile_debian() { # distro (ubuntu) ver (22.04/24.04/26.04)
  local distro="$1" ver="$2"
  OS_FAMILY="$distro"
  OS_ID=$(. "${OS_RELEASE_FILE:-/etc/os-release}" && echo "$ID")
  OS_VERSION="$ver"

  PKG_MGR=apt   # lib/common.sh's pkg_try dispatches on this; the branch itself
                # calls apt-get (script-stable, unlike the "apt" CLI which
                # upstream marks unstable for scripting).
  WEB_USER=www-data
  WEB_GROUP=www-data
  WEB_SVC=apache2
  WEB_CONFD=/etc/apache2/conf-available   # needs a2enconf too -- Debian's
                                           # Apache doesn't auto-glob conf.d
                                           # the way EL's httpd does. Not
                                           # resolved by this profile alone;
                                           # 50-web.sh's Debian branch (not
                                           # yet written) owns that mechanism.
  WEB_LOG_DIR=/var/log/apache2
  PHP_FPM_SVC=
  PHP_FPM_SOCK=
  CLAMD_SVC=clamav-daemon
  CLAMD_SOCKET=/var/run/clamav/clamd.ctl
  CLAMAV_USER=clamav
  DOVECOT_CONFD=/etc/dovecot/conf.d   # dovecot's own convention, identical
                                       # across distros -- not EL-specific.
  RSPAMD_LOCALD=/etc/rspamd/local.d   # rspamd's own convention, likewise.
  MYSQL_SVC=mariadb
  MYSQL_SOCK=/run/mysqld/mysqld.sock
  MYSQL_CONFD=/etc/mysql/mariadb.conf.d   # NOT /etc/my.cnf.d: that directory
                            # exists on Debian/Ubuntu but my.cnf only
                            # !includedir's conf.d and mariadb.conf.d, so a
                            # drop-in written to my.cnf.d is silently ignored
                            # (verified live: innodb_buffer_pool_size stayed
                            # at the 128M default on the 24.04 box).
  CRON_D=/etc/cron.d
  FIREWALL_SVC=firewalld   # apt-installable; the plan's design decision is to
                            # keep firewalld as the tool on every profile
                            # rather than build a parallel ufw module.
  HTPASSWD_BIN=/usr/bin/htpasswd   # from apache2-utils
  REDIS_PKG=redis-server   # NOT replaced with Valkey on Ubuntu, unlike EL10 --
  REDIS_SVC=redis-server   # confirmed via packages.ubuntu.com, not assumed.
}
