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
MD_VAR_QUARANTINE_FOLDERS="$(printf '"%s" ' $QUARANTINE_FOLDERS)"        # bash array
export MD_VAR_QUARANTINE_FOLDERS
MD_VAR_QUARANTINE_FOLDERS_PHP="$(printf "'%s', " $QUARANTINE_FOLDERS | sed 's/, $//')"  # php array
export MD_VAR_QUARANTINE_FOLDERS_PHP

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

# Seed the on-demand IOC lookup services that need NO API key (HRBL,
# Mailspike, url.vet) as enabled -- once, only when no config exists yet, so
# a module re-run never overrides operator toggles made in Rendszer since.
# The keyed services stay off until their key arrives; keyless ones being
# off too just made a fresh console's IOC page show zero reputation columns
# for no discoverable reason. (Same seed in the app's install-console.sh for
# the add-to-existing-server path.)
if [ "$DRY_RUN" != 1 ] && [ ! -f /etc/ilexa/ioc_lookup.conf ]; then
  for _s in hrbl mailspike urlvet; do
    /usr/local/sbin/qa-ioclookup-config.sh enable "$_s" >/dev/null 2>&1 \
      && log_info "IOC lookup enabled by default (keyless): $_s" \
      || log_warn "could not enable IOC lookup '$_s' — enable it later in Rendszer"
  done
  unset _s
elif [ "$DRY_RUN" = 1 ]; then
  log_info "[dry-run] would enable keyless IOC lookups (hrbl mailspike urlvet) if unconfigured"
