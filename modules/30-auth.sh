#!/usr/bin/env bash
# 30-auth — OpenDKIM (per-domain 2048-bit keys), OpenDMARC, policyd-spf.
source "$MD_ROOT/lib/common.sh"
step_guard 30-auth || exit 0

pkg_install opendkim opendmarc
# opendkim-genkey is bundled in the opendkim package on EL9 and Debian, but
# EL10 split it into opendkim-tools. Without it the key loop below silently
# `continue`s for every domain: no keys, an empty KeyTable and SigningTable,
# and opendkim then refuses to start ("dkimf_db_open(): Permission denied" on
# the empty table) -- reported by 99-verify only as "service not running".
# Asked by capability, not by OS version, and optional because the package
# does not exist where genkey is already bundled.
if ! command -v opendkim-genkey >/dev/null 2>&1; then
  pkg_install_optional opendkim-tools
  command -v opendkim-genkey >/dev/null 2>&1 \
    || log_warn "opendkim-genkey is still missing -- DKIM keys cannot be generated and mail will NOT be signed"
fi

ALLDOMAINS="$PRIMARY_DOMAIN${EXTRA_DOMAINS:+ $EXTRA_DOMAINS}"

# --- OpenDKIM main config (static; socket matches postfix milter 8891) ---
write_file /etc/opendkim.conf 644 <<'EOF'
OversignHeaders         From
Canonicalization        relaxed/relaxed
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
LogWhy                  Yes
MinimumKeyBits          2048
Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SigningTable            refile:/etc/opendkim/SigningTable
Socket                  inet:8891@localhost
Syslog                  Yes
SyslogSuccess           Yes
TemporaryDirectory      /var/tmp
UMask                   022
UserID                  opendkim:opendkim
EOF


# --- TrustedHosts / KeyTable / SigningTable + per-domain keys ---
{ echo "127.0.0.1"; echo "::1"; for d in $ALLDOMAINS; do echo ".$d"; done; } \
  | write_file /etc/opendkim/TrustedHosts 644

if [ "$DRY_RUN" != 1 ]; then
  : > /etc/opendkim/KeyTable
  : > /etc/opendkim/SigningTable
  DNS_OUT=/root/mail-deploy-dkim-dns.txt
  : > "$DNS_OUT"
  for d in $ALLDOMAINS; do
    kd="/etc/opendkim/keys/$d"
    mkdir -p "$kd"
    if [ ! -s "$kd/default.private" ]; then
      opendkim-genkey -b 2048 -D "$kd" -d "$d" -s default || { log_warn "genkey failed for $d"; continue; }
    fi
    chown -R opendkim:opendkim "$kd"; chmod 600 "$kd/default.private"

    echo "default._domainkey.$d $d:default:$kd/default.private" >> /etc/opendkim/KeyTable
    echo "*@$d default._domainkey.$d" >> /etc/opendkim/SigningTable
    { echo "; ===== DKIM DNS record for $d ====="; cat "$kd/default.txt" 2>/dev/null; echo; } >> "$DNS_OUT"
  done
  log_info "DKIM public-key DNS records written to $DNS_OUT"
else
  log_info "[dry-run] would generate DKIM keys for: $ALLDOMAINS"
fi

# --- OpenDMARC (socket matches postfix milter 8893) ---
setvar MAIL_FQDN "$MAIL_FQDN"
render "$MD_TEMPLATES/auth/opendmarc.conf.tmpl" /etc/opendmarc.conf

