#!/usr/bin/env bash
# 78-autoconfig — client auto-provisioning: Thunderbird autoconfig +
# Outlook autodiscover. Served over HTTPS from autoconfig.<domain> /
# autodiscover.<domain> (cert SANs added in 75-tls-dns). Runs after web/TLS.
source "$MD_ROOT/lib/common.sh"
step_guard 78-autoconfig || exit 0

if [ "$ENABLE_AUTOCONFIG" != yes ]; then
  log_info "autoconfig disabled — skipping"; mark_done 78-autoconfig; exit 0
fi

ALLDOMAINS="$PRIMARY_DOMAIN${EXTRA_DOMAINS:+ $EXTRA_DOMAINS}"
WEB_USER="${WEB_USER:-apache}"
WEB_GROUP="${WEB_GROUP:-apache}"
WEB_CONFD="${WEB_CONFD:-/etc/httpd/conf.d}"

# --- Thunderbird autoconfig XML (one <domain> line per served domain) ---
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<clientConfig version="1.1">'
  echo "  <emailProvider id=\"$PRIMARY_DOMAIN\">"
  for d in $ALLDOMAINS; do echo "    <domain>$d</domain>"; done
  cat <<EOF
    <displayName>$PRIMARY_DOMAIN Mail</displayName>
    <displayShortName>$PRIMARY_DOMAIN</displayShortName>
    <incomingServer type="imap">
      <hostname>$MAIL_FQDN</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>$MAIL_FQDN</hostname>
      <port>465</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>
  </emailProvider>
</clientConfig>
EOF
} | write_file /var/www/autoconfig/mail/config-v1.1.xml 644

# --- Outlook autodiscover XML (static; adequate for basic client setup) ---
write_file /var/www/autodiscover/autodiscover/autodiscover.xml 644 <<EOF
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
  <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
    <Account>
      <AccountType>email</AccountType>
      <Action>settings</Action>
      <Protocol>
        <Type>IMAP</Type><Server>$MAIL_FQDN</Server><Port>993</Port>
        <SSL>on</SSL><SPA>off</SPA><AuthRequired>on</AuthRequired>
      </Protocol>
      <Protocol>
        <Type>SMTP</Type><Server>$MAIL_FQDN</Server><Port>465</Port>
        <SSL>on</SSL><SPA>off</SPA><AuthRequired>on</AuthRequired>
      </Protocol>
    </Account>
  </Response>
</Autodiscover>
EOF

# --- Apache vhosts (autoconfig.<domain> / autodiscover.<domain>) ---
ac_names=""; ad_names=""
for d in $ALLDOMAINS; do ac_names="$ac_names autoconfig.$d"; ad_names="$ad_names autodiscover.$d"; done
emit_vhost() { # docroot  primary  aliases
  local docroot="$1" primary="$2" aliases="$3"
  echo "<VirtualHost *:443>"
  echo "    ServerName $primary"
  [ -n "$aliases" ] && echo "    ServerAlias$aliases"
  echo "    DocumentRoot $docroot"
  echo "    SSLEngine on"
  echo "    SSLCertificateFile $TLS_CERT"
  echo "    SSLCertificateKeyFile $TLS_KEY"
  echo "    <Directory $docroot>"
  echo "        Options -Indexes"
  echo "        Require all granted"
  echo "    </Directory>"
  echo "</VirtualHost>"
}
ac_primary=$(echo "$ac_names" | awk '{print $1}'); ac_alias=$(echo "$ac_names" | cut -d' ' -f2-)
ad_primary=$(echo "$ad_names" | awk '{print $1}'); ad_alias=$(echo "$ad_names" | cut -d' ' -f2-)
[ "$ac_primary" = "$ac_alias" ] && ac_alias=""
[ "$ad_primary" = "$ad_alias" ] && ad_alias=""
{
  emit_vhost /var/www/autoconfig   "$ac_primary" "${ac_alias:+ $ac_alias}"
  emit_vhost /var/www/autodiscover "$ad_primary" "${ad_alias:+ $ad_alias}"
} | write_file "$WEB_CONFD/mail-deploy-autoconfig.conf" 644
# Debian's apache2 doesn't auto-glob conf-available/ the way EL's httpd
# globs conf.d/ -- needs an explicit a2enconf symlink into conf-enabled/.
[ "$PKG_MGR" = apt ] && [ "$DRY_RUN" != 1 ] && a2enconf mail-deploy-autoconfig >/dev/null

if [ "$DRY_RUN" != 1 ]; then
  chown -R "$WEB_USER:$WEB_GROUP" /var/www/autoconfig /var/www/autodiscover 2>/dev/null || true
  { echo "# ===== autoconfig / autodiscover DNS ====="
    for d in $ALLDOMAINS; do
      echo "autoconfig.$d.    IN CNAME $MAIL_FQDN."
      echo "autodiscover.$d.  IN CNAME $MAIL_FQDN."
    done; } | dns_extra_block autoconfig
  if apachectl configtest 2>/dev/null; then svc_reload "${WEB_SVC:-httpd}"; else log_warn "apachectl configtest failed — not reloading ${WEB_SVC:-httpd}"; fi
fi

mark_done 78-autoconfig
log_info "autoconfig + autodiscover endpoints configured"
