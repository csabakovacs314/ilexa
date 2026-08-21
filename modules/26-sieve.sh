#!/usr/bin/env bash
# 26-sieve — server-side mail filtering (Sieve) + ManageSieve (port 4190).
# Runs after 25-dovecot. The drop-in is numbered 99-zz so it loads AFTER
# 99-mail-deploy.conf and can extend `protocols` via $protocols.
source "$MD_ROOT/lib/common.sh"
step_guard 26-sieve || exit 0

if [ "$ENABLE_SIEVE" != yes ]; then
  log_info "Sieve disabled — skipping"; mark_done 26-sieve; exit 0
fi

# Pigeonhole (sieve) is a single EL package but two on Debian -- confirmed
# live on a real 24.04 host, both real and resolvable via apt.
if [ "$PKG_MGR" = apt ]; then
  pkg_install dovecot-sieve dovecot-managesieved
else
  pkg_install dovecot-pigeonhole
fi

write_file /etc/dovecot/conf.d/99-zz-sieve.conf 644 <<'EOF'
# mail-deploy: Sieve delivery filter + ManageSieve service.
protocols = $protocols sieve
protocol lda {
  mail_plugins = $mail_plugins sieve
}
protocol lmtp {
  mail_plugins = $mail_plugins sieve
}
plugin {
  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_default = /var/lib/dovecot/sieve/default.sieve
}
service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}
EOF

if [ "$DRY_RUN" != 1 ]; then
  doveconf -n >/dev/null || die "doveconf parse failed after enabling sieve"
fi

mark_done 26-sieve
log_info "sieve + managesieve (4190) configured"
