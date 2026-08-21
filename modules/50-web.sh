#!/usr/bin/env bash
# 50-web — Apache + PHP 8.2, security headers, PostfixAdmin and
# Roundcube (the ONLY webmail — AfterLogic/Aurora is never installed).
source "$MD_ROOT/lib/common.sh"
source "$MD_ROOT/lib/db.sh"
step_guard 50-web || exit 0
load_secrets   # POSTFIX_DB_*, ROUNDCUBE_DB_*, and (Debian only) PHP_FPM_SVC/PHP_FPM_SOCK

if [ "$PKG_MGR" = apt ]; then
  # php-sqlite3 is NOT optional: the ilexa console keeps its IOC database in
  # SQLite, so without it every IOC page and the SHA-256 hash import die with
  # PDO's "could not find driver" (HTTP 500). EL gets both the sqlite3 and
  # pdo_sqlite extensions bundled inside php-pdo, which is why this was invisible
  # there; Debian splits SQLite into its own package that nothing else pulls in.
  pkg_install apache2 \
    php-fpm php-mysql php-sqlite3 php-mbstring php-xml php-json php-gd php-intl php-imap php-ldap php-zip
  # mod_ssl is bundled into apache2's core package on Debian (no separate
  # package the way EL has one), but it -- along with rewrite/headers/
  # proxy_fcgi -- ships disabled and needs explicit a2enmod, unlike EL's
  # httpd which loads them by default. Confirmed live on a real 24.04 host
  # 2026-08-15: apache2ctl -M showed none of these loaded pre-enable.
  if [ "$DRY_RUN" != 1 ]; then
    a2enmod rewrite headers ssl proxy_fcgi setenvif >/dev/null
    # PHP-FPM's systemd unit is version-specific (php8.3-fpm.service; no
    # generic alias exists -- confirmed, see lib/os.sh) and only knowable
    # once the package is actually installed. Resolve once and persist via
    # save_secret so later module subprocesses (55-ilexa) see the same
    # value load_secrets already gives them for real secrets -- each module
    # runs as its own `bash modules/NN.sh` subprocess, so a plain shell
    # variable set here would not survive past this script's exit.
    if [ -z "${PHP_FPM_SVC:-}" ]; then
      PHP_FPM_SVC=$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null \
        | awk '{print $1}' | sed 's/\.service$//' | sort -V | tail -1)
      [ -n "$PHP_FPM_SVC" ] || die "no installed php-fpm systemd unit found (package name mismatch?)"
      save_secret PHP_FPM_SVC "$PHP_FPM_SVC"
    fi
    if [ -z "${PHP_FPM_SOCK:-}" ]; then
      # /run/php/php-fpm.sock is a stable "alternatives" symlink to the
      # versioned socket (-> /run/php/php8.3-fpm.sock on 24.04) -- confirmed
      # real on a live host, so unlike the unit name this needs no runtime
      # detection.
      PHP_FPM_SOCK=/run/php/php-fpm.sock
      save_secret PHP_FPM_SOCK "$PHP_FPM_SOCK"
    fi
    a2enconf "$PHP_FPM_SVC" >/dev/null
    systemctl restart apache2   # a2enmod/a2enconf need a full restart, not reload
  fi
else
  # php-pdo is what ships sqlite3.so AND pdo_sqlite.so on EL, which the console's
  # IOC database needs. It was only ever present here as an incidental
  # dependency of something else -- named explicitly so it cannot silently drop
  # out of the dependency chain.
  pkg_install httpd mod_ssl \
    php php-fpm php-pdo php-mysqlnd php-mbstring php-xml php-json php-gd php-intl php-imap php-ldap php-zip
fi
svc_enable "$WEB_SVC"

WWW=/var/www/html
# Pinned versions + SHA-256 (verified upstream). Override via answers if you bump
# a version or a GitHub archive tarball is re-generated. Roundcube uses a stable
# release asset; the GitHub *archive* hashes (PA/MW) can drift — mismatch fails
# closed (app skipped) with a clear message so you can re-pin deliberately.
PA_VER=4.0.1;  PA_SHA256="${PA_SHA256:-41e096d37f4531af0f0ee63d2288facf0be4c834ff4d2fceca54682c2a7ed113}"
RC_VER=1.6.9;  RC_SHA256="${RC_SHA256:-b61a5f5c22f890c299e935aacfcf0870676990d8aebff0d6cdff075bf17cef4f}"

