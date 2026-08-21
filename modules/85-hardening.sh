#!/usr/bin/env bash
# 85-hardening — secure-by-default toggles from the 2026-07-22 security review.
# Lockout-safe: SSH key-only only applies when a pubkey is supplied AND a
# key-seeded sudo admin user has been created first.
source "$MD_ROOT/lib/common.sh"
step_guard 85-hardening || exit 0

# ---- SSH key-only + sudo admin user ---------------------------------------
if [ "$HARDEN_SSH_KEYONLY" = yes ]; then
  if [ -z "$ADMIN_SSH_PUBKEY" ]; then
    log_warn "SSH key-only requested but ADMIN_SSH_PUBKEY empty — SKIPPING (would risk lockout)"
  elif [ "$DRY_RUN" = 1 ]; then
    log_info "[dry-run] would create sudo admin user + enforce SSH key-only on port $SSH_PORT"
  else
    # wheel doesn't exist on Debian (Ubuntu's admin group is "sudo"); actual
    # sudo access here comes from the sudoers.d entry below regardless, so
    # this group membership is cosmetic -- just don't hand useradd a group
    # that doesn't exist.
    admin_group=wheel; [ "$PKG_MGR" = apt ] && admin_group=sudo
    id mailadmin >/dev/null 2>&1 || useradd -m -G "$admin_group" -s /bin/bash mailadmin
    install -d -m 700 -o mailadmin -g mailadmin /home/mailadmin/.ssh
    echo "$ADMIN_SSH_PUBKEY" > /home/mailadmin/.ssh/authorized_keys
    chmod 600 /home/mailadmin/.ssh/authorized_keys; chown mailadmin:mailadmin /home/mailadmin/.ssh/authorized_keys
    # Grant real sudo: the account is key-only (no password), so wheel's default
    # password prompt would make it unable to escalate — NOPASSWD gives it the
    # same effective trust as root's prohibit-password key login. Validate the
    # file before it lands (a broken sudoers.d entry breaks ALL sudo).
    printf '# mail-deploy key-only sudo admin\nmailadmin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/mailadmin
    chmod 440 /etc/sudoers.d/mailadmin
    if visudo -cf /etc/sudoers.d/mailadmin >/dev/null 2>&1; then
      log_info "sudoers.d/mailadmin installed (validated)"
    else
      rm -f /etc/sudoers.d/mailadmin; log_warn "sudoers validation failed — removed mailadmin sudo entry"
    fi
    # also seed root so the existing root key path keeps working
    install -d -m 700 /root/.ssh
    grep -qF "$ADMIN_SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$ADMIN_SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    write_file /etc/ssh/sshd_config.d/50-mail-hardening.conf 600 <<EOF
# mail-deploy SSH hardening — key-only. root stays reachable by KEY only.
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    if sshd -t 2>/dev/null; then
      systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
      log_info "SSH hardened (key-only, port $SSH_PORT); admin user 'mailadmin' seeded"
    else
      log_warn "sshd -t failed — reverting SSH hardening drop-in"
      rm -f /etc/ssh/sshd_config.d/50-mail-hardening.conf
    fi
  fi
fi

# ---- SELinux (OFF by default; opt-in = permissive burn-in, NOT enforce) ----
# EL-only feature -- Debian's MAC is AppArmor, a different system entirely,
# and none of the packages/paths here exist there. pkg_install (unlike
# pkg_try) hard-dies on a missing package, so this would have aborted the
# whole module on Debian if HARDEN_SELINUX were ever set to yes.
if [ "$HARDEN_SELINUX" = yes ] && [ "$PKG_MGR" = apt ]; then
  log_warn "HARDEN_SELINUX=yes ignored — SELinux is EL-only (Debian uses AppArmor, not implemented here)"
elif [ "$HARDEN_SELINUX" = yes ] && [ "$DRY_RUN" != 1 ]; then
  pkg_install audit policycoreutils-python-utils
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  log_warn "SELinux set to PERMISSIVE (burn-in). Review 'ausearch -m avc | audit2allow' before setting enforcing."
else
  log_info "SELinux left disabled (documented hardening TODO — matches reference box)"
fi

# ---- Webmin source-IP allowlist -------------------------------------------
if [ "$HARDEN_WEBMIN" = yes ] && [ -f /etc/webmin/miniserv.conf ] && [ "$DRY_RUN" != 1 ]; then
  backup /etc/webmin/miniserv.conf
  sed -i '/^allow=/d' /etc/webmin/miniserv.conf
  echo "allow=$WEBMIN_ALLOW_IPS" >> /etc/webmin/miniserv.conf
  systemctl restart webmin 2>/dev/null || true
  log_info "Webmin allowlisted to: $WEBMIN_ALLOW_IPS"
