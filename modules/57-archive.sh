#!/usr/bin/env bash
# 57-archive — central mail archive (optional, off by default).
#
# Postfix always_bcc puts a copy of EVERY message -- inbound, outbound, spam and
# ham, for every user of every hosted domain -- into one mailbox that
# administrators can read from the ilexa Archive tab. That is a deliberate
# decision with legal weight, not a convenience feature, so it is opt-in and the
# operator is shown what it means before it is switched on.
#
# Delivery is unaffected: the copy is additive and never a hold.
# Rollback: postconf -e 'always_bcc=' && systemctl reload postfix
source "$MD_ROOT/lib/common.sh"
# Same missing source as 55-ilexa had: every db_exec below (the archive
# mailbox row, the always_bcc alias, and the qarchive_rw role) needs db.sh,
# and modules do not share a shell with 10-mariadb. Without it the whole
# central archive silently did nothing while the module still reported done.
source "$MD_ROOT/lib/db.sh"
load_secrets
step_guard 57-archive || exit 0

if [ "${ENABLE_ARCHIVE:-no}" != yes ]; then
  log_info "central archive disabled (ENABLE_ARCHIVE=no) — skipping"
  mark_done 57-archive; exit 0
fi

WEB_USER="${WEB_USER:-apache}"
RET="${ARCHIVE_RETENTION_DAYS:-30}"

log_warn "central archive ENABLED: every message of every user is copied to ${ARCHIVE_USER} and kept ${RET} days"
log_warn "  inform your users and record a lawful basis for this processing"

# ---- the archive mailbox ---------------------------------------------------
# A real mailbox with a random, unusable password: it must receive mail and be
# readable with doveadm -u, but nobody should be able to log into it.
if [ "$DRY_RUN" != 1 ]; then
  arch_local="${ARCHIVE_USER%@*}"; arch_dom="${ARCHIVE_USER#*@}"
  ARCHIVE_MB_PASS="${ARCHIVE_MB_PASS:-$(gen_pw 32)}"
  save_secret ARCHIVE_MB_PASS "$ARCHIVE_MB_PASS"
  hash=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ARCHIVE_MB_PASS" 2>/dev/null) \
    || { log_warn "cannot hash the archive mailbox password — skipping archive"; mark_done 57-archive; exit 0; }

  db_exec "INSERT INTO mailbox (username,password,name,maildir,quota,local_part,domain,created,modified,active)
           VALUES ('$ARCHIVE_USER','$hash','ilexa archive','${arch_dom}/${ARCHIVE_USER}/',0,'$arch_local','$arch_dom',NOW(),NOW(),1)
           ON DUPLICATE KEY UPDATE active=1,modified=NOW();" postfix \
    && log_info "archive mailbox: $ARCHIVE_USER" || log_warn "archive mailbox insert failed"
  # Self-alias, matching how PostfixAdmin represents a mailbox.
  db_exec "INSERT INTO alias (address,goto,domain,created,modified,active)
           VALUES ('$ARCHIVE_USER','$ARCHIVE_USER','$arch_dom',NOW(),NOW(),1)
           ON DUPLICATE KEY UPDATE goto='$ARCHIVE_USER',active=1,modified=NOW();" postfix
fi

# ---- indexer credentials (read-write; separate from the console's read-only) 
if [ "$DRY_RUN" != 1 ]; then
  ARCH_DB_PASS="${QARCHIVE_DB_PASS:-$(gen_pw 24)}"
  save_secret QARCHIVE_DB_PASS "$ARCH_DB_PASS"
  db_exec "CREATE USER IF NOT EXISTS 'qarchive_rw'@'localhost' IDENTIFIED BY '$ARCH_DB_PASS';"
  db_exec "GRANT SELECT,INSERT,UPDATE,DELETE ON postfix.archive_index TO 'qarchive_rw'@'localhost';"
  db_exec "FLUSH PRIVILEGES;"
  install -d -m 0700 -o root -g root /etc/quarantine-admin
  write_file /etc/quarantine-admin/indexer-db.php 0600 root:root <<EOF
<?php return ['socket' => '${MYSQL_SOCK:-/var/lib/mysql/mysql.sock}', 'db' => 'postfix',
              'user' => 'qarchive_rw', 'pass' => '${ARCH_DB_PASS}'];
EOF
fi

# ---- sender-country lookup (optional, degrades to "no flag") ---------------
# The indexer records the sending server's country so the console's Archívum
# page can show a flag beside each message. That needs mmdblookup (from
# libmaxminddb) AND a MaxMind GeoLite2 country database.
#
# The DATABASE IS DELIBERATELY NOT SHIPPED with this installer: MaxMind's
# licence does not permit redistributing GeoLite2, and it requires a free
# account plus a licence key to download. So install the reader, then say
# plainly whether the database is present -- geoip_cc() in the indexer treats
# a missing file as "unknown country" and stores NULL, which the console
# renders as an empty cell. The feature degrades to nothing rather than
# breaking the archive, but an operator who is never told will reasonably
# assume the flags are broken.
pkg_try libmaxminddb >/dev/null 2>&1 || pkg_try libmaxminddb0 >/dev/null 2>&1 || true
if [ "$DRY_RUN" != 1 ]; then
  if [ -r /usr/share/GeoIP/GeoLite2-Country.mmdb ]; then
    log_info "GeoLite2 country DB found — Archívum will show sender-country flags"
  else
    log_warn "no /usr/share/GeoIP/GeoLite2-Country.mmdb — the Archívum country column will stay EMPTY"
    log_warn "  to enable it: create a free MaxMind account, then either run geoipupdate with your"
    log_warn "  licence key or drop GeoLite2-Country.mmdb into /usr/share/GeoIP/ (0644 root:root)"
    log_warn "  then backfill existing rows with: archive-indexer.php --range=1:'*'"
  fi
fi

# ---- indexer + retention ---------------------------------------------------
export MD_VAR_ARCHIVE_USER="$ARCHIVE_USER"
export MD_VAR_ARCHIVE_RETENTION_DAYS="$RET"
render "$MD_ASSETS/ilexa/archive-indexer.php.tmpl"   /usr/local/bin/archive-indexer.php
render "$MD_ASSETS/ilexa/archive-retention.sh.tmpl"  /usr/local/bin/archive-retention.sh
[ "$DRY_RUN" = 1 ] || chmod 0755 /usr/local/bin/archive-indexer.php /usr/local/bin/archive-retention.sh

# ---- turn on the copy ------------------------------------------------------
# Last, so nothing is copied before there is somewhere to put it and something
# to index it.
if [ "$DRY_RUN" != 1 ]; then
  postconf -e "always_bcc = $ARCHIVE_USER"
  svc_reload postfix
  log_info "always_bcc = $ARCHIVE_USER (rollback: postconf -e 'always_bcc=' && systemctl reload postfix)"
fi

write_file /etc/cron.d/ilexa-archive 0644 root:root <<EOF
# Central archive: incremental index every 3 minutes, retention nightly.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would bypass
# the console's notification setting entirely. All alerting goes through
# cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays silent until an
# address is configured in the Admin tab.
MAILTO=""
*/3 * * * * root /usr/bin/php /usr/local/bin/archive-indexer.php >> /var/log/quarantine-admin/indexer.log 2>&1
15 3 * * *  root /usr/local/bin/archive-retention.sh >> /var/log/quarantine-admin/retention.log 2>&1
EOF

mark_done 57-archive
log_info "57-archive done (retention ${RET} days)"
