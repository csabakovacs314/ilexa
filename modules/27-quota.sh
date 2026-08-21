#!/usr/bin/env bash
# 27-quota — enforce PostfixAdmin per-mailbox quotas. Because delivery is
# virtual_transport=virtual (bypasses Dovecot LDA/LMTP), enforcement is at SMTP
# time: Postfix queries Dovecot's quota-status policy (wired in 20-postfix via
# QUOTA_POLICY) which rejects RCPT for over-quota mailboxes. IMAP QUOTA reporting
# is enabled too. The per-mailbox limit comes from the userdb quota_rule
# (QUOTA_FIELD, set in 25-dovecot).
source "$MD_ROOT/lib/common.sh"
step_guard 27-quota || exit 0

if [ "$ENABLE_QUOTA" != yes ]; then
  log_info "quotas disabled — skipping"; mark_done 27-quota; exit 0
fi

write_file /etc/dovecot/conf.d/99-zz-quota.conf 644 <<'EOF'
# mail-deploy: quota accounting (Maildir++) + SMTP-time quota-status policy.
# `quota` must be listed in the SAME protocol-imap block as `imap_quota`, not
# just in the top-level mail_plugins line above: 90-zlib.conf already opens a
# `protocol imap { mail_plugins = ... }` filter, and per Dovecot's config
# resolution a later *global* mail_plugins setting does not propagate into an
# already-opened protocol filter (doveconf -n warns "Global setting
# mail_plugins won't change the setting inside an earlier filter"). Without
# `quota` here too, imap_quota fails to load on every install with quotas
# enabled: "Couldn't load required plugin ...imap_quota_plugin.so: Plugin
# quota must be loaded also" (confirmed live on the Ubuntu 24 test box,
# 2026-08-21) -- doveconf -n still exits 0 since this is only a warning, so
# the existing `doveconf -n || die` check below never caught it.
mail_plugins = $mail_plugins quota
protocol imap {
  mail_plugins = $mail_plugins quota imap_quota
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
