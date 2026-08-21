#!/usr/bin/env bash
# 55-ilexa — the ilexa console.
#
# Runs after 50-web (Apache/PHP) and 40-rspamd (the maps it manages). The app
# ships as a bundle produced by tools/bundle-ilexa.sh, so a fresh machine needs
# no access to the private app repository.
source "$MD_ROOT/lib/common.sh"
# db.sh provides db_exec(), used below to create the qaudit_ro role and the
# postfix.archive_index table. It was missing: every module runs in its own
# shell, so 10-mariadb sourcing db.sh does nothing for this one. The five
# db_exec calls therefore died with "command not found" on EVERY install --
# non-fatally, because the module carried on and still wrote
# /var/cache/quarantine-admin/db.php with credentials for a user that was
# never created. Confirmed on a real Ubuntu 24.04 install: after a full
# successful run, qaudit_ro and postfix.archive_index both did not exist, so
# the console's Archivum and Audit > Logins were broken from the start.
source "$MD_ROOT/lib/db.sh"
load_secrets
step_guard 55-ilexa || exit 0

if [ "${ENABLE_ILEXA:-yes}" != yes ]; then
  log_info "ilexa disabled (ENABLE_ILEXA=no) — skipping"
  mark_done 55-ilexa; exit 0
fi

WEB_USER="${WEB_USER:-apache}"
WEB_GROUP="${WEB_GROUP:-apache}"
WEB_CONFD="${WEB_CONFD:-/etc/httpd/conf.d}"
WEB_ETC="${WEB_CONFD%/*}"                          # /etc/httpd/conf.d -> /etc/httpd
WEB_LOG_DIR="${WEB_LOG_DIR:-/var/log/httpd}"
HTPASSWD_BIN="${HTPASSWD_BIN:-/usr/bin/htpasswd}"
# Single source of truth for the Basic Auth file: the vhost's AuthUserFile, the
# seeding logic below, and the console's htpasswd-manage.sh helper all take it
# from here. They used to be independent -- the helper hardcoded an EL-only
# path that also predated the quarantine-admin -> ilexa rename, so on a fresh
# install it edited a file Apache never read.
ILEXA_HTPASSWD="$WEB_ETC/ilexa.htpasswd"
SRC=/opt/ilexa-src
DST=/var/www/html/quarantine-admin
BUNDLE="$MD_ASSETS/ilexa-app.tar.gz"

# The app's templates live INSIDE the bundle, and --dry-run deliberately does
# not extract it, so $SRC/install/*.tmpl is absent on a dry run and render()
# would die with "template not found" -- breaking the preview that exists to be
# run before touching a host. Verify the template is present in the tarball
# instead, which is the same assurance without writing anything.
render_app() { # bundled-template-path dest
  local t="$1" d="$2" rel="${1#"$SRC"/}"
  if [ "$DRY_RUN" = 1 ]; then
    if tar tzf "$BUNDLE" 2>/dev/null | grep -qE "(^|/)${rel}\$"; then
      log_info "[dry-run] would render $rel (present in bundle) -> $d"
    else
      die "$rel is NOT in $BUNDLE -- rebuild it with tools/bundle-ilexa.sh"
    fi
    return 0
  fi
  render "$t" "$d"
}

# ---- unpack the application ------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
  [ -f "$BUNDLE" ] || die "ilexa bundle missing: $BUNDLE (run tools/bundle-ilexa.sh)"
  mkdir -p "$SRC"
  # --no-same-owner: the bundle is built on an EL host and carries apache's
  # NUMERIC uid/gid (48). Extracting as root would faithfully restore uid 48,
  # which on Debian/Ubuntu is not www-data (33) -- so every file landed
  # unreadable by the web server and the console returned "Permission denied"
  # for index.php itself. Ownership is set explicitly below instead of being
  # inherited from whichever machine happened to build the tarball.
  tar -xzf "$BUNDLE" -C "$SRC" --no-same-owner
  log_info "ilexa unpacked from bundle @ $(cat "$MD_ASSETS/ilexa-app.commit" 2>/dev/null || echo unknown)"