# server-level security headers (no global cookie_secure)
[ "$DRY_RUN" != 1 ] && install -m 644 "$MD_TEMPLATES/web/security.conf" "$WEB_CONFD/security.conf"

# web routing + HTTPS enforcement: PostfixAdmin served from public/ only, a
# single :80 -> :443 redirect, deny rules for app config/temp/.git dirs.
setvar MAIL_FQDN "$MAIL_FQDN"
render "$MD_TEMPLATES/web/apache-web.conf.tmpl" "$WEB_CONFD/mail-deploy-web.conf"

# Debian's apache2 does not auto-glob conf-available/ into effect the way
# EL's httpd globs conf.d/ -- each conf needs an explicit a2enconf symlink
# into conf-enabled/. security.conf ships from the apache2 package itself
# and is already enabled by default there, so re-enabling it is a no-op.
if [ "$PKG_MGR" = apt ] && [ "$DRY_RUN" != 1 ]; then
  a2enconf mail-deploy-web security >/dev/null
fi

# point the default TLS vhost at our cert (certbot or self-signed) instead of
# the package's snakeoil/localhost cert.
if [ "$PKG_MGR" = apt ]; then
  ssl_conf=/etc/apache2/sites-available/default-ssl.conf
else
  ssl_conf=/etc/httpd/conf.d/ssl.conf
fi
if [ "$DRY_RUN" != 1 ] && [ -f "$ssl_conf" ]; then
  backup "$ssl_conf"
  sed -i -e "s#^\(\s*SSLCertificateFile\).*#\1 $TLS_CERT#" \
         -e "s#^\(\s*SSLCertificateKeyFile\).*#\1 $TLS_KEY#" "$ssl_conf"
  # Neither platform's stock SSL vhost sets a ServerName -- EL's ssl.conf
  # ships it fully commented out, Debian's default-ssl.conf has no such
  # line at all -- so this vhost was only ever reachable via its accidental
  # IP-based default (127.0.0.1), never the real MAIL_FQDN. Roundcube in
  # particular has no explicit Alias the way PostfixAdmin/ilexa do (both
  # bare top-level Aliases that apply to every vhost regardless of
  # ServerName matching), so without this fix it was completely
  # unreachable via the real domain. Confirmed live 2026-08-15 on both a
  # real EL9 host (ssl.conf) and Ubuntu 24.04 (default-ssl.conf) -- not
  # Debian-specific.
  if grep -qE '^\s*#?\s*ServerName\s' "$ssl_conf"; then
    sed -i -E "s/^\s*#?\s*ServerName\s.*/ServerName $MAIL_FQDN/" "$ssl_conf"
  else
    sed -i "/<VirtualHost/a\\    ServerName $MAIL_FQDN" "$ssl_conf"
  fi
  if [ "$PKG_MGR" = apt ]; then
    # Debian's default-ssl.conf shares access.log with the plain :80 vhost
    # (confirmed on a real 24.04 host); EL's stock ssl.conf logs to a
    # distinct ssl_access_log, which templates/ilexa/config.php.tmpl's
    # access_log_glob assumes. Rename the SSL vhost's log to match so that
    # glob keeps working unchanged on Debian too.
    sed -i "s#^\(\s*CustomLog\s*\)\${APACHE_LOG_DIR}/access\.log#\1\${APACHE_LOG_DIR}/ssl_access_log#" "$ssl_conf"
    a2ensite default-ssl >/dev/null
  fi
fi

fetch() { # url dest
  [ "$DRY_RUN" = 1 ] && { log_info "[dry-run] fetch $1"; return 0; }
  curl -fsSL --max-time 120 "$1" -o "$2"
}

