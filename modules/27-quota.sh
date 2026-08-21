#!/usr/bin/env bash
# 27-quota — enforce PostfixAdmin per-mailbox quotas. Primary enforcement is
# at SMTP time: Postfix queries Dovecot's quota-status policy (wired in
# 20-postfix via QUOTA_POLICY) which rejects RCPT for over-quota mailboxes --
# rejecting pre-queue beats bouncing post-queue. Delivery itself now goes via
# Dovecot LMTP (see main.cf.tmpl virtual_transport), which enforces quota a
# second time at write; the RCPT-time policy stays because it is the one that
# refuses mail before this server has accepted responsibility for it. IMAP QUOTA reporting
# is enabled too. The per-mailbox limit comes from the userdb quota_rule
# (QUOTA_FIELD, set in 25-dovecot).
source "$MD_ROOT/lib/common.sh"
step_guard 27-quota || exit 0

if [ "$ENABLE_QUOTA" != yes ]; then
  log_info "quotas disabled — skipping"; mark_done 27-quota; exit 0
fi

write_file /etc/dovecot/conf.d/99-zz-quota.conf 644 <<'EOF'
# mail-deploy: quota accounting (Maildir++) + SMTP-time quota-status policy.
# The `quota` base plugin is loaded GLOBALLY by 00-mail-deploy-plugins.conf
# (written by 25-dovecot, which reads ENABLE_QUOTA for exactly this): this
# file sorts last, far after 90-zlib's protocol filters have snapshotted the
# global, so a global mail_plugins line HERE never reaches them and only
# draws the "won't change the setting inside an earlier filter" warning.
# Only the imap-specific loader is added here; imap inherits quota from the
# 00- global, satisfying imap_quota's "Plugin quota must be loaded also".
protocol imap {
  mail_plugins = $mail_plugins imap_quota
}
plugin {
  quota = maildir:User quota
  quota_status_success = DUNNO
  quota_status_nouser = DUNNO
  quota_status_overquota = "552 5.2.2 Mailbox is over quota"
  quota_grace = 10%%
}
service quota-status {
  executable = quota-status -p postfix
  unix_listener /var/spool/postfix/private/quota-status {
    user = postfix
    mode = 0660
  }
  client_limit = 1
}
EOF

if [ "$DRY_RUN" != 1 ]; then
  doveconf -n >/dev/null || die "doveconf parse failed after enabling quota"
fi

mark_done 27-quota
log_info "mailbox quotas enforced (SMTP-time quota-status + IMAP QUOTA)"