else
  log_info "[dry-run] would unpack $BUNDLE -> $SRC"
fi

# ---- render the two files that must agree ----------------------------------
# config.php and qa-doveadm.sh independently carry the archive mailbox and the
# folder allowlist. If they disagree the console looks fine and silently fails:
# the gateway refuses folders the UI offers. Both come from the same answers,
# and 99-verify re-checks that they still match.
export MD_VAR_MAIL_FQDN="$MAIL_FQDN"
export MD_VAR_TIMEZONE="${TIMEZONE:-UTC}"
export MD_VAR_ARCHIVE_USER="$ARCHIVE_USER"
export MD_VAR_POSTMASTER_FROM="postmaster@${PRIMARY_DOMAIN}"
export MD_VAR_ILEXA_URL_PREFIX="$ILEXA_URL_PREFIX"
export MD_VAR_ILEXA_HTPASSWD="$ILEXA_HTPASSWD"
export MD_VAR_HTPASSWD_BIN="$HTPASSWD_BIN"
export MD_VAR_RSPAMD_CTRL="$RSPAMD_CTRL"
export MD_VAR_MAIL_STORE="$MAIL_STORE"
export MD_VAR_WEB_LOG_DIR="$WEB_LOG_DIR"
# Sidebar shortcut target. Trailing slash: the Alias in
# templates/web/apache-web.conf.tmpl is "/postfixadmin" and Apache would
# redirect the slashless form anyway, so we ask for the canonical URL
# directly. Overridable (POSTFIXADMIN_URL='') for deployments that do not
# want the entry -- the console hides the menu item on an empty string
# rather than rendering a dead link.
export MD_VAR_POSTFIXADMIN_URL="${POSTFIXADMIN_URL-/postfixadmin/}"
# The same list in two syntaxes, from one answer, because config.php and
# qa-doveadm.sh both need it and disagreeing is a silent failure: the gateway
# refuses a folder the UI happily offers.
export MD_VAR_QUARANTINE_FOLDERS="$(printf '"%s" ' $QUARANTINE_FOLDERS)"        # bash array
export MD_VAR_QUARANTINE_FOLDERS_PHP="$(printf "'%s', " $QUARANTINE_FOLDERS | sed 's/, $//')"  # php array

render_app "$SRC/install/config.php.tmpl" "$SRC/config.php"

# ---- ownership: the web server must be able to READ its own application ----
# Done after config.php is rendered so the rendered file is covered too.
# Without this the whole tree stays root-owned (or uid 48 from the EL build
# host) and PHP-FPM, running as $WEB_USER, cannot open index.php at all --
# the browser shows a permission error that looks like a login failure but is
# not: Basic Auth has already succeeded by then. Verified on a real Ubuntu
# 24.04 install, where the log read "Unable to open primary script:
# .../index.php (Permission denied)".
#
# Group-readable, not world-readable: config.php holds the DB password.
if [ "$DRY_RUN" != 1 ]; then
  chown -R "$WEB_USER:$WEB_GROUP" "$SRC"
  find "$SRC" -type d -exec chmod 750 {} +
  find "$SRC" -type f -exec chmod 640 {} +
  # parse_email.py is executed by the console, not merely included.
  [ -f "$SRC/parse_email.py" ] && chmod 750 "$SRC/parse_email.py"
  log_info "ilexa tree owned by $WEB_USER:$WEB_GROUP (dirs 750, files 640)"
fi

