#!/usr/bin/env bash
# 20-postfix — Postfix MTA: virtual domains (MySQL), postscreen, TLS, milters.
source "$MD_ROOT/lib/common.sh"
step_guard 20-postfix || exit 0
load_secrets   # POSTFIX_DB_USER / POSTFIX_DB_PASS from 10-mariadb

# postfix-mysql is the same package name on both platforms (confirmed:
# Debian ships its own postfix-mysql providing dict_mysql, not just an EL
# thing). The SPF policy daemon package genuinely differs -- EL's
# pypolicyd-spf creates its own dedicated system user and installs to
# /usr/libexec/postfix/; Debian's postfix-policyd-spf-python runs as
# "nobody" from /usr/bin/ (its own packaged master.cf snippet uses exactly
# this stanza).
if [ "$PKG_MGR" = apt ]; then
  # postfix-pcre is NOT optional here: EL builds PCRE map support into postfix
  # itself, Debian splits it into this package. main.cf.tmpl uses
  # "header_checks = pcre:/etc/postfix/header_checks", and without the package
  # postconf -m lists no pcre at all, so EVERY message fails in cleanup with
  # "unsupported dictionary type: pcre" -> "queue file write error" and is
  # refused. Observed on the Ubuntu 24.04 test host: the server accepted
  # nothing from the moment it was installed, with 410 messages piled up in
  # the queue and no obvious symptom beyond a warning in mail.log.
  pkg_install postfix postfix-mysql postfix-pcre postfix-policyd-spf-python
  POLICYD_SPF_USER=nobody
  POLICYD_SPF_BIN=/usr/bin/policyd-spf
else
  pkg_install postfix postfix-mysql pypolicyd-spf
  POLICYD_SPF_USER=policyd-spf
  POLICYD_SPF_BIN=/usr/libexec/postfix/policyd-spf
fi

# add postfix to mtagroup (shared access to the clamd socket)
[ "$DRY_RUN" != 1 ] && getent group mtagroup >/dev/null && gpasswd -a postfix mtagroup >/dev/null 2>&1 || true

# --- render main.cf / master.cf ---
# virtual_uid_maps/virtual_gid_maps/virtual_minimum_uid were hardcoded to 89
# (EL's postfix uid). Resolve the real one -- see mail_owner_ids() in
# lib/common.sh for why assuming it breaks Debian outright.
mail_owner_ids
setvar MAIL_UID "$MAIL_UID"
setvar MAIL_GID "$MAIL_GID"
setvar POLICYD_SPF_USER "$POLICYD_SPF_USER"
setvar POLICYD_SPF_BIN "$POLICYD_SPF_BIN"
for k in PRIMARY_DOMAIN MAIL_FQDN MAIL_STORE MESSAGE_SIZE_LIMIT SMTPD_DELAY_REJECT SENDER_LOGIN_GUARD RSPAMD_MILTER \
         POSTSCREEN_DNSBL_SITES TLS_CERT TLS_KEY TLS_CAFILE INET_PROTOCOLS MYNETWORKS QUOTA_POLICY; do
  setvar "$k" "${!k}"
done
# always_bcc belongs to 57-archive.sh (central mail archive), which sets it
# with postconf -e AFTER this module runs. main.cf is rendered whole here, so
# a re-run of THIS module silently drops it and archiving stops -- every
# message stops being copied to the archive mailbox, with nothing to notice.
# Observed twice on the reference host on 2026-08-17. Capture it before the
# render and put it back after; same "don't destroy what you don't own" rule
# as the rbl.d and multimap.d splits.
#
# The milters (40-rspamd) do NOT need this: they are in the template already.
_prev_always_bcc=""
[ "$DRY_RUN" = 1 ] || _prev_always_bcc="$(postconf -h always_bcc 2>/dev/null)"

render "$MD_TEMPLATES/postfix/main.cf.tmpl"   /etc/postfix/main.cf

if [ "$DRY_RUN" != 1 ] && [ -n "$_prev_always_bcc" ]; then
  postconf -e "always_bcc = $_prev_always_bcc"
  log_info "preserved always_bcc = $_prev_always_bcc across the main.cf render (owned by 57-archive)"
fi
render "$MD_TEMPLATES/postfix/master.cf.tmpl" /etc/postfix/master.cf

