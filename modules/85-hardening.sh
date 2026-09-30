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

# ---- backups (always keeps a verified LOCAL copy; ships off-host if asked) ---
#
# Reworked 2026-09-30. Two things were wrong with the previous version, both
# found on a host that believed it was backed up:
#
#  1. It was INERT without BACKUP_TARGET -- it logged "no BACKUP_TARGET set" and
#     exited 0, so a host with no off-host destination got no backup AT ALL, not
#     even a local dump. That is the common case on a single-server deployment,
#     and it is the case where losing the mailbox table means rebuilding every
#     account by hand. It now always writes a verified local dump and treats
#     shipping off-host as the optional extra.
#  2. Its verification was `gzip -t` on one dump. A TRUNCATED dump is a
#     perfectly valid gzip file -- verified live: piping half a real dump through
#     gzip passes `gzip -t` cleanly -- so a short dump would be encrypted,
#     shipped and logged as "restore-test OK". The check is now by CONTENT: the
#     `-- Dump completed` marker mysqldump writes LAST, the CREATE TABLE count
#     against the live schema, and for `postfix` the mailbox row count.
write_file /usr/bin/mail-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# mail-backup — nightly verified DB dumps, kept locally and shipped off-host
# when BACKUP_TARGET is configured in /etc/mail-backup.conf.
#
# Deliberately NOT inert without a target: the local verified dump is the part
# that saves you from a bad migration or a dropped table, and it costs under a
# megabyte. BACKUP_TARGET adds survival of losing the host, which the local copy
# cannot give you -- they are different failures, so both layers exist.
#
# NO set -e: a failure on one database must still be reported, and the local
# copy must still be kept even if shipping off-host fails.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/etc/mail-backup.conf
# The directive must sit alone, directly above the source line: on a compound
# line it binds to the assignment instead, and trailing prose on the directive
# line makes shellcheck discard it (SC1125). Both cost a round to learn.
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
: "${BACKUP_TARGET:=}"; : "${MAIL_STORE:=/data/mail}"
: "${BACKUP_DBS:=postfix roundcube}"; : "${BACKUP_LOCAL_DIR:=/var/backups/ilexa-db}"
: "${BACKUP_KEEP_DAYS:=30}"
ts=$(date +%F-%H%M%S); rc=0

# 0700 / 0600 throughout: these dumps contain mailbox password HASHES and users'
# address books. A readable path must never exist, even briefly.
install -d -m 0700 -o root -g root "$BACKUP_LOCAL_DIR" || {
  logger -t mail-backup "cannot create $BACKUP_LOCAL_DIR"; exit 2; }
work=$(mktemp -d); chmod 0700 "$work"
trap 'rm -rf "$work"' EXIT

for db in $BACKUP_DBS; do
  f="$work/${db}-${ts}.sql.gz"
  if ! mysqldump --single-transaction --quick --routines --triggers \
                 --default-character-set=utf8mb4 --databases "$db" 2>"$f.err" | gzip -c >"$f"; then
    logger -t mail-backup "FAILED $db: mysqldump -- $(tr -d '\n' <"$f.err" | cut -c1-120)"
    rm -f "$f" "$f.err"; rc=1; continue
  fi
  rm -f "$f.err"

  # --- verify by CONTENT. gzip -t alone accepts a truncated dump. ---
  if ! gzip -t "$f" 2>/dev/null; then
    logger -t mail-backup "FAILED $db: gzip integrity"; rm -f "$f"; rc=1; continue
  fi
  if ! zcat "$f" | tail -5 | grep -q '^-- Dump completed'; then
    logger -t mail-backup "FAILED $db: truncated (no '-- Dump completed' marker)"
    rm -f "$f"; rc=1; continue
  fi
  live_t=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)
  dump_t=$(zcat "$f" | grep -c '^CREATE TABLE')
  if [ -z "$live_t" ] || [ "$dump_t" -lt "$live_t" ]; then
    logger -t mail-backup "FAILED $db: $dump_t tables dumped, $live_t live"
    rm -f "$f"; rc=1; continue
  fi
  if [ "$db" = postfix ]; then
    live_mb=$(mysql -N -e "SELECT COUNT(*) FROM postfix.mailbox;" 2>/dev/null)
    dump_mb=$(zcat "$f" | sed -n "/INSERT INTO \`mailbox\`/,/;\$/p" | grep -o "),(" | wc -l)
    dump_mb=$(( dump_mb > 0 ? dump_mb + 1 : 0 ))
    if [ "$dump_mb" -lt "$live_mb" ]; then
      logger -t mail-backup "FAILED postfix: ~$dump_mb mailbox rows dumped, $live_mb live"
      rm -f "$f"; rc=1; continue
    fi
  fi

  # Keep the verified local copy BEFORE any encryption or shipping, so a broken
  # target or a missing gpg can never cost you the backup itself.
  install -m 0600 -o root -g root "$f" "$BACKUP_LOCAL_DIR/$(basename "$f")" \
    && logger -t mail-backup "ok $db: $(du -h "$f" | cut -f1), $dump_t tables (local)"