# ---- host helper scripts ---------------------------------------------------
inst() { # src dst mode
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] install $2"; return 0; fi
  install -m "$3" -o root -g root "$1" "$2"
}
# Installed from the APP repo's install/ directory inside the extracted bundle,
# not from this installer's assets/. These are the console's own helpers; the app
# is their single source, the same rule already applied to install/*.tmpl.
#
# This repo used to keep its own copy of all 22 and they had drifted:
# feeds-status.sh here was missing the yara_forge entry the app repo gained, so
# on every host this installer built that feed showed "nincs adat" forever even
# after a successful refresh. Identical failure shape to the gateway losing
# hdr.received. One copy now, so it cannot recur.
#
# Not silently skipped when absent: a missing helper means a console panel that
# fails at runtime, so say so.
# Read from the app bundle's install/helpers.list -- the single source, also
# read by install-console.sh and verified against sudoers.example by the
# app's tools/check-helpers.php. This list was previously written out by
# hand here AND there, and drifted three times in one week; each drift
# shipped a panel or cron job calling a script no installer had placed.
# Only source=list entries: the templated helpers are rendered below.
for h in $(awk '$1 !~ /^#/ && NF >= 3 && $3 == "list" { print $1 }' "$SRC/install/helpers.list" 2>/dev/null); do
  if [ -f "$SRC/install/$h" ]; then
    inst "$SRC/install/$h" "/usr/local/sbin/$h" 0755
  elif [ "$DRY_RUN" = 1 ]; then
    tar tzf "$BUNDLE" 2>/dev/null | grep -qE "(^|/)install/${h}\$" \
      || log_warn "$h is not in the bundle — the console panel using it will fail"
  else
    log_warn "$h missing from $SRC/install — the console panel using it will fail"
  fi
done

# cron-alert.sh is a general-purpose "run this, journal it, mail on hard
# failure" wrapper -- not OTX-specific, even though it lives under
# assets/otx/ (its first, historical consumer). It must be installed here,
# unconditionally, rather than left to 70-otx's own (OTX-gated) copy of it:
# the qa-feed-sample cron below depends on it, and 70-otx.sh exits early
# without installing anything when ENABLE_OTX=no (e.g. the CI lab profile),
# which would leave that cron job silently calling a missing binary every
# hour. 70-otx.sh still installs its own copy too when OTX is enabled --
# redundant, not harmful, and left alone rather than risking that module.
inst "$MD_ASSETS/otx/cron-alert.sh" /usr/bin/cron-alert.sh 0755
# templated helpers
# These come from the APP repo's own install/ directory (inside the extracted
# bundle), not from this installer's assets/. The app is the single source for
# the helpers it shells out to, which is what lets it also be installed onto a
# stack this toolkit did not build -- see docs/standalone-console.md. Same
# convention sudoers.example already used.
render_app "$SRC/install/qa-doveadm.sh.tmpl"       /usr/local/sbin/qa-doveadm.sh
render_app "$SRC/install/htpasswd-manage.sh.tmpl"  /usr/local/sbin/htpasswd-manage.sh
render_app "$SRC/install/fts-manage.sh.tmpl"       /usr/local/sbin/fts-manage.sh
[ "$DRY_RUN" = 1 ] || chmod 0755 /usr/local/sbin/qa-doveadm.sh /usr/local/sbin/fts-manage.sh /usr/local/sbin/htpasswd-manage.sh

# ---- state directories -----------------------------------------------------
# cache must be WRITABLE by the web user: it holds the language file, the
# learning flag, roles.json and the status caches.
if [ "$DRY_RUN" != 1 ]; then
  install -d -m 0750 -o "$WEB_USER" -g "$WEB_GROUP" /var/log/quarantine-admin
  install -d -m 0700 -o "$WEB_USER" -g "$WEB_GROUP" /var/cache/quarantine-admin
  install -d -m 0755 -o "$WEB_USER" -g "$WEB_GROUP" "$ILEXA_LIST_DIR"
else
  log_info "[dry-run] would create /var/log|cache|lib quarantine-admin dirs"
fi

# ---- sudoers ---------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
  tmp=$(mktemp)
  sed "s/^apache /${WEB_USER} /" "$SRC/install/sudoers.example" > "$tmp"
  if visudo -cqf "$tmp"; then
    install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/ilexa
    log_info "sudoers installed: /etc/sudoers.d/ilexa"
  else
    log_error "generated sudoers failed validation — NOT installed"
  fi
  rm -f "$tmp"