# --- MySQL virtual maps (dedicated postfix DB user, never root) ---
write_sql_map() { # filename  query
  write_file "/etc/postfix/sql/$1" 640 "root:postfix" <<EOF
# $1 — rendered by mail-deploy
user = ${POSTFIX_DB_USER:-postfix}
password = ${POSTFIX_DB_PASS:-CHANGEME}
hosts = 127.0.0.1
dbname = postfix
query = $2
EOF
}
write_sql_map mysql_virtual_domains_maps.cf \
  "SELECT domain FROM domain WHERE domain='%s' AND active='1'"
write_sql_map mysql_virtual_alias_maps.cf \
  "SELECT goto FROM alias WHERE address='%s' AND active='1'"
write_sql_map mysql_virtual_alias_domain_maps.cf \
  "SELECT goto FROM alias,alias_domain WHERE alias_domain.alias_domain='%d' AND alias.address=CONCAT('%u','@',alias_domain.target_domain) AND alias.active=1 AND alias_domain.active='1'"
write_sql_map mysql_virtual_alias_domain_catchall_maps.cf \
  "SELECT goto FROM alias,alias_domain WHERE alias_domain.alias_domain='%d' AND alias.address=CONCAT('@',alias_domain.target_domain) AND alias.active=1 AND alias_domain.active='1'"
write_sql_map mysql_virtual_alias_domain_mailbox_maps.cf \
  "SELECT maildir FROM mailbox,alias_domain WHERE alias_domain.alias_domain='%d' AND mailbox.username=CONCAT('%u','@',alias_domain.target_domain) AND mailbox.active=1 AND alias_domain.active='1'"
write_sql_map mysql_virtual_mailbox_maps.cf \
  "SELECT maildir FROM mailbox WHERE username='%s' AND active='1'"
write_sql_map mysql_virtual_mailbox_limit_maps.cf \
  "SELECT quota FROM mailbox WHERE username='%s' AND active='1'"
write_sql_map mysql-email2email.cf \
  "SELECT username FROM mailbox WHERE username='%s'"
# Sending rights via ALIAS membership, for smtpd_sender_login_maps. Without
# this, only "you may send as your own mailbox" is expressible, and a member of
# a shared/role alias (info@, office@) gets rejected the moment the sender-login
# guard is enforced. The owners of an alias address are its goto targets, which
# is also PostfixAdmin's own model. NOTE it does not grant anything across
# separate mailboxes -- an alias whose goto is itself (the common
# PostfixAdmin-generated row) confers no extra rights, verified on the
# reference host.
write_sql_map mysql-sender-login-alias.cf \
  "SELECT goto FROM alias WHERE address='%s' AND active='1'"

# --- static support files ---
install -d /etc/postfix/postfix-files.d
# header_checks is seeded once, then belongs to the operator -- the template
# itself invites per-site rules ("Add per-site rules below if you need them"),
# and this used to cp over it unconditionally with no backup(), unlike the
# transport line right below which has always been only-if-absent. On the
# reference host that would have silently replaced a file documenting the
# rspamd cutover and naming the rollback script.
if [ "$DRY_RUN" != 1 ]; then
  if [ ! -e /etc/postfix/header_checks ]; then
    cp "$MD_TEMPLATES/postfix/header_checks" /etc/postfix/header_checks
  else
    log_info "keeping existing /etc/postfix/header_checks (may hold per-site rules)"
    # Don't silently "fix" a legacy file by overwriting it, but do surface the
    # one configuration that breaks mail outright: the pre-2026 MailScanner
    # hand-off. With rspamd as the filter and MailScanner absent, an active
    # HOLD rule parks every message in the hold queue forever -- 410 stuck
    # messages on the 24.04 test host before the template dropped it.
    if grep -qE '^[[:space:]]*[^#[:space:]].*\bHOLD\b' /etc/postfix/header_checks; then
      log_warn "/etc/postfix/header_checks has an active HOLD rule -- with rspamd filtering and no MailScanner this holds EVERY message in the queue forever; remove it unless you know you need it"
    fi
  fi
  [ -e /etc/postfix/transport ] || cp "$MD_TEMPLATES/postfix/transport" /etc/postfix/transport
fi

if [ "$DRY_RUN" != 1 ]; then
  postmap /etc/postfix/transport
  postfix set-permissions >/dev/null 2>&1 || true
  postfix check || die "postfix check failed"
fi

mark_done 20-postfix
log_info "postfix configured"