fi

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
  # Console UI language, seeded ONCE: the file is console-owned state
  # (Admin -> language rewrites it), so a module re-run must never reset an
  # operator's later choice. Bare language code, no newline -- qa_lang()
  # trims, qa_lang_set() writes the same shape.
  if [ ! -e /var/cache/quarantine-admin/language ]; then
    # SYSTEM_LANG is authoritative (it is what the operator answered);
    # ILEXA_LANG is only the older name for it, honoured for answers
    # files predating SYSTEM_LANG and for a standalone --only 55 run.
    # This file is the RUNTIME source of truth all three web apps read,
    # so seeding it from the wrong one would silently override the
    # chosen system language for Roundcube and PostfixAdmin too.
    _lang="${SYSTEM_LANG:-${ILEXA_LANG:-en}}"
    if [ ! -f "$SRC/lang/${_lang}.php" ]; then
      log_warn "no lang/${_lang}.php in the console bundle — seeding language 'en' instead"
      _lang=en
    fi
    printf '%s' "$_lang" > /var/cache/quarantine-admin/language
    chown "$WEB_USER:$WEB_GROUP" /var/cache/quarantine-admin/language
    chmod 644 /var/cache/quarantine-admin/language
    log_info "console language seeded: $_lang"
    unset _lang
  fi
  # Password-expiry master switch (Admin -> Jelszó-lejárati kényszerítés),
  # seeded ONCE from the same PASSWORD_EXPIRY_DAYS answer that already drives
  # PASSWORD_EXPIRATION_ENABLED (deploy_postfixadmin(), modules/50-web.sh) and
  # seed_postfixadmin()'s per-domain days -- same on/off decision, expressed
  # a third time because it also has to reach two things outside PHP's own
  # config system: the Roundcube password_expiry plugin and the
  # qa-password-expiry-notify.php cron job, both of which read this exact
  # file directly, not a PostfixAdmin or ilexa setting. Console-owned state
  # afterwards (Admin tab rewrites it), so seeded once, same discipline as
  # the language file just above -- a module re-run must never reset an
  # operator's later choice made through the console.
  if [ ! -e /var/cache/quarantine-admin/password_expiry_enabled ]; then
    if [ "${PASSWORD_EXPIRY_DAYS:-90}" = never ]; then _pwx=0; else _pwx=1; fi
    printf '%s' "$_pwx" > /var/cache/quarantine-admin/password_expiry_enabled
    chown "$WEB_USER:$WEB_GROUP" /var/cache/quarantine-admin/password_expiry_enabled
    chmod 644 /var/cache/quarantine-admin/password_expiry_enabled
    log_info "password-expiry enforcement seeded: $([ "$_pwx" = 1 ] && echo enabled || echo disabled)"
    unset _pwx
  fi
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
  # Column-scoped on purpose: `password` is deliberately NOT in this list, so
  # the console's read-only account can never read a password hash even if the
  # app is compromised. The named columns are exactly what the console reads --
  # admin_pwexpiry_coverage() (src/admin.php: domain, email_other, active) and
  # the sign-in check (src/signin.php: username, active), plus password_expiry
  # and modified for the expiry reporting.
  #
  # Without this the console is BROKEN ON EVERY FRESH INSTALL: the Rendszer
  # page dies with "1142 SELECT command denied ... for table postfix.mailbox"
  # and 55-ilexa fails its own smoke test (admin-runtime). It went unnoticed
  # because the reference host was granted this by hand long ago, so only a
  # genuinely fresh install ever hits it -- first seen 2026-08-26 on a clean
  # Ubuntu 24.04 box.
  db_exec "GRANT SELECT (username, domain, active, email_other, password_expiry, modified) ON postfix.mailbox TO 'qaudit_ro'@'localhost';"
  # The migration ledger must EXIST before it can be granted on: MariaDB
  # refuses "GRANT ... ON postfix.schema_migrations" with ERROR 1146 when the
  # table is absent, and db_exec would abort the module (verified on MariaDB
  # 10.11, fresh Ubuntu 24.04). Creating it here also resolves the same
  # chicken-and-egg the reference host hit by hand: a table-level grant cannot
  # authorise CREATE TABLE for a table that does not exist yet, so the
  # migration user can never bootstrap its own ledger.
  #
  # Definition is kept byte-identical to migration_ensure_ledger_table() in the
  # app's src/migrate.php -- CREATE TABLE IF NOT EXISTS, so whichever of the two
  # runs first wins and the other is a no-op.
  db_exec "CREATE TABLE IF NOT EXISTS postfix.schema_migrations (
             id INT UNSIGNED NOT NULL PRIMARY KEY,
             applied_at BIGINT UNSIGNED NOT NULL,
             checksum CHAR(64) NOT NULL,
             duration_ms INT UNSIGNED,
             applied_by VARCHAR(64) NOT NULL DEFAULT ''
           ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
  # Read-only view of that ledger so the console can render migration status
  # without a sudo round-trip. Same omission as the mailbox grant above: added
  # by hand on the reference host when the migration framework shipped.
  db_exec "GRANT SELECT ON postfix.schema_migrations TO 'qaudit_ro'@'localhost';"
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
    # Hard failure, not a warning: with no webroot there IS no console --
    # every remaining line of this module (crons, logrotate, helpers) dresses
    # up a corpse, and the old behaviour then logged "done — console at
    # <url>" and marked the module complete. A finished install with nothing
    # at /ilexa/ was the observed result (24.04 redeploy, 2026-08-21, where a
    # lint-gate bug in the bundle made deploy.sh refuse). Dying here leaves
    # the marker unset, so a re-run after fixing the cause redeploys cleanly.
    die "ilexa console deploy failed (see the lines above) — fix the cause and re-run: ./deploy.sh --only 55-ilexa"
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

# ---- GeoIP country lookups (archive/audit flags, sender_cc) ----------------
# mmdblookup binary: EL ships it in libmaxminddb, Debian/Ubuntu in mmdb-bin.
# The database itself comes from qa-geoipdb-refresh.sh (db-ip lite, keyless,
# fresh monthly -- EL's geolite2-country package is a frozen 2019 snapshot
# and Ubuntu packages no GeoLite2 mmdb at all). Without this stack every
# sender-country flag silently never renders and sender_cc stays NULL.
if [ "$PKG_MGR" = apt ]; then pkg_install mmdb-bin; else pkg_install libmaxminddb; fi