elif [ "$HARDEN_WEBMIN" = yes ]; then
  log_info "Webmin allowlist requested but Webmin not installed — skipping"
fi

# ---- kernel auto-reboot (maintenance window) ------------------------------
if [ "$HARDEN_KERNEL_AUTOREBOOT" = yes ] && [ "$DRY_RUN" != 1 ]; then
  # dnf-utils' `needs-restarting -r` has no apt equivalent -- and critically,
  # a script that unconditionally invokes a missing command on Debian gets a
  # nonzero (127, "command not found") exit status every time, which the
  # original `||` logic reads as "reboot required": this would have rebooted
  # the box every single Sunday regardless of actual need. Debian/apt signal
  # the same fact via the well-known /var/run/reboot-required marker file
  # instead (created by apt when an installed kernel/library update needs a
  # restart to take effect).
  if [ "$PKG_MGR" = apt ]; then
    write_file /usr/bin/kernel-autoreboot.sh 755 <<'EOF'
#!/usr/bin/env bash
# Reboot only if a newer kernel/library needs it (maintenance window via cron).
[ -f /var/run/reboot-required ] || exit 0
logger -t kernel-autoreboot "reboot required — rebooting"
systemctl reboot
EOF
  else
    pkg_try dnf-utils >/dev/null 2>&1 || true
    write_file /usr/bin/kernel-autoreboot.sh 755 <<'EOF'
#!/usr/bin/env bash
# Reboot only if a newer kernel/library needs it (maintenance window via cron).
needs-restarting -r >/dev/null 2>&1 || { logger -t kernel-autoreboot "reboot required — rebooting"; systemctl reboot; }
EOF
  fi
  write_file /etc/cron.d/kernel-autoreboot 644 <<'EOF'
# Sundays 04:30 — activate installed kernel/security updates if needed.
30 4 * * 0 root /usr/bin/kernel-autoreboot.sh
EOF
  log_info "kernel auto-reboot scheduled (Sun 04:30 if needed)"
fi

# ---- backups (module always installed; ACTIVE only when a target is set) ---
write_file /usr/bin/mail-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# mail-backup — nightly per-DB dumps + mail-store sync to BACKUP_TARGET.
# Inert (exit 0) until BACKUP_TARGET is configured in /etc/mail-backup.conf.
set -euo pipefail
# shellcheck source=/dev/null
CONF=/etc/mail-backup.conf; [ -r "$CONF" ] && . "$CONF"
: "${BACKUP_TARGET:=}"; : "${MAIL_STORE:=/data/mail}"
[ -z "$BACKUP_TARGET" ] && { logger -t mail-backup "no BACKUP_TARGET set — skipping"; exit 0; }
ts=$(date +%F); work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for db in postfix roundcube; do
  mysqldump --single-transaction "$db" | gzip > "$work/${db}-${ts}.sql.gz"
done
# restore-test hook: verify the newest dump gunzips cleanly BEFORE shipping.
gzip -t "$work/postfix-${ts}.sql.gz" || { logger -t mail-backup "restore-test FAILED — aborting"; exit 1; }
# Dumps contain mailbox password HASHES — encrypt at rest before shipping.
if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  for f in "$work"/*.sql.gz; do
    gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" -c "$f" && rm -f "$f"
  done
else
  logger -t mail-backup "WARNING: BACKUP_PASSPHRASE unset — DB dumps ship UNENCRYPTED"
fi
# rsync-style target example; adapt to restic/borg/S3 as needed.
rsync -a "$work"/ "$BACKUP_TARGET/db/" && rsync -a "$MAIL_STORE"/ "$BACKUP_TARGET/mail/"
logger -t mail-backup "backup + restore-test OK ($ts)"
EOF
if [ "$DRY_RUN" != 1 ]; then
  command -v gpg >/dev/null 2>&1 || pkg_try gnupg2 >/dev/null 2>&1 || log_warn "gnupg2 not installed — backup encryption unavailable"
  [ -e /etc/mail-backup.conf ] || printf 'BACKUP_TARGET=%s\nMAIL_STORE=%s\n# Set a passphrase to gpg-encrypt DB dumps at rest (they contain password hashes):\nBACKUP_PASSPHRASE=%s\n' \
    "$BACKUP_TARGET" "$MAIL_STORE" "${BACKUP_PASSPHRASE:-}" > /etc/mail-backup.conf
  chmod 600 /etc/mail-backup.conf
  write_file /etc/cron.d/mail-backup 644 <<'EOF'
30 2 * * * root /usr/bin/mail-backup.sh
EOF
  [ -n "$BACKUP_TARGET" ] && log_info "backups ACTIVE -> $BACKUP_TARGET" || log_info "backup module installed but INACTIVE (set BACKUP_TARGET in /etc/mail-backup.conf)"
fi

mark_done 85-hardening
log_info "hardening options applied"
