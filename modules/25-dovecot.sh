#!/usr/bin/env bash
# 25-dovecot — IMAP/POP3 with MySQL auth, Maildir, TLS, optional last_login
# and fts_xapian (compiled from source, version-matched to Dovecot 2.3.x).
source "$MD_ROOT/lib/common.sh"
source "$MD_ROOT/lib/db.sh"
step_guard 25-dovecot || exit 0
load_secrets   # POSTFIX_DB_USER / POSTFIX_DB_PASS (dovecot reuses the postfix DB user)

# Debian's dovecot-core postinst runs `invoke-rc.d dovecot restart`
# automatically whenever a related package (dovecot-fts-xapian, installed
# further down) gets configured -- EL's dnf/rpm has no equivalent behavior,
# it never restarts a running service just because a sibling package
# installed. 10-ssl.conf (written below, before that later pkg_install
# call) always points dovecot at TLS_CERT/TLS_KEY, but 75-tls-dns -- the
# module that actually provisions those -- hasn't run yet this early in the
# sequence. Confirmed live 2026-08-15: the auto-restart crashes with
# "ssl_cert: Can't open file ... No such file or directory", and dpkg
# treats a failed postinst as the WHOLE package transaction failing,
# aborting this module outright. Bootstrap a throwaway self-signed cert at
# the target path if nothing is there yet, purely so dovecot always has
# *something* loadable; 75-tls-dns.sh replaces it with the real cert
# (Let's Encrypt or a proper self-signed one) later, using this dedicated
# flag file -- not mere file-existence -- to know a placeholder needs
# replacing rather than being mistaken for a real, already-issued cert.
if [ "$DRY_RUN" != 1 ] && [ ! -e "$TLS_CERT" ]; then
  install -d "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
  if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
       -keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=bootstrap-placeholder" >/dev/null 2>&1; then
    mkdir -p "$MD_STATE_DIR"; : > "$MD_STATE_DIR/tls-bootstrap-placeholder.flag"
    log_info "bootstrapped a throwaway self-signed cert so dovecot can start before 75-tls-dns runs"
  else
    log_warn "bootstrap cert generation failed — dovecot may fail to (re)start until 75-tls-dns runs"
  fi
fi

# Debian splits the single EL "dovecot" package into per-protocol pieces
# (confirmed live on a real 24.04 host: dovecot-core alone gives no IMAP/
# POP3/LMTP at all, each needs its own package).
if [ "$PKG_MGR" = apt ]; then
  pkg_install dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-mysql
else
  pkg_install dovecot dovecot-mysql
fi

# --- SQL auth ---
setvar DB_USER "${POSTFIX_DB_USER:-postfix}"
setvar DB_PASSWORD "${POSTFIX_DB_PASS:-CHANGEME}"
setvar QUOTA_FIELD "${QUOTA_FIELD:-}"
# The userdb hands Dovecot the uid that owns each maildir; it must be the same
# id Postfix delivers as, and must not be assumed to be 89 (see
# mail_owner_ids() in lib/common.sh).
mail_owner_ids
setvar MAIL_UID "$MAIL_UID"
setvar MAIL_GID "$MAIL_GID"
render "$MD_TEMPLATES/dovecot/dovecot-sql.conf.ext.tmpl" /etc/dovecot/dovecot-sql.conf.ext
[ "$DRY_RUN" != 1 ] && chmod 600 /etc/dovecot/dovecot-sql.conf.ext && chown root:root /etc/dovecot/dovecot-sql.conf.ext

write_file /etc/dovecot/conf.d/auth-sql.conf.ext 644 <<'EOF'
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
EOF

write_file /etc/dovecot/conf.d/10-auth.conf 644 <<'EOF'
# mail-deploy: SQL-only virtual-user auth (no system auth).
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-sql.conf.ext
EOF

# --- TLS ---
write_file /etc/dovecot/conf.d/10-ssl.conf 644 <<EOF
ssl = required
ssl_cert = <$TLS_CERT
ssl_key = <$TLS_KEY
ssl_ca = <$TLS_CAFILE
ssl_min_protocol = TLSv1.2
ssl_verify_client_cert = no
ssl_cipher_list = EECDH+ECDSA+AESGCM:EECDH+aRSA+AESGCM:EECDH+ECDSA+SHA384:EECDH+ECDSA+SHA256:EECDH+aRSA+SHA384:EECDH+aRSA+SHA256:EECDH:EDH+aRSA:!aNULL:!eNULL:!LOW:!3DES:!MD5:!EXP:!PSK:!SRP:!DSS:!RC4
EOF