# --- Debian: /etc/default/* overrides the Socket in the .conf files ---------
# Both daemons are configured above with "Socket inet:8891@localhost" /
# "inet:8893@127.0.0.1", which is what main.cf's smtpd_milters dials. On EL
# that is the whole story. Debian/Ubuntu additionally ship
# /etc/default/opendkim and /etc/default/opendmarc containing
# SOCKET=local:$RUNDIR/<name>.sock, and that value WINS over the .conf -- so
# both milters ended up listening on unix sockets while Postfix kept
# connecting to TCP, logging "connect to Milter service inet:127.0.0.1:8891:
# Connection refused" on every message. Mail still flowed, silently unsigned
# and unchecked: no DKIM signature on outbound, no DMARC evaluation inbound.
#
# A unix socket is not the fix here: Postfix's smtpd runs chrooted to
# /var/spool/postfix on Debian and cannot reach /run/opendkim/. Align the
# override with the .conf instead.
if [ "$PKG_MGR" = apt ] && [ "$DRY_RUN" != 1 ]; then
  for _d in opendkim:8891 opendmarc:8893; do
    _svc="${_d%%:*}"; _port="${_d##*:}"
    [ -f "/etc/default/$_svc" ] || continue
    backup "/etc/default/$_svc"
    if grep -qE '^[[:space:]]*SOCKET=' "/etc/default/$_svc"; then
      sed -i "s|^[[:space:]]*SOCKET=.*|SOCKET=inet:${_port}@127.0.0.1|" "/etc/default/$_svc"
    else
      echo "SOCKET=inet:${_port}@127.0.0.1" >> "/etc/default/$_svc"
    fi
    log_info "/etc/default/$_svc: SOCKET pinned to inet:${_port}@127.0.0.1"
  done
  unset _d _svc _port

  # Debian's opendmarc.service is Type=forking with
  # PIDFile=/run/opendmarc/opendmarc.pid, so systemd waits for a pid file that
  # opendmarc only writes when its config names one. Our opendmarc.conf did
  # not, so the unit sat in "activating" until it hit its start timeout and
  # was killed -- even though the daemon itself was up and answering on 8893.
  # opendkim.conf already carries an equivalent PidFile, which is why only
  # opendmarc showed this. EL's unit is Type=simple and needs none, so this
  # stays on the apt side.
  if ! grep -qiE '^[[:space:]]*PidFile' /etc/opendmarc.conf 2>/dev/null; then
    echo "PidFile /run/opendmarc/opendmarc.pid" >> /etc/opendmarc.conf
    log_info "/etc/opendmarc.conf: PidFile added (Debian's unit is Type=forking)"
  fi
fi

# --- policyd-spf: default /etc/python-policyd-spf/policyd-spf.conf is fine ---

# RESTART, not merely enable. Everything above rewrote the milters' configs --
# including the Socket they listen on -- but Debian starts opendkim/opendmarc
# at PACKAGE INSTALL time, seconds earlier, using the distribution's default.
# The only later contact with these units is 90-enable's
# `systemctl enable --now`, and that does nothing at all to a service which is
# already running. So the fix directly above (pinning SOCKET= to inet) landed
# on disk and never reached the process.
#
# Measured on a fresh Ubuntu 24.04 install 2026-08-17: opendkim started
# 21:45:25, its config was written 21:45:29. Both daemons were still on the
# packaged unix socket while Postfix dialled inet:8891/8893, so every message
# logged "connect to Milter service inet:127.0.0.1:8891: Connection refused"
# -- and since milter_default_action=accept, the mail was delivered anyway,
# unsigned and with no DMARC evaluation. A test message arrived with no
# DKIM-Signature, no Authentication-Results and no X-Spamd-Result at all.
# Nothing failed loudly; `systemctl is-active` said "active" for both.
#
# This is why the acceptance bar is a real message with real headers rather
# than "every module ran".
if [ "$DRY_RUN" != 1 ]; then
  for _u in opendkim opendmarc; do
    if systemctl restart "$_u" >/dev/null 2>&1; then
      log_info "$_u restarted so it picks up the config written above"
    else
      log_warn "$_u would not restart -- postfix milter calls to it will be refused, and with milter_default_action=accept that means silently unsigned mail"
    fi
  done
  unset _u
  # Prove it, rather than trusting the restart: the whole failure mode is a
  # daemon that reports "active" while listening somewhere Postfix cannot
  # reach. Only meaningful for the inet sockets main.cf actually dials.
  for _d in opendkim:8891 opendmarc:8893; do
    _svc="${_d%%:*}"; _port="${_d##*:}"
    if (exec 3<>/dev/tcp/127.0.0.1/"$_port") 2>/dev/null; then
      log_info "$_svc is answering on 127.0.0.1:$_port"
    else
      log_warn "$_svc is NOT listening on 127.0.0.1:$_port -- postfix will log 'Connection refused' and deliver mail unsigned/unchecked"
    fi
  done
  unset _d _svc _port
fi

mark_done 30-auth
log_info "opendkim + opendmarc configured for: $ALLDOMAINS"