fi

# ---- Apache ----------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
  # Rendered from the app repo's install/apache-ilexa.conf.tmpl -- the same
  # template install-console.sh uses, so a console configured by either route
  # gets identical Apache config. The long explanations that used to live in
  # this heredoc (the DocumentRoot second-URL/CSRF trap in particular) moved
  # into the template along with the config itself.
  export MD_VAR_DOCROOT="$DST"
  MD_VAR_DOCROOT_BASE="$(basename "$DST")"; export MD_VAR_DOCROOT_BASE
  export MD_VAR_SITE_TITLE="${SITE_TITLE:-ilexa - Mail Security Operations Console}"
  export MD_VAR_PHP_FPM_SOCK="${PHP_FPM_SOCK:-/run/php-fpm/www.sock}"
  render_app "$SRC/install/apache-ilexa.conf.tmpl" "$WEB_CONFD/ilexa.conf"
  [ "$DRY_RUN" = 1 ] || chmod 0644 "$WEB_CONFD/ilexa.conf"
  # Debian's apache2 doesn't auto-glob conf-available/ the way EL's httpd
  # globs conf.d/ -- needs an explicit a2enconf symlink into conf-enabled/.
  [ "$PKG_MGR" = apt ] && a2enconf ilexa >/dev/null
  # Nothing else in this module (on any platform) ever reloads the web
  # server, so a fresh conf.d/ilexa.conf would otherwise sit unread by an
  # already-running httpd/apache2 until some unrelated later action
  # happened to reload it.
  if apachectl configtest 2>/dev/null; then svc_reload "${WEB_SVC:-httpd}"
  else log_warn "apachectl configtest failed — not reloading ${WEB_SVC:-httpd} (review $WEB_CONFD/ilexa.conf)"; fi
  # Adopt a pre-rename Basic Auth file rather than seeding a fresh one beside
  # it. Hosts installed before the quarantine-admin -> ilexa rename keep their
  # accounts in <WEB_ETC>/quarantine-admin.htpasswd (the reference host still
  # does). Without this, a re-run creates an empty-but-for-a-new-admin
  # ilexa.htpasswd, repoints the vhost at it, and every existing console
  # account stops working -- the file is orphaned rather than deleted, so it
  # is recoverable, but nobody would know why access broke.
  if [ ! -f "$ILEXA_HTPASSWD" ] && [ -s "$WEB_ETC/quarantine-admin.htpasswd" ] && [ "$DRY_RUN" != 1 ]; then
    cp -p "$WEB_ETC/quarantine-admin.htpasswd" "$ILEXA_HTPASSWD"
    chmod 640 "$ILEXA_HTPASSWD"; chgrp "$WEB_GROUP" "$ILEXA_HTPASSWD"
    log_info "migrated $WEB_ETC/quarantine-admin.htpasswd -> $ILEXA_HTPASSWD ($(grep -c : "$ILEXA_HTPASSWD") account(s) preserved; the old file is left in place, delete it once the console is confirmed working)"
  fi

  # First admin. Generated rather than prompted, and recorded with the rest.
  if [ ! -f "$ILEXA_HTPASSWD" ]; then
    ILEXA_ADMIN_PASSWORD="${ILEXA_ADMIN_PASSWORD:-$(gen_pw 20)}"
    # The htpasswd binary is a hard requirement, not a nice-to-have: without
    # this file the vhost's AuthUserFile points at nothing and the console is
    # unreachable for everyone. Its stderr used to go to /dev/null, so the
    # ONLY symptom was a one-line warning in a long install log with no
    # reason attached -- keep the real error and say what it costs.
    if ! htpasswd_err="$("$HTPASSWD_BIN" -cbB "$ILEXA_HTPASSWD" \
           "${ILEXA_ADMIN_USER:-admin}" "$ILEXA_ADMIN_PASSWORD" 2>&1)"; then
      log_error "could not create $ILEXA_HTPASSWD: ${htpasswd_err:-no output from $HTPASSWD_BIN}"
      log_error "the ilexa console will be UNREACHABLE until this is fixed (AuthUserFile missing)"
    else
      chmod 640 "$ILEXA_HTPASSWD"; chgrp "$WEB_GROUP" "$ILEXA_HTPASSWD"
      record_cred "ilexa console" "${ILEXA_ADMIN_USER:-admin}" "$ILEXA_ADMIN_PASSWORD"
      log_info "ilexa console admin created — credentials in $MD_CRED_FILE"
    fi
  fi
  # The Audit > Logins view greps the Apache access log as the web user.
  # $WEB_LOG_DIR is 0700 root, so without this ACL the view is silently empty.
  command -v setfacl >/dev/null && setfacl -m "u:${WEB_USER}:rx" "$WEB_LOG_DIR" 2>/dev/null \
    || log_warn "setfacl unavailable — Audit > Logins will be empty"