# The sqlite3 BINARY, not just PHP's driver. The console reads iocs.db and
# logins.db through PDO, so nothing here needs the CLI -- but qa-update-apply.sh
# shells out to `sqlite3 ... ".backup"` to snapshot them before an update, and
# its preflight refuses to run without it. Every fresh install therefore failed
# one-click updates with ERR_PREFLIGHT_BIN_sqlite3, while the reference host
# happened to have the package pulled in by something else. Same package on
# both families.
pkg_install sqlite3

# jq, for the same reason: a console feature depends on it and nothing was
# making sure it existed. qa-ioc-lookup.sh parses every reputation API's
# response with jq, but the only pkg_install jq in the tree is in 70-otx.sh --
# which exits three lines EARLIER when ENABLE_OTX=no, the default in the
# acceptance profile. On the box this was found on, jq was present purely as a
# transitive dependency of fwupd and prometheus-node-exporter-collectors
# (apt-mark showmanual does not list it), so every IOC reputation lookup was one
# unrelated package removal away from failing. Install it where the feature that
# needs it is installed.
pkg_install jq
if [ "$DRY_RUN" != 1 ] && [ ! -e /usr/share/GeoIP/GeoLite2-Country.mmdb ]; then
  /usr/local/sbin/qa-geoipdb-refresh.sh \
    && log_info "GeoIP country database installed (db-ip lite)" \
    || log_warn "GeoIP database fetch failed — country flags stay empty until the monthly cron succeeds"
fi

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
  # Skipped entirely when expiry is disabled: PostfixAdmin's own +0-days
  # computation for "never" would leave every password_expiry sitting in the
  # past, which never lands in a future 7/3/1-day window anyway (harmless),
  # but there is no reason to run a daily DB sweep for a feature the operator
  # explicitly turned off.
  [ "${PASSWORD_EXPIRY_DAYS:-90}" != never ] && \
    echo "0 6 * * * root /usr/local/sbin/qa-password-expiry-notify.php >> /var/log/qa-password-expiry-notify.log 2>&1"
  # GeoIP country DB (db-ip lite, monthly re-publish): feeds the archive/audit
  # country flags and archive_index.sender_cc. Day 2, after db-ip publishes.
  echo "20 3 2 * * root SOFT_FAIL_RC=75 /usr/bin/cron-alert.sh geoipdb /usr/local/sbin/qa-geoipdb-refresh.sh >> /var/log/qa-geoipdb.log 2>&1"
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

# ---- alert destination -----------------------------------------------------
# Seed /etc/ilexa/alerts.conf from ALERT_EMAIL. cron-alert.sh reads this file
# to decide where scheduled-job failures go, and every cron this toolkit
# installs is wrapped in it.
#
# Before this existed the file was created ONLY by the console's Admin tab, so
# a fresh install discarded every alert until an operator happened to find
# that setting -- which nobody does before the first failure they needed to
# hear about. Confirmed on a real deployment: no alerts.conf, therefore silent
# feed-failure, SIEM-health and neural-training alerts.
#
# Seed-only: if the file already exists the console owns it and a re-run must
# not overwrite the operator's choice (including a deliberate "off").
if [ "$DRY_RUN" != 1 ]; then
  # Validate before writing: this value is handed to mail(1) as a recipient
  # argument by cron-alert.sh, and deploy.sh does not check it. The console's
  # own helper (qa-alerts-config.sh) enforces exactly this shape for exactly
  # this reason; an option-shaped or typo'd value written here would otherwise
  # persist forever, because the seed is deliberately one-shot.
  if [ -n "${ALERT_EMAIL:-}" ] \
     && ! printf '%s' "$ALERT_EMAIL" | grep -qE '^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'; then
    log_warn "ALERT_EMAIL is not a valid address ('$ALERT_EMAIL') — not seeding alerts.conf; set it in the console (Admin tab)"
    ALERT_EMAIL=""
  fi
  if [ -n "${ALERT_EMAIL:-}" ] && [ ! -e /etc/ilexa/alerts.conf ]; then
    install -d -m 755 /etc/ilexa
    printf '# Destination for scheduled-job alerts (cron-alert.sh).\n# Seeded by the installer from ALERT_EMAIL; the console Admin tab owns it now.\n%s\n' \
      "$ALERT_EMAIL" > /etc/ilexa/alerts.conf
    chmod 644 /etc/ilexa/alerts.conf
    log_info "alert destination seeded: $ALERT_EMAIL"
  elif [ -e /etc/ilexa/alerts.conf ]; then
    log_info "alert destination already configured — left as is"
  else
    log_warn "ALERT_EMAIL empty — scheduled-job alerts will be discarded until an address is set in the console (Admin tab)"
  fi
