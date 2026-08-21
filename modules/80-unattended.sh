#!/usr/bin/env bash
# 80-unattended — dnf-automatic security updates. Excludes dovecot* because
# fts_xapian is an out-of-tree compiled .so; a Dovecot ABI bump applied
# unattended would make it unloadable (IMAP down). Kernel updates install but
# need a manual/scheduled reboot (reboot=never).
source "$MD_ROOT/lib/common.sh"
step_guard 80-unattended || exit 0

[ "$ENABLE_UNATTENDED" != yes ] && { log_info "unattended updates disabled — skipping"; mark_done 80-unattended; exit 0; }

if [ "$PKG_MGR" = apt ]; then
  pkg_install unattended-upgrades
  if [ "$DRY_RUN" != 1 ]; then
    conf=/etc/apt/apt.conf.d/50unattended-upgrades
    backup "$conf"
    # Security-only, matching EL's upgrade_type=security: the shipped file
    # enables the full release pocket by default (confirmed live on a real
    # 24.04 host), not just -security -- drop that line, keep the
    # -security/ESM origins already uncommented there.
    sed -i '/"${distro_id}:${distro_codename}";/d' "$conf"
    grep -q 'dovecot' "$conf" \
      || sed -i '/^Unattended-Upgrade::Package-Blacklist {/a\    "dovecot.*";' "$conf"
    grep -q '^Unattended-Upgrade::Mail ' "$conf" \
      || printf 'Unattended-Upgrade::Mail "%s";\n' "$ADMIN_EMAIL" >> "$conf"
    # "on-change" rather than dnf-automatic's always-email-on-output: closer
    # functional match (no email on a no-op run) and avoids inbox spam.
    grep -q '^Unattended-Upgrade::MailReport ' "$conf" \
      || echo 'Unattended-Upgrade::MailReport "on-change";' >> "$conf"
    grep -q '^Unattended-Upgrade::Automatic-Reboot ' "$conf" \
      || echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> "$conf"
    # Mail delivery goes through /usr/sbin/sendmail -- postfix (already a
    # hard dependency of this whole stack) provides that, so no extra
    # mailutils/bsd-mailx package is needed the way some guides assume.

    # apt ships apt-daily.timer/apt-daily-upgrade.timer always-enabled;
    # what actually gates unattended-upgrades running is this config, which
    # the package's postinst already sets to "1"/"1" on a fresh install
    # (confirmed live) -- write it explicitly anyway so a stripped image or
    # a prior manual override doesn't leave it silently off.
    write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  fi
else
  pkg_install dnf-automatic
  if [ "$DRY_RUN" != 1 ]; then
    conf=/etc/dnf/automatic.conf
    backup "$conf"
    sed -i \
      -e 's/^upgrade_type\s*=.*/upgrade_type = security/' \
      -e 's/^apply_updates\s*=.*/apply_updates = yes/' \
      -e 's/^reboot\s*=.*/reboot = never/' \
      -e "s/^emit_via\s*=.*/emit_via = email,stdio/" \
      -e "s/^email_to\s*=.*/email_to = $ADMIN_EMAIL/" \
      "$conf"
    grep -q '^exclude' "$conf" || printf '\n[base]\nexclude = dovecot*\n' >> "$conf"
  fi
  svc_enable dnf-automatic.timer
fi

mark_done 80-unattended
log_info "unattended security updates enabled (dovecot* excluded)"