# ---- PostfixAdmin ----------------------------------------------------------
# Without a row in `domain`, mysql_virtual_domains_maps.cf matches nothing and the
# server accepts mail for no one -- the install looks successful and silently works
# for zero addresses. Seed the superadmin and the domains so a first run is usable.
seed_postfixadmin() {
  [ "$DRY_RUN" = 1 ] && { log_info "[dry-run] seed PostfixAdmin superadmin + domains"; return 0; }
  local hash
  # Defence in depth against a blank superadmin. deploy.sh generates one when
  # the answer is empty, but this function is also reachable via --only 50-web
  # with a hand-made answers file, and hashing "" here would mint a superadmin
  # that logs in with no password at all. Refuse rather than create it.
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    log_warn "ADMIN_PASSWORD is empty — refusing to seed a superadmin with a blank password"
    log_warn "  set ADMIN_PASSWORD in the answers file (or leave it unset to have one generated)"
    return 0
  fi
  # PostfixAdmin reads crypt() hashes; bcrypt via PHP keeps us off the password_hash CLI.
  hash=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ADMIN_PASSWORD") || {
    log_warn "could not hash ADMIN_PASSWORD — skipping superadmin seed"; return 0; }

  db_exec "INSERT INTO admin (username,password,superadmin,active,created,modified)
           VALUES ('$ADMIN_EMAIL','$hash',1,1,NOW(),NOW())
           ON DUPLICATE KEY UPDATE password=VALUES(password),superadmin=1,active=1,modified=NOW();" postfix \
    && log_info "PostfixAdmin superadmin: $ADMIN_EMAIL" \
    || log_warn "superadmin seed failed"

  local d
  for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do
    db_exec "INSERT INTO domain (domain,description,aliases,mailboxes,maxquota,quota,transport,backupmx,active,created,modified)
             VALUES ('$d','$d',0,0,0,0,'virtual',0,1,NOW(),NOW())
             ON DUPLICATE KEY UPDATE active=1,modified=NOW();" postfix \
      && log_info "domain seeded: $d" || log_warn "domain seed failed: $d"
    db_exec "INSERT IGNORE INTO domain_admins (username,domain,created,active)
             VALUES ('$ADMIN_EMAIL','$d',NOW(),1);" postfix
  done
  record_cred "PostfixAdmin superadmin" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"

  # --- second, dedicated PostfixAdmin superadmin ----------------------------
  # postfixadmin@<fqdn> exists so the panel has an account of its own, separate
  # from the operator's postmaster@<domain> identity: the postmaster address is
  # also a real mailbox and a published contact, so using it as the only way
  # into the panel ties one credential to two very different jobs.
  #
  # Deliberately keyed on MAIL_FQDN, not PRIMARY_DOMAIN, so the login can never
  # collide with a real mailbox an operator might later create in a virtual
  # domain. It is a login only -- no mailbox row is created for it, and nothing
  # delivers mail there.
  #
  # The account row itself is the source of truth for whether a password has
  # already been issued -- deliberately NOT save_secret, because 50-web calls
  # load_secrets at module load, which would overwrite an operator's
  # answers-file value with the previously generated one on every re-run and
  # silently ignore what they asked for.
  #
  # So: an explicit PFA_ADMIN_PASSWORD always wins; otherwise a password is
  # generated only when the account does not exist yet. A re-run therefore
  # never rotates the credential out from under whoever wrote the first one
  # down, and never re-records a password it did not set.
  local pfa_user="postfixadmin@${MAIL_FQDN}" pfa_hash pfa_pw pfa_exists
  pfa_exists=$(db_exec "SELECT 1 FROM admin WHERE username='$pfa_user' LIMIT 1;" postfix 2>/dev/null)

  if [ -n "${PFA_ADMIN_PASSWORD:-}" ]; then
    pfa_pw="$PFA_ADMIN_PASSWORD"
  elif [ -n "$pfa_exists" ]; then
    log_info "PostfixAdmin admin: $pfa_user already exists — password left unchanged"
    return 0
  else
    pfa_pw=$(gen_pw 24)
  fi

  pfa_hash=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$pfa_pw") || {
    log_warn "could not hash the $pfa_user password — skipping"; return 0; }

  if db_exec "INSERT INTO admin (username,password,superadmin,active,created,modified)
              VALUES ('$pfa_user','$pfa_hash',1,1,NOW(),NOW())
              ON DUPLICATE KEY UPDATE password=VALUES(password),superadmin=1,active=1,modified=NOW();" postfix; then
    # Mirror the domain_admins rows the other superadmin gets, so the account
    # still works if its superadmin flag is ever cleared in the UI.
    for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do
      db_exec "INSERT IGNORE INTO domain_admins (username,domain,created,active)
               VALUES ('$pfa_user','$d',NOW(),1);" postfix
    done
    # NEVER log the password: MD_LOG is world-readable (644). record_cred
    # writes it to the 600 credentials file, which 99-verify prints via cat.
    log_info "PostfixAdmin admin: $pfa_user (password in $MD_CRED_FILE)"
    record_cred "PostfixAdmin admin" "$pfa_user" "$pfa_pw"
  else
    log_warn "could not seed the $pfa_user account"
  fi
}