fi

# ---- database --------------------------------------------------------------
# Read-only role. The console never writes to the mail databases.
if [ "$DRY_RUN" != 1 ]; then
  QA_DB_PASS="${QAUDIT_DB_PASS:-$(gen_pw 24)}"
  save_secret QAUDIT_DB_PASS "$QA_DB_PASS"
  db_exec "CREATE USER IF NOT EXISTS 'qaudit_ro'@'localhost' IDENTIFIED BY '$QA_DB_PASS';"
  db_exec "CREATE TABLE IF NOT EXISTS postfix.archive_index (
             uid BIGINT UNSIGNED NOT NULL PRIMARY KEY, ts BIGINT NOT NULL,
             from_addr VARCHAR(320), to_addr VARCHAR(320), subject VARCHAR(998),
             rspamd_score FLOAT DEFAULT NULL, is_spam TINYINT(1) NOT NULL DEFAULT 0,
             indexed_at BIGINT UNSIGNED NOT NULL,
             learned_as ENUM('spam','ham') DEFAULT NULL, learned_at INT UNSIGNED DEFAULT NULL,
             sender_ip VARCHAR(45) DEFAULT NULL, sender_cc CHAR(2) DEFAULT NULL,
             INDEX(ts), INDEX(is_spam), INDEX(sender_cc)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
  # Upgrade path for hosts whose archive_index predates the country column.
  # CREATE TABLE IF NOT EXISTS does nothing on an existing table, so without
  # this an upgraded host keeps the old schema and the indexer's INSERT --
  # which now names sender_ip/sender_cc -- fails on EVERY message. IF NOT
  # EXISTS on ADD COLUMN makes this a no-op on a fresh install and on repeat
  # runs (MariaDB 10.0+; this stack requires far newer).
  db_exec "ALTER TABLE postfix.archive_index
             ADD COLUMN IF NOT EXISTS sender_ip VARCHAR(45) DEFAULT NULL,
             ADD COLUMN IF NOT EXISTS sender_cc CHAR(2) DEFAULT NULL,
             ADD INDEX IF NOT EXISTS idx_sender_cc (sender_cc);"
  db_exec "GRANT SELECT ON postfix.last_login TO 'qaudit_ro'@'localhost';"
  # Column-scoped, not table-wide: the app can flip which verdict an admin
  # already taught rspamd for a message (learned_as/learned_at), nothing else
  # -- subject/from/score/is_spam etc. stay read-only even to this user.
  db_exec "GRANT SELECT, UPDATE (learned_as, learned_at) ON postfix.archive_index TO 'qaudit_ro'@'localhost';"
  db_exec "FLUSH PRIVILEGES;"
  write_file /var/cache/quarantine-admin/db.php 0600 "${WEB_USER}:${WEB_GROUP}" <<EOF
<?php return ['socket' => '${MYSQL_SOCK:-/var/lib/mysql/mysql.sock}', 'db' => 'postfix',
              'user' => 'qaudit_ro', 'pass' => '${QA_DB_PASS}'];