# --- compression (mail stored gz) ---
# NOTE: every "protocol X { setting = value }" block in this module (and in
# 26-sieve.sh/27-quota.sh) is written multi-line -- content on its own line
# after the opening brace. A single-line "protocol imap { ... }" form fails
# doveconf with "Garbage after '{'" on Dovecot 2.3.21 (confirmed live on a
# real host 2026-08-15); this was never caught before because doveconf -n
# only ever runs when DRY_RUN!=1, and this installer had never actually
# executed end-to-end on any host until this session's Ubuntu verification.
# Not Debian-specific -- the same single-line form would fail identically on
# EL9/EL10, which ship the same Dovecot 2.3.x parser.
write_file /etc/dovecot/conf.d/90-zlib.conf 644 <<'EOF'
plugin {
  zlib_save = gz
  zlib_save_level = 6
}
protocol imap {
  mail_plugins = $mail_plugins zlib imap_zlib
}
protocol lda {
  mail_plugins = $mail_plugins zlib
}
protocol lmtp {
  mail_plugins = $mail_plugins zlib
}
EOF

# --- optional: fts_xapian (build BEFORE writing its config; verify the .so) ---
FTS_OK=0
if [ "$PKG_MGR" = apt ]; then
  # Ubuntu ships a PREBUILT dovecot-fts-xapian package (1.6.0, universe) --
  # confirmed live on a real 24.04 host, no source build needed at all. Its
  # .so lands nested under modules/, unlike EL's flat /usr/lib64/dovecot/.
  if [ "$ENABLE_FTS_XAPIAN" = yes ] && [ "$DRY_RUN" != 1 ]; then
    pkg_install dovecot-fts-xapian
    if ls /usr/lib/dovecot/modules/lib2*_fts_xapian_plugin.so >/dev/null 2>&1; then
      FTS_OK=1; log_info "fts_xapian module installed + present"
    else
      log_warn "dovecot-fts-xapian installed but .so missing — skipping fts"
    fi
  elif [ "$ENABLE_FTS_XAPIAN" = yes ] && [ "$DRY_RUN" = 1 ]; then
    log_info "[dry-run] would install dovecot-fts-xapian"
  fi