done

# --- retention. Never prune the newest copy of a database, whatever its age. --
for db in $BACKUP_DBS; do
  newest=$(ls -1t "$BACKUP_LOCAL_DIR"/"$db"-*.sql.gz 2>/dev/null | head -1)
  while IFS= read -r old; do
    [ "$old" = "$newest" ] && continue
    rm -f -- "$old"
  done < <(find "$BACKUP_LOCAL_DIR" -maxdepth 1 -name "$db-*.sql.gz" -mtime +"$BACKUP_KEEP_DAYS" 2>/dev/null)
done

# --- off-host, only if asked -------------------------------------------------
if [ -z "$BACKUP_TARGET" ]; then
  logger -t mail-backup "local copy kept in $BACKUP_LOCAL_DIR; no BACKUP_TARGET set, nothing shipped"
  exit "$rc"
fi
if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  for f in "$work"/*.sql.gz; do
    [ -e "$f" ] || continue
    gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" -c "$f" && rm -f "$f"
  done
else
  logger -t mail-backup "WARNING: BACKUP_PASSPHRASE unset — DB dumps ship UNENCRYPTED"
fi
# rsync-style target example; adapt to restic/borg/S3 as needed.
if rsync -a "$work"/ "$BACKUP_TARGET/db/" && rsync -a "$MAIL_STORE"/ "$BACKUP_TARGET/mail/"; then
  logger -t mail-backup "shipped to $BACKUP_TARGET ($ts)"
else
  logger -t mail-backup "FAILED: shipping to $BACKUP_TARGET (local copy is intact)"; rc=1
fi
exit "$rc"
EOF
if [ "$DRY_RUN" != 1 ]; then
  command -v gpg >/dev/null 2>&1 || pkg_try gnupg2 >/dev/null 2>&1 || log_warn "gnupg2 not installed — backup encryption unavailable"
  [ -e /etc/mail-backup.conf ] || printf 'BACKUP_TARGET=%s\nMAIL_STORE=%s\n# Set a passphrase to gpg-encrypt DB dumps at rest (they contain password hashes):\nBACKUP_PASSPHRASE=%s\n' \
    "$BACKUP_TARGET" "$MAIL_STORE" "${BACKUP_PASSPHRASE:-}" > /etc/mail-backup.conf
  chmod 600 /etc/mail-backup.conf
  write_file /etc/cron.d/mail-backup 644 <<'EOF'
# Nightly verified DB dumps. A local copy is always kept (see mail-backup.sh);
# off-host shipping happens only when BACKUP_TARGET is set.
# MAILTO empty on purpose: cron-alert.sh then uses /etc/ilexa/alerts.conf, and
# mails only when a dump, its verification, or the shipping step fails.
MAILTO=""
30 2 * * * root /usr/bin/cron-alert.sh mail-backup /usr/bin/mail-backup.sh
EOF
  [ -n "$BACKUP_TARGET" ] && log_info "backups: local + off-host -> $BACKUP_TARGET" || log_info "backups: verified local dumps in /var/backups/ilexa-db (set BACKUP_TARGET in /etc/mail-backup.conf to also ship off-host)"
fi

mark_done 85-hardening
log_info "hardening options applied"
