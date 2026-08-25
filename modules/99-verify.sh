#!/usr/bin/env bash
# 99-verify — non-destructive acceptance self-check + summary with DNS records.
source "$MD_ROOT/lib/common.sh"
step_guard 99-verify || exit 0

fail=0
svc_fail=0
check() { # label cmd...
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] check: $1"; return 0; fi
  if "${@:2}" >/dev/null 2>&1; then log_info "OK   $1"; else log_warn "FAIL $1"; fail=$((fail+1)); fi
}

# A service that is merely not started yet is worth ONE attempt to start
# before being called a failure: module ordering, a slow dependency or a
# condition that has since been satisfied (clamd waits for its signature
# database to exist) all produce a service that is fine but idle. Only a
# service that will not start even when asked is a real failure.
check_service() { # unit
  local u="$1"
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] check: service $u active"; return 0; fi
  if systemctl is-active --quiet "$u"; then log_info "OK   service $u active"; return 0; fi
  log_info "service $u not running — attempting to start it"
  systemctl start "$u" >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet "$u"; then
    log_info "OK   service $u active (started by verify)"
  else
    log_error "FAIL service $u is NOT running and could not be started"
    log_error "     diagnose with: systemctl status $u ; journalctl -u $u -n 30"
    fail=$((fail+1)); svc_fail=$((svc_fail+1))
  fi
}

check "postfix config"  postfix check
check "dovecot config"  doveconf -n

# Every check_policy_service socket main.cf names must actually exist.
#
# `postfix check` does NOT catch a missing one, and the failure is invisible
# from the server's own side: Postfix answers "451 4.3.5 <user>: Recipient
# address rejected: Server configuration error" to EVERY external sender,
# while local mail keeps flowing because permit_mynetworks short-circuits
# before the policy service is ever consulted. A fresh Ubuntu 24.04 install
# shipped exactly this on 2026-08-17 -- dovecot's quota-status socket was
# never created (dovecot had been started by the package before its config
# was written), so the box accepted mail from itself and rejected all real
# inbound mail, with every service reporting "active".
if [ "$DRY_RUN" != 1 ]; then
  _qdir="$(postconf -h queue_directory 2>/dev/null || echo /var/spool/postfix)"
  while read -r _sock; do
    [ -n "$_sock" ] || continue
    if [ -S "$_qdir/$_sock" ]; then
      log_info "OK   policy socket $_sock exists"
    else
      log_warn "FAIL policy socket $_sock is MISSING ($_qdir/$_sock) — Postfix will answer 451 to every external recipient while local mail still works"
      fail=$((fail+1))
    fi
  done < <(postconf 2>/dev/null \
             | grep -oE 'check_policy_service[[:space:]]+unix:[^,[:space:]]+' \
             | sed -E 's|.*unix:||' | sort -u)
  unset _qdir _sock
fi
for u in "${MYSQL_SVC:-mariadb}" postfix dovecot opendkim opendmarc rspamd "${REDIS_SVC:-redis}" \
         "${CLAMD_SVC:-clamd@scan}" clamav-freshclam "${WEB_SVC:-httpd}" fail2ban "${FIREWALL_SVC:-firewalld}"; do
  check_service "$u"
done
if [ "$ENABLE_OTX" = yes ] && [ "$DRY_RUN" != 1 ]; then
  check "rbldnsd-otx active" systemctl is-active --quiet rbldnsd-otx
  dig +short 2.0.0.127.otx.rbl @127.0.0.1 -p 530 >/dev/null 2>&1 && log_info "OK   otx.rbl responds" || log_warn "otx.rbl not yet answering (may need first sync)"
fi
for p in 25 465 587 143 993 110 995 80 443; do
  check "port $p listening" bash -c "ss -ltn 2>/dev/null | grep -q ':$p '"
done