deploy_postfixadmin() {
  local dir="$WWW/postfixadmin"
  if [ "$DRY_RUN" != 1 ] && [ ! -d "$dir" ]; then
    local tgz=/tmp/pa.tgz
    fetch "https://github.com/postfixadmin/postfixadmin/archive/refs/tags/postfixadmin-${PA_VER}.tar.gz" "$tgz" \
      || { log_warn "PostfixAdmin download failed — skipping"; return 0; }
    verify_sha256 "$tgz" "$PA_SHA256" || { log_warn "PostfixAdmin checksum failed — skipping"; return 0; }
    mkdir -p "$dir"; tar xzf "$tgz" -C "$dir" --strip-components=1
    mkdir -p "$dir/templates_c"; chown -R "$WEB_USER:$WEB_GROUP" "$dir/templates_c"
  fi
  # The GitHub release tarball ships composer.json but NOT a pre-built
  # vendor/ -- upgrade.php (and the whole app) fatals on a missing
  # autoloader without this. Confirmed live 2026-08-15: this had never
  # actually run before on ANY OS (no end-to-end run of this installer
  # existed until this session), so the gap was invisible to every
  # static/dry-run check so far -- it's not a Debian-specific issue.
  # composer is the same package name on both platforms (EPEL's
  # composer-2.10.2 / Ubuntu universe's composer-2.7.1). Gated on vendor/
  # missing rather than folded into the "$dir didn't exist yet" branch
  # above, so a prior failed attempt (e.g. a network hiccup) gets retried
  # on the next run instead of silently staying broken forever.
  if [ "$DRY_RUN" != 1 ] && [ -f "$dir/composer.json" ] && [ ! -d "$dir/vendor" ]; then
    pkg_install composer
    # ext-sqlite3 is flagged as a platform requirement by a transitive
    # dependency (composer wouldn't say which), but PostfixAdmin only ever
    # talks to MySQL in this installer's config -- confirmed by actually
    # installing with it ignored and getting a clean, fully-functional
    # vendor/ tree, not just an assumption. ext-sqlite3 also isn't even
    # packaged for EL9 at all (dnf has no matching package), so requiring
    # it for real would make PostfixAdmin permanently uninstallable there.
    if COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction \
         --working-dir="$dir" >/dev/null 2>&1; then
      log_info "composer dependencies installed for PostfixAdmin"
    else
      log_warn "composer install failed in $dir — PostfixAdmin will not function until it's re-run"
    fi
  fi
  setvar DB_USER "${POSTFIX_DB_USER:-postfix}"; setvar DB_PASSWORD "${POSTFIX_DB_PASS:-CHANGEME}"
  # The console's language file and its own default, so PostfixAdmin follows
  # whatever ilexa is set to. Both are ilexa's, not PostfixAdmin's: the path is
  # derived from the same settings directory config.php.tmpl uses, and the
  # default mirrors ilexa's LANG_DEFAULT for when the file does not exist yet
  # (a fresh install, before anyone has touched the language selector).
  setvar ILEXA_LANG_FILE "/var/cache/quarantine-admin/language"
  setvar ILEXA_LANG_DEFAULT "hu"
  setvar ILEXA_URL_PREFIX "$ILEXA_URL_PREFIX"
  setvar MAIL_FQDN "$MAIL_FQDN"
  # Same postmaster@<domain> identity 55-ilexa already uses as its own
  # mail From (MD_VAR_POSTMASTER_FROM). Left unset, PostfixAdmin's
  # smtp_get_admin_email() falls back to a hardcoded "noreply@example.com"
  # placeholder (functions.inc.php) as the From on every reset-code email
  # public/users/password-recover.php sends -- Gmail (correctly) DMARC-
  # rejects that as unauthenticated. Confirmed live on hawking 2026-08-21.
  setvar POSTMASTER_EMAIL "postmaster@${PRIMARY_DOMAIN}"
  render "$MD_TEMPLATES/web/postfixadmin-config.local.php.tmpl" "$dir/config.local.php"
  [ "$DRY_RUN" != 1 ] && chown "root:$WEB_GROUP" "$dir/config.local.php" && chmod 640 "$dir/config.local.php"
  # Console-matching Bootstrap overrides, referenced by theme_custom_css above.
  # Lives under public/ because header.tpl emits the href relative to the
  # document root the /postfixadmin Alias points at.
  # (install_bin is 72-feeds' own local helper, not a lib function -- calling it
  # here would be a runtime "command not found", so use install directly.)
  [ "$DRY_RUN" != 1 ] && install -m 0644 -o root -g root \
    "$MD_ASSETS/web/postfixadmin-ilexa.css" "$dir/public/css/ilexa.css"
  if [ "$DRY_RUN" != 1 ] && [ -f "$dir/public/upgrade.php" ]; then
    sudo -u "$WEB_USER" php "$dir/public/upgrade.php" >/dev/null 2>&1 && log_info "PostfixAdmin schema applied" \
      || log_warn "PostfixAdmin schema step needs manual run (public/upgrade.php)"
  fi

  # Column-level SELECT grants for the read-only Postfix maps user (created
  # ungranted by 10-mariadb; the maps rendered by 20-postfix use it). Applied
  # here because the tables only exist once upgrade.php has run. The column
  # lists are exactly what the map queries read -- notably NOT
  # mailbox.password, so a leak of the group-readable map files cannot expose
  # password hashes. A failed upgrade.php above makes these fail too; the
  # warning names the fix (re-run this module).
  if [ "$DRY_RUN" != 1 ]; then
    local _h _grants_ok=1
    for _h in localhost 127.0.0.1; do
      db_exec "GRANT SELECT (domain, active) ON postfix.domain TO 'postfix_maps'@'${_h}';
               GRANT SELECT (address, goto, active) ON postfix.alias TO 'postfix_maps'@'${_h}';
               GRANT SELECT (alias_domain, target_domain, active) ON postfix.alias_domain TO 'postfix_maps'@'${_h}';
               GRANT SELECT (username, maildir, quota, active) ON postfix.mailbox TO 'postfix_maps'@'${_h}';" \
        || _grants_ok=0
    done
    db_exec "FLUSH PRIVILEGES;" || true
    if [ "$_grants_ok" = 1 ]; then
      log_info "postfix_maps: column-level SELECT grants applied"
    else
      log_warn "postfix_maps grants failed (schema missing?) — mail routing will fail until you re-run --only 50-web"
    fi
  fi
}

