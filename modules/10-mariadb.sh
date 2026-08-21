#!/usr/bin/env bash
# 10-mariadb — install MariaDB, harden, create app DBs + users.
source "$MD_ROOT/lib/common.sh"
source "$MD_ROOT/lib/db.sh"
step_guard 10-mariadb || exit 0

pkg_install mariadb-server
svc_enable "${MYSQL_SVC:-mariadb}"

# localhost-only bind + larger buffer pool (matches reference box).
# Path is OS-dependent: EL reads /etc/my.cnf.d, Debian/Ubuntu only
# !includedir's /etc/mysql/conf.d and /etc/mysql/mariadb.conf.d. This was
# hardcoded to the EL path, so on Ubuntu the file was written to a directory
# that exists but is never read -- innodb_buffer_pool_size silently stayed at
# the 128M default (verified live on the 24.04 box). bind-address happened to
# be right anyway there, but only because Debian's own default already is
# 127.0.0.1, not because this file applied.
write_file "${MYSQL_CONFD:-/etc/my.cnf.d}/99-mail.cnf" 644 <<'EOF'
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = 512M
EOF
svc_reload "${MYSQL_SVC:-mariadb}"

# mysql_secure_installation equivalent: drop anonymous users + the test DB
# (version-safe IF EXISTS; usually a no-op on fresh EL9 MariaDB, but explicit).
if [ "$DRY_RUN" != 1 ]; then
  db_exec "DROP USER IF EXISTS ''@'localhost';" 2>/dev/null || true
  db_exec "DROP USER IF EXISTS ''@'$(hostname)';" 2>/dev/null || true
  db_exec "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
  db_exec "DELETE FROM mysql.db WHERE Db IN ('test','test\\_%');" 2>/dev/null || true
  db_exec "FLUSH PRIVILEGES;" 2>/dev/null || true
  log_info "removed anonymous users + test database (if any)"
fi

# app databases + dedicated localhost users (passwords auto-generated + saved)
provision_app_db postfix     postfix     POSTFIX_DB
provision_app_db roundcube   roundcube   ROUNDCUBE_DB

# Read-only user for the Postfix SQL maps (20-postfix renders them with these
# credentials). Separate from the read-write 'postfix' user PostfixAdmin uses:
# the map files are readable by the postfix group, so a leak of THOSE
# credentials must not grant write access to the mail DB. Created here without
# grants -- the column-level SELECT grants need the PostfixAdmin schema, which
# does not exist until 50-web runs upgrade.php, so 50-web applies them.
# Nothing consumes the maps before 90-enable starts services, so the window in
# which the user exists ungranted is harmless. Both host forms: the maps use
# hosts=127.0.0.1 (TCP), and @'localhost' alone only matches that while
# name resolution is on.
if [ "$DRY_RUN" != 1 ]; then
  POSTFIX_MAPS_PASS="${POSTFIX_MAPS_PASS:-$(gen_pw 24)}"
  save_secret POSTFIX_MAPS_PASS "$POSTFIX_MAPS_PASS"
  for _h in localhost 127.0.0.1; do
    db_exec "CREATE USER IF NOT EXISTS 'postfix_maps'@'${_h}' IDENTIFIED BY '${POSTFIX_MAPS_PASS}';"
    db_exec "ALTER USER 'postfix_maps'@'${_h}' IDENTIFIED BY '${POSTFIX_MAPS_PASS}';"
  done
  log_info "read-only maps user 'postfix_maps' created (grants applied by 50-web after the schema exists)"
else
  log_info "[dry-run] would create read-only maps user 'postfix_maps'"
fi

mark_done 10-mariadb
log_info "mariadb + app databases ready"
