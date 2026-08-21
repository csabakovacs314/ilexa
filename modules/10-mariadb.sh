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

mark_done 10-mariadb
log_info "mariadb + app databases ready"