EOF

  # ---- rspamd controller password for the console --------------------------
  # Spam/ham teaching shells out to `rspamc -P "$(cat <this file>)" learn_spam`.
  # config.php has always pointed at it, but NOTHING created it, so on every
  # fresh install teaching aborted with
  #   "ABORT live [learn_spam]: missing/unreadable .../rspamc.pw - not learned"
  # and the operator's spam never reached Bayes. 40-rspamd already generates the
  # plaintext and save_secret's it (the config gets only the rspamadm hash), so
  # this just hands the console the same value.
  #
  # Written only when we actually have it: an EMPTY file would pass the app's
  # is_readable() check and then authenticate with an empty password, turning a
  # clear "missing file" abort into a confusing 401 from the controller.
  if [ -n "${RSPAMD_CTRL_PW:-}" ]; then
    write_file /var/cache/quarantine-admin/rspamc.pw 0600 "${WEB_USER}:${WEB_GROUP}" <<EOF
${RSPAMD_CTRL_PW}
EOF
    log_info "rspamc controller password installed for the console"
  else
    log_warn "RSPAMD_CTRL_PW unknown (run 40-rspamd first) — spam/ham teaching will abort until /var/cache/quarantine-admin/rspamc.pw exists"
  fi
fi

# ---- deploy the application ------------------------------------------------
# Its own deploy.sh, never a bare rsync: it refuses to overwrite webroot-only
# work and fixes the ownership PHP-FPM needs.
#
# Invoked as `bash ./deploy.sh`, not `./deploy.sh`: the hardening pass above
# chmods every file in $SRC to 640, which strips deploy.sh's exec bit, so the
# direct form died with "Permission denied" (exit 126) on EVERY run. The old
# `>/dev/null 2>&1` then swallowed the reason and left only a vague warning,
# so the webroot silently kept whatever version it already had -- a fresh
# install shipped an un-deployed console and an upgrade appeared to do
# nothing. Keep the output: on failure its last lines are the diagnosis
# (drift refusal, unknown web user, ...), and they belong in the log.
if [ "$DRY_RUN" != 1 ]; then
  _ilexa_deploy_out=$(cd "$SRC" && bash ./deploy.sh 2>&1) && log_info "ilexa deployed to $DST" || {
    log_warn "ilexa deploy.sh failed — $DST was NOT updated"
    while IFS= read -r _l; do [ -n "$_l" ] && log_warn "  $_l"; done <<<"$_ilexa_deploy_out"
  }
  unset _ilexa_deploy_out _l
fi

# ---- logrotate + cron ------------------------------------------------------
write_file /etc/logrotate.d/ilexa 0644 root:root <<EOF
/var/log/quarantine-admin/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 ${WEB_USER} ${WEB_GROUP}
    su ${WEB_USER} ${WEB_GROUP}
}
EOF

