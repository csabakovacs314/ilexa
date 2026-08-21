#!/usr/bin/env bash
# lib/db.sh — MariaDB helpers. Assumes local root socket auth (EL9 default),
# i.e. `mysql` run as system root connects without a password.
# All mutating helpers honour DRY_RUN.

# run a SQL statement as root
db_exec() { # sql [database]
  # The optional 2nd arg selects a database. Without it, statements that are not
  # fully qualified fail with "No database selected".
  if [ "${DRY_RUN:-0}" = 1 ]; then log_info "[dry-run] SQL${2:+ [$2]}: $1"; return 0; fi
  if [ -n "${2:-}" ]; then
    mysql --batch --skip-column-names --database="$2" -e "$1"
  else
    mysql --batch --skip-column-names -e "$1"
  fi
}

db_exists() { # dbname -> 0 if present
  local n
  n=$(mysql --batch --skip-column-names \
        -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1';" 2>/dev/null)
  [ -n "$n" ]
}

# create_db NAME
create_db() {
  local db="$1"
  if db_exists "$db"; then log_info "db '$db' already exists"; return 0; fi
  db_exec "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  log_info "created db '$db'"
}

# create_user_grant DB USER PASSWORD  — localhost-only, privileges on that DB
create_user_grant() {
  local db="$1" user="$2" pw="$3"
  db_exec "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pw}';"
  db_exec "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pw}';"
  db_exec "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';"
  db_exec "FLUSH PRIVILEGES;"
  log_info "granted '${user}'@'localhost' on '${db}'"
}

# import_schema DB SQLFILE  — idempotent-ish: caller guards with markers
import_schema() {
  local db="$1" file="$2"
  [ -r "$file" ] || die "schema file not found: $file"
  if [ "${DRY_RUN:-0}" = 1 ]; then log_info "[dry-run] would import $file into $db"; return 0; fi
  mysql "$db" < "$file"
  log_info "imported schema $file into $db"
}

# provision DB+user in one shot, generating a password, recording it to the
# human credentials file AND saving <KEYPREFIX>_USER/<KEYPREFIX>_PASS as
# cross-module secrets. Idempotent: reuses an already-saved password.
# Usage: provision_app_db postfix postfix POSTFIX_DB
provision_app_db() { # db user keyprefix
  local db="$1" user="$2" key="$3" pw
  load_secrets
  local pvar="${key}_PASS"
  if [ -n "${!pvar:-}" ]; then
    pw="${!pvar}"; log_info "reusing saved password for '$db'"
  else
    pw=$(gen_pw 28)
  fi
  create_db "$db"
  create_user_grant "$db" "$user" "$pw"
  # 3-arg form (label, user, secret) -- the 2-arg call this used to make put
  # the password in the "user" column, so the credentials file showed it on the
  # label line with no user field. Not lost, but the odd one out among five
  # call sites and exactly the shape record_cred's own header warns about.
  record_cred "db:${db}" "$user" "$pw"
  save_secret "${key}_USER" "$user"
  save_secret "${key}_PASS" "$pw"
}