elif [ "$ENABLE_FTS_XAPIAN" = yes ] && [ "$DRY_RUN" != 1 ]; then
  dovecot_ver=$(dovecot --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  fts_tag=1.5.5   # contemporary series for Dovecot 2.3.16 (see PLAN caveats)
  log_info "building fts-xapian $fts_tag for Dovecot ${dovecot_ver:-unknown}"
  pkg_install dovecot-devel xapian-core-devel gcc-c++ make autoconf automake libtool \
              pkgconf-pkg-config libicu-devel sqlite-devel
  src=/usr/local/src/fts-xapian
  if [ ! -d "$src/.git" ]; then
    rm -rf "$src"; git clone --branch "$fts_tag" --depth 1 \
      https://github.com/grosjo/fts-xapian "$src" || log_warn "fts-xapian clone failed"
  fi
  if [ -d "$src" ] && ( cd "$src" && autoreconf -vi && ./configure --with-dovecot=/usr/lib64/dovecot && make && make install ); then
    if ls /usr/lib64/dovecot/lib2*_fts_xapian_plugin.so >/dev/null 2>&1; then
      FTS_OK=1; log_info "fts_xapian module installed + present"
    else
      log_warn "fts_xapian build finished but .so missing — skipping fts"
    fi
  else
    log_warn "fts_xapian build failed — continuing without full-text search"
  fi
elif [ "$ENABLE_FTS_XAPIAN" = yes ] && [ "$DRY_RUN" = 1 ]; then
  log_info "[dry-run] would build fts-xapian from source"
fi

# --- assemble global mail_plugins based on what's enabled ---
GLOBAL_PLUGINS="zlib"
[ "$FTS_OK" = 1 ] && GLOBAL_PLUGINS="fts fts_xapian zlib"

{
  echo "# mail-deploy consolidated overrides"
  echo "protocols = imap pop3"
  echo "mail_location = maildir:$MAIL_STORE/%d/%u"
  echo "mail_home = $MAIL_STORE/%d/%u"
  echo "mail_plugins = $GLOBAL_PLUGINS"
  # The userdb hands out $MAIL_UID for every virtual mailbox, and Dovecot
  # refuses any uid below first_valid_uid -- which defaults to 500, well above
  # the postfix uid on BOTH platforms (89 on EL, 112 on the Ubuntu test host).
  # Without this, every doveadm call fails with "Mail access for users with
  # UID <n> not permitted", so the console cannot read a single mailbox. EL
  # happened to work only because the reference host had been set to 89 by
  # hand years ago; a fresh install never was.
  echo "first_valid_uid = $MAIL_UID"
  echo "first_valid_gid = $MAIL_GID"
  echo "service auth {"
  echo "  unix_listener /var/spool/postfix/private/auth {"
  echo "    mode = 0666"
  echo "    user = postfix"
  echo "    group = postfix"
  echo "  }"
  echo "}"
} | write_file /etc/dovecot/conf.d/99-mail-deploy.conf 644

# --- quarantine folders: exist for every user, from first login -------------
# The ilexa console's quarantine view runs `doveadm search -A` over every
# folder in QUARANTINE_FOLDERS on every page render, and 58-report-learn
# saves reported spam into Spam with `doveadm save` -- BOTH fail with
# "Mailbox doesn't exist" (doveadm exit 68) for any user who lacks the
# folder, which on a fresh install is every user, so the console showed its
# loud gateway-failure banner on every single page (observed on the 24.04
# box the moment the first console page rendered; the reference host never
# hit it because its 15-mailboxes.conf declares Spam auto=subscribe).
# auto=subscribe also makes the folder visible in webmail without the user
# hunting for it. No special_use here: the distro's stock 15-mailboxes.conf
# already assigns \Junk, and a second claimant would just draw warnings.
{
  echo "# Quarantine folders (QUARANTINE_FOLDERS) — auto-created + subscribed so"
  echo "# the console's search-all and the spam@/ham@ report path never hit"
  echo "# 'Mailbox doesn't exist'. Rendered by 25-dovecot."
  echo "namespace inbox {"
  for _qf in $QUARANTINE_FOLDERS; do
    echo "  mailbox $_qf {"
    echo "    auto = subscribe"
    echo "  }"
  done
  echo "}"
} | write_file /etc/dovecot/conf.d/99-quarantine-mailboxes.conf 644

# --- optional: last_login ---
if [ "$ENABLE_LAST_LOGIN" = yes ]; then
  db_exec "CREATE TABLE IF NOT EXISTS postfix.last_login (username VARCHAR(255) NOT NULL PRIMARY KEY, last_login BIGINT NOT NULL);"
  render "$MD_TEMPLATES/dovecot/dovecot-dict-last-login.conf.ext.tmpl" /etc/dovecot/dovecot-dict-last-login.conf.ext
  [ "$DRY_RUN" != 1 ] && chmod 640 /etc/dovecot/dovecot-dict-last-login.conf.ext && chown root:dovecot /etc/dovecot/dovecot-dict-last-login.conf.ext
  write_file /etc/dovecot/conf.d/91-last-login.conf 644 <<'EOF'
dict {
  lastlogin = mysql:/etc/dovecot/dovecot-dict-last-login.conf.ext
}
plugin {
  last_login_dict = proxy::lastlogin
  last_login_key = last-login/%u
  last_login_precision = s
}
protocol imap {
  mail_plugins = $mail_plugins last_login
}
protocol pop3 {
  mail_plugins = $mail_plugins last_login
}
EOF
elif [ "$DRY_RUN" != 1 ] && [ -e /etc/dovecot/conf.d/91-last-login.conf ]; then
  # Turning the feature off has to remove its drop-in, not just stop writing
  # it: dovecot globs conf.d/*.conf, so a leftover file keeps the plugin and
  # its mysql dict loaded, and the answers file no longer describes the running
  # config. backup() first so the removal is recoverable.
  backup /etc/dovecot/conf.d/91-last-login.conf
  rm -f /etc/dovecot/conf.d/91-last-login.conf
  log_info "ENABLE_LAST_LOGIN=no — removed stale /etc/dovecot/conf.d/91-last-login.conf (backed up)"
fi

# --- fts config (only if the module actually built) ---
if [ "$FTS_OK" = 1 ]; then
  write_file /etc/dovecot/conf.d/91-fts.conf 644 <<'EOF'
plugin {
  fts = xapian
  fts_xapian = partial=3 full=20 verbose=0
  fts_message_max_size = 5M
  fts_autoindex = yes
  fts_autoindex_exclude = \Trash
}
service indexer-worker {
  vsz_limit = 2G
  process_limit = 2
}
EOF
elif [ "$DRY_RUN" != 1 ] && [ -e /etc/dovecot/conf.d/91-fts.conf ]; then
  # Same reasoning as 91-last-login.conf above. Extra bite here: a leftover
  # 91-fts.conf names the xapian plugin, so if the module did NOT build fts
  # this time (missing headers, or the feature turned off) dovecot keeps trying
  # to load a plugin that may no longer be installed.
  backup /etc/dovecot/conf.d/91-fts.conf
  rm -f /etc/dovecot/conf.d/91-fts.conf
  log_info "fts not built/enabled — removed stale /etc/dovecot/conf.d/91-fts.conf (backed up)"
fi

# --- mail store ---
if [ "$DRY_RUN" != 1 ]; then
  install -d -m 770 -o "$MAIL_UID" -g "$MAIL_GID" "$MAIL_STORE" 2>/dev/null \
    || { mkdir -p "$MAIL_STORE"; chown "$MAIL_UID:$MAIL_GID" "$MAIL_STORE"; chmod 770 "$MAIL_STORE"; }
  doveconf -n >/dev/null || die "doveconf parse failed"
fi

# ---- FTS index maintenance --------------------------------------------------
# Xapian indexes are written incrementally as mail arrives, and incremental
# writes fragment them: deleted mail leaves dead entries behind and the on-disk
# size grows well past the live data. Compacting reclaims that and keeps search
# fast -- but NOTHING schedules it, so an unmaintained server accumulates
# indexes several times larger than they need to be and progressively slower
# searches. The reference host has had a hand-written optimizer since 2026-08-07
# that the installer never learned, so every installed host with FTS enabled has
# been running unmaintained indexes.
#
# `doveadm fts optimize -A` is the obvious command and the wrong one here: it
# compacts every user in one pass, peak memory scales with index size, and on a
# box sized for mail rather than search that reliably invokes the OOM killer --
# which does not necessarily kill doveadm. The installed script caps each call
# with ulimit -v, skips indexes too large to succeed under the cap, runs at
# nice 15 / ionice idle and pauses between users. Its limits derive from this
# host's RAM AT RUN TIME, so a box that gains memory later uses it.
if [ "$ENABLE_FTS_XAPIAN" = yes ] && [ "$DRY_RUN" != 1 ]; then
  install -m 0755 -o root -g root "$MD_ASSETS/dovecot/fts-optimize.sh" /usr/local/sbin/fts-optimize.sh
  install -d -m 0755 /etc/ilexa
  # Seed-once: the console owns this file afterwards (it is how the optimizer is
  # switched off without deleting the cron entry), so a re-run must not reset
  # an operator's choice.
  if [ ! -f /etc/ilexa/fts-optimize.conf ]; then
    write_file /etc/ilexa/fts-optimize.conf 0644 root:root <<EOF
# Dovecot FTS Xapian index maintenance. Managed by the ilexa console
# (Rendszer -> FTS indexek); safe to edit by hand.
#
# FTS_OPTIMIZE_ENABLED   yes|no  -- no leaves the weekly cron in place but makes
#                                   it exit immediately, so switching it back on
#                                   needs no reinstall.
# FTS_OPTIMIZE_MEM_MB            -- ulimit -v cap per doveadm call. Unset means
#                                   "a quarter of this host's RAM, clamped to
#                                   256-2048MB", recomputed at every run.
# FTS_OPTIMIZE_MAX_INDEX_MB      -- skip indexes larger than this; they cannot
#                                   compact under the cap. Defaults to half it.
# FTS_OPTIMIZE_SLEEP             -- seconds between users, so freed memory settles.
FTS_OPTIMIZE_ENABLED=${ENABLE_FTS_OPTIMIZE:-yes}
MAIL_STORE=$MAIL_STORE
EOF
    log_info "FTS optimize config seeded (/etc/ilexa/fts-optimize.conf, enabled=${ENABLE_FTS_OPTIMIZE:-yes})"
  else
    log_info "FTS optimize config exists — leaving the console's setting alone"
  fi
  # Weekly, off-peak. The script self-gates on FTS_OPTIMIZE_ENABLED, so the
  # cron entry is installed unconditionally and the console toggles behaviour.
  write_file /etc/cron.d/ilexa-fts-optimize 0644 root:root <<'EOF'
# Dovecot FTS Xapian index compaction. Gated by FTS_OPTIMIZE_ENABLED in
# /etc/ilexa/fts-optimize.conf, so disabling it in the console does not need
# this file removed. See /usr/local/sbin/fts-optimize.sh for why this is not
# a plain `doveadm fts optimize -A`.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
30 4 * * 0 root /usr/local/sbin/fts-optimize.sh >/dev/null 2>&1
EOF
  log_info "FTS optimize scheduled weekly (Sun 04:30), memory-aware, switchable in the console"
fi

mark_done 25-dovecot
log_info "dovecot configured (fts=$FTS_OK last_login=$ENABLE_LAST_LOGIN)"