# SIEM export's impstats output (qa-siem-config.sh, only written while SIEM
# export is enabled) -- copytruncate because rsyslog holds the file open for
# continuous appending via impstats' own log.file parameter, with no signal-
# based reopen configured for it the way the main journal/imfile paths have.
write_file /etc/logrotate.d/rsyslog-siem-stats 0644 root:root <<EOF
/var/log/rsyslog-siem-stats.json {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

{
  echo "# ilexa scheduled jobs."
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would
    # bypass the console's notification setting entirely. All alerting goes
    # through cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays
    # silent until an address is configured in the Admin tab.
    echo 'MAILTO=""'
  [ "${ENABLE_BREACH_CHECK:-no}" = yes ] && \
    echo "0 2 * * * root /usr/local/sbin/check-breaches.py >> /var/log/check-breaches.log 2>&1"
  echo "QA_DIGEST_TO=${ADMIN_EMAIL}"
  echo "0 7 * * 1 root /usr/local/sbin/qa-weekly-digest.php >> /var/log/qa-digest.log 2>&1"
} > /tmp/ilexa.cron.$$
write_file /etc/cron.d/ilexa 0644 root:root < /tmp/ilexa.cron.$$
rm -f /tmp/ilexa.cron.$$

# ---- additional per-feature cron jobs ---------------------------------------
# Each of these gets its OWN /etc/cron.d file (not folded into /etc/cron.d/ilexa
# above) because cron.d environment-variable assignments are file-scoped, not
# line-scoped: qa-feed-sample below needs CRON_ALERT_STATE_DIR/SOFT_FAIL_RC that
# must NOT leak onto qa-campaign-detect's or qa-ioc-expire's unrelated exit codes
# if they ever shared a file.
#
# qa-campaign-detect and qa-ioc-expire log to /var/log/quarantine-admin/ (created
# apache:apache above), NOT bare /var/log/*.log -- the reference deployment hit a
# real incident from exactly that: apache cannot create new files under bare
# /var/log (root:root 0755), so a `>> /var/log/x.log 2>&1` redirect on an
# apache-run job dies before the command ever executes while cron's own log still
# reports a clean exit. Using the directory this module already provisions
# apache-writable avoids reproducing that bug on a fresh install.
write_file /etc/cron.d/qa-campaign-detect 0644 root:root <<EOF
0 4 * * * ${WEB_USER} /usr/local/sbin/qa-campaign-detect.php >> /var/log/quarantine-admin/qa-campaign-detect.log 2>&1
EOF

write_file /etc/cron.d/qa-ioc-expire 0644 root:root <<EOF
0 3 * * * ${WEB_USER} /usr/local/sbin/qa-ioc-expire.php >> /var/log/quarantine-admin/qa-ioc-expire.log 2>&1
EOF

# SIEM export health check -- catches a config that "looks enabled" but has
# silently stopped delivering anything (a stuck omfwd action can sit in
# resume/retry backoff, or in some failure modes never even flip that flag,
# while the config itself and `rsyslogd -N1` both look completely fine).
# Runs unconditionally, same as the other cron.d files here -- the script
# itself reads /etc/ilexa/siem.conf and exits immediately, silently, when
# SIEM export is not enabled, so there is nothing to gate here.
write_file /etc/cron.d/qa-siem-healthcheck 0644 root:root <<EOF
MAILTO=""
*/15 * * * * root /usr/bin/cron-alert.sh qa-siem-healthcheck /usr/local/sbin/qa-siem-healthcheck.sh
EOF

write_file /etc/cron.d/qa-community-feed 0644 root:root <<EOF
0 5 * * * root /usr/local/sbin/qa-community-feed-loader.php >> /var/log/qa-community-feed.log 2>&1
EOF

write_file /etc/cron.d/update-rspamd-community-rules 0644 root:root <<EOF
2 4 * * * root /usr/local/sbin/update-rspamd-community-rules.sh >/dev/null 2>&1
EOF

# Hourly feed-count sampler for the Rendszer page's freshness/collapse table.
# See the comment inside the file this mirrors (the reference host's own
# /etc/cron.d/qa-feed-sample) for why SOFT_FAIL_RC + CRON_ALERT_STATE_DIR exist:
# apache cannot write cron-alert.sh's default streak-file location (/run), and
# an unwritable streak file suppresses alerting PERMANENTLY rather than merely
# throttling it, which is strictly worse than the hourly noise it exists to fix.
write_file /etc/cron.d/qa-feed-sample 0644 root:root <<EOF
# Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would bypass
# the console's notification setting entirely. All alerting goes through
# cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays silent until an
# address is configured in the Admin tab.
MAILTO=""
CRON_ALERT_STATE_DIR=/var/cache/quarantine-admin
SOFT_FAIL_RC=1
17 * * * * ${WEB_USER} /usr/bin/cron-alert.sh qa-feed-sample /usr/local/sbin/qa-feed-sample.php
EOF

mark_done 55-ilexa
log_info "55-ilexa done — console at https://${MAIL_FQDN}${ILEXA_URL_PREFIX}"
