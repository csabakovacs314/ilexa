#!/usr/bin/env bash
# 76-mta-sts — inbound TLS reputation: MTA-STS policy (served over HTTPS),
# TLS-RPT reporting, and DANE/TLSA record generation. Runs after web (50) and
# TLS (75) so Apache + the cert exist. Publishing the DNS is the operator's job;
# we generate every record into /root/mail-deploy-dns-extra.txt.
source "$MD_ROOT/lib/common.sh"
step_guard 76-mta-sts || exit 0

if [ "$ENABLE_MTA_STS" != yes ]; then
  log_info "MTA-STS disabled — skipping"; mark_done 76-mta-sts; exit 0
fi

ALLDOMAINS="$PRIMARY_DOMAIN${EXTRA_DOMAINS:+ $EXTRA_DOMAINS}"
DNS_EXTRA=/root/mail-deploy-dns-extra.txt
WEB_USER="${WEB_USER:-apache}"
WEB_GROUP="${WEB_GROUP:-apache}"
WEB_CONFD="${WEB_CONFD:-/etc/httpd/conf.d}"

# --- MTA-STS policy document (served at https://mta-sts.<domain>/.well-known/) ---
setvar MTA_STS_MODE "$MTA_STS_MODE"
setvar MAIL_FQDN "$MAIL_FQDN"
render "$MD_TEMPLATES/web/mta-sts.txt.tmpl" /var/www/mta-sts/.well-known/mta-sts.txt

# stable policy id (only changes when you rebuild it deliberately)
if [ "$DRY_RUN" != 1 ]; then
  idfile="$MD_STATE_DIR/mta-sts.id"
  if [ -s "$idfile" ]; then STS_ID=$(cat "$idfile"); else STS_ID=$(date +%Y%m%d%H%M%S); mkdir -p "$MD_STATE_DIR"; echo "$STS_ID" >"$idfile"; fi
  chown -R "$WEB_USER:$WEB_GROUP" /var/www/mta-sts 2>/dev/null || true
else
  STS_ID="<generated-at-deploy>"
fi

# --- Apache vhost for mta-sts.<domain> (HTTPS, serves the policy) ---
# An array avoids the previous space-joined-string approach's two bugs:
# a missing space made "ServerAlias$sn_aliases" render as one glued-together
# invalid directive whenever there WAS an alias, and (with only one domain,
# the common case) the leading space introduced by string concatenation
# made `cut -f2-` return that same single domain as a spurious "alias" —
# so single-domain deploys hit the missing-space bug every time. Confirmed
# live 2026-08-15: apache2 refused to start at all with
# "Invalid command 'ServerAliasmta-sts.example.com'". Not Debian-specific,
# pure shell logic — would have broken identically on EL9's httpd.
servernames=(); for d in $ALLDOMAINS; do servernames+=("mta-sts.$d"); done
sn_primary="${servernames[0]}"
sn_aliases="${servernames[*]:1}"
{
  echo "# mail-deploy MTA-STS policy host (cert must include these names — see 75-tls-dns SAN)"
  echo "<VirtualHost *:443>"
  echo "    ServerName $sn_primary"
  [ -n "$sn_aliases" ] && echo "    ServerAlias $sn_aliases"
  echo "    DocumentRoot /var/www/mta-sts"
  echo "    SSLEngine on"
  echo "    SSLCertificateFile $TLS_CERT"
  echo "    SSLCertificateKeyFile $TLS_KEY"
  echo "    <Directory /var/www/mta-sts>"
  echo "        Options -Indexes"
  echo "        Require all granted"
  echo "    </Directory>"
  echo "</VirtualHost>"
} | write_file "$WEB_CONFD/mail-deploy-mta-sts.conf" 644
# Debian's apache2 doesn't auto-glob conf-available/ the way EL's httpd
# globs conf.d/ -- needs an explicit a2enconf symlink into conf-enabled/.
[ "$PKG_MGR" = apt ] && [ "$DRY_RUN" != 1 ] && a2enconf mail-deploy-mta-sts >/dev/null

# --- DANE / TLSA (3 1 1) for the MX, computed from the live cert ---
tlsa=""
if [ "$DRY_RUN" != 1 ] && [ -r "$TLS_CERT" ]; then
  tlsa=$(openssl x509 -in "$TLS_CERT" -noout -pubkey 2>/dev/null \
         | openssl pkey -pubin -outform DER 2>/dev/null \
         | openssl dgst -sha256 -binary 2>/dev/null | od -An -tx1 | tr -d ' \n')
fi

# --- write the DNS records the operator must publish ---
if [ "$DRY_RUN" != 1 ]; then
  {
    echo "# ===== MTA-STS / TLS-RPT / DANE records (generated $(date -u +%FT%TZ)) ====="
    for d in $ALLDOMAINS; do
      echo "mta-sts.$d.           IN CNAME  $MAIL_FQDN.        ; or an A record to this host"
      echo "_mta-sts.$d.          IN TXT    \"v=STSv1; id=$STS_ID\""
      echo "_smtp._tls.$d.        IN TXT    \"v=TLSRPTv1; rua=mailto:${TLSRPT_RUA:-$ADMIN_EMAIL}\""
    done
    if [ -n "$tlsa" ]; then
      echo "_25._tcp.$MAIL_FQDN.  IN TLSA   3 1 1 $tlsa"
    else
      echo "; TLSA: cert not readable at run time — regenerate after issuance: openssl x509 -in $TLS_CERT -noout -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256"
    fi
    echo
  } | dns_extra_block mta-sts
  log_info "MTA-STS/TLS-RPT/DANE records written to $DNS_EXTRA"
  if apachectl configtest 2>/dev/null; then svc_reload "${WEB_SVC:-httpd}"; else log_warn "apachectl configtest failed — not reloading ${WEB_SVC:-httpd}"; fi
fi

mark_done 76-mta-sts
log_info "MTA-STS ($MTA_STS_MODE) policy + TLS-RPT + DANE records generated"