# --- certificate coverage (computed before the banner so it can be shown IN it) ---
# The names an enabled feature serves over HTTPS but which the certificate may
# not carry. See the ACTION REQUIRED block written further down for the why.
cert_missing=()
cert_have=""
if [ "$DRY_RUN" != 1 ] && [ -s "${TLS_CERT:-}" ]; then
  cert_want=()
  if [ "${ENABLE_MTA_STS:-no}" = yes ]; then
    for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do cert_want+=("mta-sts.$d"); done
  fi
  if [ "${ENABLE_AUTOCONFIG:-no}" = yes ]; then
    for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do cert_want+=("autoconfig.$d" "autodiscover.$d"); done
  fi
  if [ ${#cert_want[@]} -gt 0 ]; then
    cert_have="$(openssl x509 -in "$TLS_CERT" -noout -ext subjectAltName 2>/dev/null \
                 | tr ',' '\n' | sed -nE 's/.*DNS:([A-Za-z0-9.*_-]+).*/\1/p' \
                 | tr 'A-Z' 'a-z' | sort -u)"
    for n in "${cert_want[@]}"; do
      printf '%s\n' "$cert_have" | grep -qx "$n" || cert_missing+=("$n")
    done
  fi
fi

# --- summary + required DNS records ---
spf="v=spf1 a mx ~all"
tls_note="$TLS_MODE"
[ -e "$MD_STATE_DIR/tls-selfsigned.flag" ] && tls_note="SELF-SIGNED (Let's Encrypt did not issue — clients will see cert warnings; fix DNS/port 80 and re-run --only 75)"

# The web addresses belong IN the credentials file: the operator reads that
# one file after the install (it holds the logins), and a login without its
# URL sends them back to scrollback-diving. Guarded so a --only re-run of
# this module doesn't append the block twice.
if [ "$DRY_RUN" != 1 ] && [ -e "$MD_CRED_FILE" ] \
   && ! grep -q "^web addresses" "$MD_CRED_FILE" 2>/dev/null; then
  {
    echo ""
    echo "web addresses"
    printf '%-32s %s\n' "  Landing page" "https://${MAIL_FQDN}/"
    [ "${ENABLE_ILEXA:-yes}" = yes ] \
      && printf '%-32s %s\n' "  ilexa console" "https://${MAIL_FQDN}${ILEXA_URL_PREFIX:-/ilexa/}"
    printf '%-32s %s\n' "  Roundcube webmail" "https://${MAIL_FQDN}/roundcube/"
    printf '%-32s %s\n' "  PostfixAdmin" "https://${MAIL_FQDN}/postfixadmin/"
  } >> "$MD_CRED_FILE"
fi
cat <<EOF

============================================================
 ilexa install complete for $MAIL_FQDN
============================================================
 Credentials:  $MD_CRED_FILE
 DKIM records: /root/mail-deploy-dkim-dns.txt$([ "$ENABLE_MTA_STS" = yes ] && printf '\n MTA-STS/DANE: /root/mail-deploy-dns-extra.txt')
 Log:          $MD_LOG
 TLS:          $tls_note
 Checks failed: $fail$([ ${#cert_missing[@]} -gt 0 ] && printf '\n Cert covers:   %s\n MISSING from cert: %s  <- autoconfig/MTA-STS need these; see %s' "$(printf '%s' "$cert_have" | tr '\n' ' ')" "${cert_missing[*]}" "$DNS_EXTRA_FILE")

 Set these DNS records for each mail domain ($PRIMARY_DOMAIN${EXTRA_DOMAINS:+ $EXTRA_DOMAINS}):
   MX     @        10 $MAIL_FQDN
   A      ${MAIL_FQDN%%.*}   <this server's public IP>$([ "$ENABLE_IPV6" = yes ] && printf '\n   AAAA   %s   <public IPv6>   (+ set the IPv6 PTR too)' "${MAIL_FQDN%%.*}")
   TXT    @        "$spf"
   TXT    _dmarc   "v=DMARC1; p=quarantine; rua=mailto:$ADMIN_EMAIL"
   TXT    default._domainkey   (full value printed below)
   PTR    <public IP> -> $MAIL_FQDN   (set at your hosting provider)
============================================================
EOF

# The values themselves, not just the paths to them. An operator finishing an
# install needs to (a) log in and (b) publish DNS -- making them cat two more
# files to do either is friction at exactly the wrong moment, and the DKIM key
# in particular is the one record nobody can guess or reconstruct.
#
# Printed with `cat`, never log_info: log_* appends to $MD_LOG, which is mode
# 644. Credentials must not land in a world-readable file. This goes to the
# terminal only, and the file the operator is pointed at stays 600.
if [ "$DRY_RUN" != 1 ]; then
  if [ -s "$MD_CRED_FILE" ]; then
    cat <<EOF
 GENERATED CREDENTIALS  (also in $MD_CRED_FILE, mode 600 — keep it or delete it)
------------------------------------------------------------
$(sed 's/^/   /' "$MD_CRED_FILE")
------------------------------------------------------------
EOF
  else
    cat <<EOF
 GENERATED CREDENTIALS: none recorded — expected at $MD_CRED_FILE
   If services were installed, this is a BUG worth reporting, not a normal
   outcome: every generated password should be listed here.
------------------------------------------------------------
EOF
  fi

  dkim_f=/root/mail-deploy-dkim-dns.txt
  if [ -s "$dkim_f" ]; then
    cat <<EOF
 DKIM PUBLIC KEY(S)  (also in $dkim_f)
   Publish each as a TXT record at the name shown. The value is split into
   quoted chunks because DNS strings cap at 255 chars — most providers accept
   it exactly as printed; a few want the chunks concatenated with no quotes.
------------------------------------------------------------
$(sed 's/^/   /' "$dkim_f")
------------------------------------------------------------
EOF
  else
    echo " DKIM: no records generated (expected at $dkim_f)"
  fi

  extra_f=/root/mail-deploy-dns-extra.txt
  if [ "$ENABLE_MTA_STS" = yes ] && [ -s "$extra_f" ]; then
    cat <<EOF
 MTA-STS / TLS-RPT / DANE  (also in $extra_f)
------------------------------------------------------------
$(sed 's/^/   /' "$extra_f")
------------------------------------------------------------
EOF
  fi
  echo "============================================================"
fi

mark_done 99-verify

# A DOWN SERVICE IS NOT AN ADVISORY. The banner above says "install complete",
# and it used to say that even with core services dead -- the operator had to
# notice a "Checks failed: N" line buried in it. A service that will not start
# means the stack does not work, so say so unmistakably and exit non-zero, which
# makes deploy.sh report the run as failed rather than complete.
#
# Non-service checks (a port not listening, a config parse) stay advisory: they
# are usually downstream of the same root cause and blocking on them adds noise
# without adding information.
if [ "$svc_fail" -gt 0 ]; then
  log_error "=============================================================="
  log_error " INSTALL INCOMPLETE: $svc_fail core service(s) are NOT running."
  log_error " The stack will not work until they do. See the FAIL lines above"
  log_error " for the exact units, then re-run:  ./deploy.sh --only 99-verify"
  log_error "=============================================================="
  exit 1
fi
[ "$fail" -eq 0 ] && log_info "verification passed" || log_warn "verification finished with $fail non-service issue(s)"

# ---- ilexa: console post-install checks -------------------------------------
# One implementation, run from a fixed path, shared with the app's own
# install-console.sh. Both callers used to carry their own copies and had
# already diverged: this module checked the folder allowlist but not sudo
# reachability, install-console.sh the reverse. See install/qa-verify-console.sh
# in the app repo for what each check means and why.
QA_VERIFY=/usr/local/sbin/qa-verify-console.sh
if [ "${ENABLE_ILEXA:-yes}" = yes ] && [ "$DRY_RUN" != 1 ]; then
  if [ -x "$QA_VERIFY" ]; then
    while IFS='|' read -r verdict label remedy; do
      case "$verdict" in
        OK)   log_info "OK   ilexa: $label" ;;
        SKIP) log_info "SKIP ilexa: $label — $remedy" ;;
        FAIL) log_warn "FAIL ilexa: $label — $remedy"; fail=$((fail+1)) ;;
      esac
    done < <("$QA_VERIFY" --web-user "${WEB_USER:-apache}" 2>/dev/null)
  else
    log_warn "FAIL ilexa: $QA_VERIFY not installed — console checks skipped"
    fail=$((fail+1))
  fi
fi


# ---- certificate coverage vs the features that need it ----------------------
# ENABLE_AUTOCONFIG and ENABLE_MTA_STS are served over HTTPS from names other
# than MAIL_FQDN, so the certificate has to carry them or Thunderbird, Outlook
# and other MTAs hit a name mismatch -- which the person reporting it will
# describe as "invalid certificate", exactly like a missing cert.
#
# On a first install those names cannot be in the certificate: their DNS
# records do not exist yet, this run prints them below, and 75-tls-dns
# deliberately omits unresolvable names so one of them cannot fail the whole
# order. That is correct behaviour, but it leaves the operator with a server
# whose autoconfig quietly does not work and a warning that scrolled past
# twenty modules ago.
#
# So say it once more, at the end, and write it into the DNS file the operator
# actually keeps -- next to the very records they need to create.
if [ "$DRY_RUN" != 1 ] && [ -s "${TLS_CERT:-}" ] && [ -n "$cert_have" ]; then
    if [ ${#cert_missing[@]} -gt 0 ]; then
      # Deliberately NOT counted in "Checks failed": nothing is broken on this
      # host, the missing piece is DNS the operator has to create.
      log_warn "certificate does not cover: ${cert_missing[*]} — autoconfig/MTA-STS over HTTPS will fail on a name mismatch until it does"
      log_warn "  create the CNAMEs listed in $DNS_EXTRA_FILE, then re-run: ./deploy.sh --only 75-tls-dns --answers <your answers file>"
      dns_extra_block tls-cert <<EOF
# ===== certificate coverage — ACTION REQUIRED =====
# The TLS certificate on this host currently covers ONLY:
$(printf '%s\n' "$cert_have" | sed 's/^/#   /')
#
# It does NOT cover:
$(printf '%s\n' "${cert_missing[@]}" | sed 's/^/#   /')
#
# Those names could not be included at install time because their DNS records
# did not exist yet — requesting a name that does not resolve makes Let's
# Encrypt reject the entire certificate order, so they were skipped.
#
# Until they are covered, Thunderbird/Outlook autoconfig and MTA-STS fetches
# fail with a certificate NAME MISMATCH, which looks identical to an untrusted
# certificate from the client side.
#
# To fix, in this order:
#   1. create the CNAME records listed elsewhere in this file
#   2. wait for them to resolve:  dig +short autoconfig.$PRIMARY_DOMAIN
#   3. re-issue, which picks up whatever now resolves:
#        ./deploy.sh --only 75-tls-dns --answers <your answers file>
#
# Re-running is safe and idempotent; it reloads postfix, dovecot and the web
# server onto the new certificate automatically.
EOF
      log_info "wrote the certificate-coverage note to $DNS_EXTRA_FILE"
    else
      log_info "OK   certificate covers all autoconfig/MTA-STS names"
    fi
    unset cert_want cert_have cert_missing n d
fi