fi

# Brand-guard review. Runs as ROOT (reads /var/log/rspamd). Mails only when a
# sender was tagged SOLELY because of the brand guard -- the shape a false
# positive takes -- so a clean day is silent. 06:15 is after the midnight log
# rotation; the script reads the rotated file and the live one together.
write_file /etc/cron.d/qa-brand-review 0644 root:root <<'EOF'
MAILTO=""
15 6 * * * root /usr/bin/cron-alert.sh qa-brand-review /usr/local/sbin/qa-brand-review.sh
EOF

# rspamd neural training progress. Runs as ROOT (reads redis directly, no
# message content). Exists because the neural module fails SILENTLY: when it
# never reaches its training threshold -- or when a symbol-set change resets
# its vectors, which happens whenever this project ships a new symbol -- the
# only visible effect is that NEURAL_* never fires, which looks identical to
# "installed and quiet". The reference host sat that way for two weeks. See
# the header of local.d/neural.conf.
write_file /etc/cron.d/qa-neural-snapshot 0644 root:root <<'EOF'
MAILTO=""
# rc=10 (first-ever training) and rc=11 (weekly shadow-mode reminder) are the
# script's own delivery mechanism, not failures -- see qa-neural-snapshot.sh's
# own comment at those exit points. INFO_RC tells cron-alert.sh to still mail
# every occurrence (unlike SOFT_FAIL_RC, never suppressed or streak-tracked)
# but label it "NOTICE", not "FAILED": without this, a healthy weekly nag
# reads as a production outage.
INFO_RC="10,11"
41 5 * * * root /usr/bin/cron-alert.sh qa-neural-snapshot /usr/local/sbin/qa-neural-snapshot.sh
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

# Login-anomaly ingestion sweep (see plans/zany-napping-sunrise.md). First
# sub-hourly cron in this codebase, deliberately -- justified there:
# successful logins are frequent enough that the daily/weekly cadence every
# other job here uses would make "new sign-in" detection close to useless.
# Same cron-alert.sh + CRON_ALERT_STATE_DIR + SOFT_FAIL_RC reasoning as
# qa-feed-sample immediately above (apache cannot write /run either).
write_file /etc/cron.d/qa-signin-monitor 0644 root:root <<EOF
MAILTO=root
CRON_ALERT_STATE_DIR=/var/cache/quarantine-admin
SOFT_FAIL_RC=1
*/5 * * * * ${WEB_USER} /usr/bin/cron-alert.sh qa-signin-monitor /usr/local/sbin/qa-signin-monitor.php
EOF