# ---- Roundcube (webmail) ---------------------------------------------------
deploy_roundcube() {
  local dir="$WWW/roundcube"
  if [ "$DRY_RUN" != 1 ] && [ ! -d "$dir" ]; then
    local tgz=/tmp/rc.tgz
    fetch "https://github.com/roundcube/roundcubemail/releases/download/${RC_VER}/roundcubemail-${RC_VER}-complete.tar.gz" "$tgz" \
      || { log_warn "Roundcube download failed — skipping"; return 0; }
    verify_sha256 "$tgz" "$RC_SHA256" || { log_warn "Roundcube checksum failed — skipping"; return 0; }
    mkdir -p "$dir"; tar xzf "$tgz" -C "$dir" --strip-components=1
    chown -R "$WEB_USER:$WEB_GROUP" "$dir/temp" "$dir/logs" 2>/dev/null || true
  fi
  setvar RC_DB_USER "${ROUNDCUBE_DB_USER:-roundcube}"; setvar RC_DB_PASSWORD "${ROUNDCUBE_DB_PASS:-CHANGEME}"
  # des_key must survive a re-run. Roundcube encrypts the IMAP password it
  # carries in the session with it, so regenerating it invalidates every live
  # session and any "keep me logged in" cookie. This was the one generated
  # secret in the codebase without the save_secret/reuse guard that
  # RSPAMD_CTRL_PW, ILEXA_ADMIN_PASSWORD and provision_app_db all use, so
  # every re-run silently logged all webmail users out.
  load_secrets
  if [ -z "${RC_DES_KEY:-}" ]; then
    RC_DES_KEY="$(gen_pw 24)"
    save_secret RC_DES_KEY "$RC_DES_KEY"
  else
    log_info "reusing saved Roundcube des_key (re-run would otherwise drop every webmail session)"
  fi
  setvar DES_KEY "$RC_DES_KEY"
  rc_plugins="'archive', 'zipdownload', 'password', 'secondary_email', 'forgot_password_link', 'markasjunk', 'markasjunk_ham_everywhere', 'newmail_notifier', 'attachment_reminder'"
  [ "$ENABLE_SIEVE" = yes ] && rc_plugins="$rc_plugins, 'managesieve'"
  setvar RC_PLUGINS "$rc_plugins"
  render "$MD_TEMPLATES/web/roundcube-config.inc.php.tmpl" "$dir/config/config.inc.php"
  # managesieve (bundled in -complete.tar.gz): only rendered when the plugin
  # is actually in $rc_plugins above (ENABLE_SIEVE=yes and Dovecot's
  # ManageSieve listener on 4190 therefore exists) -- turns on the vacation
  # UI, off by default in the plugin's own config.inc.php.dist. Confirmed
  # live and working on hawking 2026-08-21.
  if [ "$ENABLE_SIEVE" = yes ]; then
    install -d "$dir/plugins/managesieve" 2>/dev/null || true
    render "$MD_TEMPLATES/web/roundcube-managesieve-config.inc.php.tmpl" "$dir/plugins/managesieve/config.inc.php"
    if [ "$DRY_RUN" != 1 ]; then
      chown "root:$WEB_GROUP" "$dir/plugins/managesieve/config.inc.php" 2>/dev/null || true
      chmod 640 "$dir/plugins/managesieve/config.inc.php" 2>/dev/null || true
      chown "$WEB_USER:$WEB_GROUP" "$dir/plugins/managesieve/config.inc.php"   # re-read as the web user
    fi
  fi
  # password plugin (writes new hashes to the PostfixAdmin mailbox table)
  setvar DB_USER "${POSTFIX_DB_USER:-postfix}"; setvar DB_PASSWORD "${POSTFIX_DB_PASS:-CHANGEME}"
  install -d "$dir/plugins/password" 2>/dev/null || true
  render "$MD_TEMPLATES/web/roundcube-password-config.inc.php.tmpl" "$dir/plugins/password/config.inc.php"
  # secondary_email plugin (recovery-email opt-in + verification; writes
  # mailbox.email_other, which PostfixAdmin's own password-recover.php
  # already reads).
  # Not part of the stock Roundcube release tarball, so the whole plugin
  # tree is copied in, not just a config file.
  if [ "$DRY_RUN" != 1 ]; then
    install -d "$dir/plugins/secondary_email"
    cp -a "$MD_ASSETS/roundcube-secondary-email/." "$dir/plugins/secondary_email/"
  fi
  render "$MD_TEMPLATES/web/roundcube-secondary-email-config.inc.php.tmpl" "$dir/plugins/secondary_email/config.inc.php"
  # forgot_password_link plugin: puts a link to PostfixAdmin's own
  # password-recover.php on Roundcube's login page (via the login skin's
  # <roundcube:container name="loginfooter"> insertion point) -- without
  # it, secondary_email's recovery flow is real but undiscoverable from
  # webmail itself. Also not part of the stock tarball.
  if [ "$DRY_RUN" != 1 ]; then
    install -d "$dir/plugins/forgot_password_link"
    cp -a "$MD_ASSETS/roundcube-forgot-password-link/." "$dir/plugins/forgot_password_link/"
  fi
  render "$MD_TEMPLATES/web/roundcube-forgot-password-link-config.inc.php.tmpl" "$dir/plugins/forgot_password_link/config.inc.php"
  # markasjunk (bundled in the -complete.tar.gz release, unlike secondary_email
  # -- just needs its config + the rspamd learning target) + the
  # markasjunk_ham_everywhere companion, which is NOT bundled and NOT an
  # upstream plugin: markasjunk's own JS hides its "Not junk" button outside
  # the configured spam folder by design, so a message rspamd only tags
  # (add-header tier, never moved to Spam) had no direct way to be taught as
  # ham. The companion hooks markasjunk's own 'markasjunk-update' JS event to
  # force that button visible everywhere -- no vendor file touched. Confirmed
  # working live on hawking 2026-08-21 before being ported in here.
  [ "$DRY_RUN" != 1 ] && install -m 0755 "$MD_ASSETS/roundcube-markasjunk/markasjunk-rspamd" /usr/local/sbin/markasjunk-rspamd
  install -d "$dir/plugins/markasjunk" 2>/dev/null || true
  render "$MD_TEMPLATES/web/roundcube-markasjunk-config.inc.php.tmpl" "$dir/plugins/markasjunk/config.inc.php"
  if [ "$DRY_RUN" != 1 ]; then
    install -d "$dir/plugins/markasjunk_ham_everywhere"
    cp -a "$MD_ASSETS/roundcube-markasjunk-ham-everywhere/." "$dir/plugins/markasjunk_ham_everywhere/"
  fi
  # newmail_notifier (bundled in -complete.tar.gz): static config, no
  # per-deployment values -- desktop/sound/basic notifications on, matching
  # what is live on hawking. attachment_reminder is also bundled but ships
  # no config.inc.php.dist at all (its keyword list is a PHP default, not a
  # config option), so it needs nothing beyond the $rc_plugins entry above.
  install -d "$dir/plugins/newmail_notifier" 2>/dev/null || true
  render "$MD_TEMPLATES/web/roundcube-newmail-notifier-config.inc.php.tmpl" "$dir/plugins/newmail_notifier/config.inc.php"
  if [ "$DRY_RUN" != 1 ]; then
    chown -R "root:$WEB_GROUP" "$dir/config" "$dir/plugins/password/config.inc.php" "$dir/plugins/secondary_email" \
      "$dir/plugins/forgot_password_link" "$dir/plugins/markasjunk/config.inc.php" "$dir/plugins/markasjunk_ham_everywhere" \
      "$dir/plugins/newmail_notifier/config.inc.php" 2>/dev/null || true
    chmod 640 "$dir/config/config.inc.php" "$dir/plugins/password/config.inc.php" "$dir/plugins/secondary_email/config.inc.php" \
      "$dir/plugins/forgot_password_link/config.inc.php" "$dir/plugins/markasjunk/config.inc.php" \
      "$dir/plugins/newmail_notifier/config.inc.php" 2>/dev/null || true
    chown "$WEB_USER:$WEB_GROUP" "$dir/plugins/password/config.inc.php" "$dir/plugins/secondary_email/config.inc.php" \
      "$dir/plugins/forgot_password_link/config.inc.php" "$dir/plugins/markasjunk/config.inc.php" \
      "$dir/plugins/newmail_notifier/config.inc.php"   # plugins re-read as the web user
    # Only on a genuinely empty database. This ran on every re-run, replaying
    # Roundcube's CREATE TABLE script against an already-populated schema: not
    # destructive (the statements just fail) but it filled the log with MySQL
    # errors and made import_schema's own success line meaningless after the
    # first install.
    if [ ! -f "$dir/SQL/mysql.initial.sql" ]; then
      log_warn "Roundcube schema not imported (mysql.initial.sql not found)"
    elif [ -n "$(mysql -N -B -e "SHOW TABLES" roundcube 2>/dev/null)" ]; then
      log_info "Roundcube schema already present — not re-importing"
    else
      import_schema roundcube "$dir/SQL/mysql.initial.sql"
    fi

    # Remove Roundcube's web installer once deployment has succeeded.
    #
    # Third layer, not the only one: the rendered config sets
    # enable_installer=false, and apache-web.conf.tmpl already blocks
    # /roundcube/installer via DirectoryMatch. Deleting it is the layer that
    # survives a future mistake in either of those two -- a mis-rendered config
    # or an edited vhost cannot re-expose a directory that is not on disk.
    # Roundcube's own INSTALL guidance is to remove it on production.
    #
    # Runs LAST, after the schema import, because reaching this point means the
    # download, checksum and render steps all succeeded (each of those returns
    # early on failure). Idempotent: a re-run finds nothing to do.
    #
    # Deliberately NOT removed: SQL/ (import above needs it, and so do future
    # schema upgrades) and bin/ (installto.sh IS the upgrade path -- the
    # installer directory is not involved in upgrading).
    if [ -d "$dir/installer" ]; then
      rm -rf "$dir/installer" \
        && log_info "removed Roundcube web installer ($dir/installer)" \
        || log_warn "could not remove $dir/installer — check permissions"
    fi
  fi
}


deploy_postfixadmin
seed_postfixadmin
deploy_roundcube
if [ "$DRY_RUN" != 1 ]; then
  # apachectl is the same binary/symlink name on both platforms (confirmed
  # on a real 24.04 host: apache2-bin ships /usr/sbin/apachectl too).
  if apachectl configtest 2>/dev/null; then svc_reload "$WEB_SVC"
  else log_warn "apachectl configtest failed — NOT reloading $WEB_SVC (review $WEB_CONFD/)"; fi
fi

mark_done 50-web
log_info "web stack deployed (Roundcube webmail, PostfixAdmin)"