# ---- self-update provisioning ----------------------------------------------
# NONE of this was installed before 2026-08-26, so the one-click self-update
# feature had never worked on any host except the reference machine, where it
# was assembled by hand while being built. A fresh install shipped the helper
# scripts and the sudoers grant, then failed at the first step:
# qa-update-check.sh returned ERR_NO_PUBKEY and the console's version tile read
# "check failed" forever. Found on a clean 24.04 box while preparing a rollback
# drill -- the drill could not even start.
if [ "$DRY_RUN" != 1 ]; then
  # 1. Pinned release-signing keys. Verification is fail-closed, so an absent
  #    key does not degrade to "unsigned but working" -- it stops everything.
  install -d -m 755 /etc/ilexa
  if [ -r "$MD_ROOT/assets/ilexa/update-release.pub" ]; then
    install -m 644 "$MD_ROOT/assets/ilexa/update-release.pub" /etc/ilexa/update-release.pub
    log_info "release-signing public key(s) installed"
  else
    log_warn "assets/ilexa/update-release.pub missing — one-click updates will not work on this host"
  fi

  # 2. State tree. staging/ and rollback/ are created by the apply script, but
  #    installed.json must exist before the first run so the console has a
  #    version record to show, and last-tmpl/ must exist for the
  #    ERR_TMPL_CHANGED comparison to have a baseline.
  install -d -m 755 /var/lib/ilexa/update /var/lib/ilexa/update/staging \
                    /var/lib/ilexa/update/rollback /var/lib/ilexa/update/last-tmpl
  for f in "$SRC"/install/*.tmpl; do
    [ -e "$f" ] && install -m 644 "$f" "/var/lib/ilexa/update/last-tmpl/$(basename "$f")"
  done
  if [ ! -f /var/lib/ilexa/update/installed.json ]; then
    write_file /var/lib/ilexa/update/installed.json 0644 root:root <<JSON
{
    "version": "$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)",
    "codename": "$(tr -d '[:space:]' < "$SRC/CODENAME" 2>/dev/null || echo '')",
    "commit": "installer",
    "applied_at": $(date +%s),
    "applied_by": "installer",
    "method": "installer",
    "previous_version": "",
    "source_url": "",
    "sha256": "",
    "manifest_serial": 0
}
JSON
  fi

  # 3. Migration credential. DDL-capable but scoped to the two console-owned
  #    tables; deliberately NOT readable by the web user -- only the root-run
  #    apply script and qa-db-migrate.php ever use it.
  MIG_PASS="${ILEXA_MIG_PASS:-$(gen_pw 24)}"
  save_secret ILEXA_MIG_PASS "$MIG_PASS"
  db_exec "CREATE USER IF NOT EXISTS 'ilexa_mig'@'localhost' IDENTIFIED BY '$MIG_PASS';"
  db_exec "GRANT ALTER, CREATE, DROP, INDEX, SELECT, INSERT, UPDATE, DELETE ON postfix.archive_index TO 'ilexa_mig'@'localhost';"
  db_exec "GRANT ALL ON postfix.schema_migrations TO 'ilexa_mig'@'localhost';"
  # Scratch databases for the migration dry-run, which builds and drops a
  # structure-only shadow of the console tables before touching the real ones.
  db_exec "GRANT CREATE, DROP, ALTER, SELECT, INSERT ON \`ilexa\_migtest\_%\`.* TO 'ilexa_mig'@'localhost';"
  db_exec "FLUSH PRIVILEGES;"
  install -d -m 700 /etc/ilexa/secrets
  write_file /etc/ilexa/secrets/db-migrate.php 0600 root:root <<PHPCRED
<?php return ['socket' => '${MYSQL_SOCK:-/var/lib/mysql/mysql.sock}', 'db' => 'postfix',
              'user' => 'ilexa_mig', 'pass' => '${MIG_PASS}'];
PHPCRED
  log_info "migration credential provisioned (ilexa_mig, root-only)"
fi

# 4. Daily update check. Applying is ALWAYS a human one-click; this only
#    refreshes what the console displays. Runs as the web user because the
#    script needs no privilege at all, and wrapped in cron-alert.sh with
#    CRON_ALERT_STATE_DIR pointed at a directory that user can actually write
#    (see qa-feed-sample above for why /run silently suppresses alerting).
write_file /etc/cron.d/ilexa-update-check 0644 root:root <<EOF
MAILTO=root
CRON_ALERT_STATE_DIR=/var/cache/quarantine-admin
17 4 * * * ${WEB_USER} /usr/bin/cron-alert.sh ilexa-update-check /usr/local/sbin/qa-update-check.sh --cron
EOF

mark_done 55-ilexa
log_info "55-ilexa done — console at https://${MAIL_FQDN}${ILEXA_URL_PREFIX}"
