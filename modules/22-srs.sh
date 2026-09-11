#!/usr/bin/env bash
# 22-srs — SRS (Sender Rewriting Scheme) so forwarded mail survives SPF.
#
# THE PROBLEM, measured on the reference host rather than assumed. An alias
# that forwards off-server relays the message keeping the ORIGINAL envelope
# sender, so the destination checks SPF for the sender's domain against THIS
# host and fails. Over one week of real traffic: t-email.hu 467 delivered /
# 334 bounced (42%), 310 of them "550 5.7.1 Message failed SPF check"; gmail
# 3264 / 264, ~207 of those "5.7.26 sender is unauthenticated". Forwarding is
# an ordinary PostfixAdmin feature, so this is a default-on fix, not a tweak.
#
# WHAT IT COSTS. sender_canonical_maps is per-MESSAGE, and a message cannot
# carry a different sender per recipient, so EVERY inbound message from a
# non-hosted domain gets an SRS Return-Path — not only forwarded ones. That is
# how postsrsd works everywhere; it is cosmetic, and bounces still reverse
# correctly. Say so out loud rather than let an operator discover it.
#
# WHAT IT DOES NOT FIX. If the subject is rewritten for spam (SPAM_REWRITE_
# SUBJECT), the sender's DKIM signature is invalidated, so a forwarded copy has
# neither aligned SPF nor valid DKIM and still fails a strict DMARC policy.
# Weakening the filter for that would be the wrong trade.
source "$MD_ROOT/lib/common.sh"
step_guard 22-srs || exit 0

: "${ENABLE_SRS:=yes}"
if [ "$ENABLE_SRS" != yes ]; then
  log_info "SRS disabled (ENABLE_SRS=no) — forwarded mail will fail SPF at the destination"
  mark_done 22-srs; exit 0
fi

SRS_DOMAIN="${PRIMARY_DOMAIN:-}"
if [ -z "$SRS_DOMAIN" ]; then
  log_warn "PRIMARY_DOMAIN is empty — cannot pick an SRS domain, skipping SRS"
  mark_done 22-srs; exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log_info "[dry-run] would install postsrsd, rewrite envelope senders as SRS0=...@${SRS_DOMAIN}"
  log_info "[dry-run] would exclude every hosted domain and install the daily srs-sync cron"
  mark_done 22-srs; exit 0
fi

# pkg_try, not pkg_install: forwarding still works without SRS (it just fails
# SPF), so a missing package must not abort an otherwise good build.
if ! pkg_try postsrsd; then
  log_warn "postsrsd not available — forwarded mail will fail SPF at the destination."
  log_warn "Set ENABLE_SRS=no to stop this warning."
  mark_done 22-srs; exit 0
fi

# --- capability detection, not version assumption ---------------------------
# postsrsd 1.x is configured through /etc/default/postsrsd and exposes two TCP
# lookup tables (10001 forward, 10002 reverse). 2.x replaced both with a single
# socketmap and /etc/postsrsd.conf, which needs different main.cf syntax. Only
# the 1.x layout is verified here, so anything else is left unconfigured and
# said so, rather than guessed at and silently breaking mail.
if [ ! -f /etc/default/postsrsd ]; then
  log_warn "postsrsd is installed but /etc/default/postsrsd is absent — this is"
  log_warn "probably postsrsd 2.x, whose socketmap config differs. SRS NOT configured;"
  log_warn "mail flows normally, but forwarded mail will still fail SPF."
  mark_done 22-srs; exit 0
fi

# The SRS domain must publish an SPF record authorising this host, or the
# rewrite buys nothing. DNS is frequently not in place yet at install time, so
# warn and carry on rather than refuse: an SPF result of "none" for our domain
# is still treated more kindly by receivers than an outright "fail" for
# somebody else's.
if command -v dig >/dev/null 2>&1; then
  if dig +short TXT "$SRS_DOMAIN" 2>/dev/null | grep -qi 'v=spf1'; then
    log_info "SRS domain $SRS_DOMAIN publishes an SPF record"
  else
    log_warn "$SRS_DOMAIN publishes no SPF record yet — publish one (see the DNS"
    log_warn "records this installer printed) or forwarded mail still will not authenticate."
  fi
fi

# Every hosted domain is excluded: only third-party senders being relayed
# onward may be rewritten. srs-sync keeps this list current as domains are
# added through PostfixAdmin — without it the list silently rots.
EXCLUDES="$PRIMARY_DOMAIN"
for d in ${EXTRA_DOMAINS:-}; do
  case ",$EXCLUDES," in *",$d,"*) ;; *) EXCLUDES="$EXCLUDES,$d" ;; esac
done

write_file /etc/default/postsrsd 0644 root:root <<EOF
# Managed by ilexa-installer (modules/22-srs.sh). See that file for what SRS
# buys, what it costs, and what it cannot fix.
SRS_DOMAIN=${SRS_DOMAIN}
SRS_EXCLUDE_DOMAINS=${EXCLUDES}
SRS_SEPARATOR==
SRS_SECRET=/etc/postsrsd.secret
SRS_HASHLENGTH=4
SRS_HASHMIN=4
SRS_FORWARD_PORT=10001
SRS_REVERSE_PORT=10002
RUN_AS=nobody
CHROOT=
EOF

# The secret signs every SRS address; anything world-readable here would let a
# local user forge return paths. The package ships it 0644.
[ -f /etc/postsrsd.secret ] && chmod 0600 /etc/postsrsd.secret

# --- make SRS return addresses acceptable at RCPT time -----------------------
# Bounces come back to SRS0.../SRS1... at the SRS domain. That domain is a
# virtual mailbox domain, and smtpd_reject_unlisted_recipient defaults to yes,
# so smtpd rejects those addresses BEFORE cleanup ever runs — verified live:
# they are absent from both the mailbox and the alias map. This map exists only
# to make that RCPT-time lookup succeed; it is never used for delivery, because
# canonical rewriting runs before virtual alias expansion. Its target therefore
# only catches SRS addresses postsrsd REFUSES to reverse (bad hash, expired,
# forged), which would otherwise vanish silently.
write_file /etc/postfix/srs_accept.pcre 0644 root:root <<EOF
# Managed by ilexa-installer (modules/22-srs.sh) — see there for why.
/^SRS[01][=+-].*@${SRS_DOMAIN//./\\.}\$/	postmaster@${SRS_DOMAIN}
EOF

VA=$(postconf -h virtual_alias_maps)
case "$VA" in
  *srs_accept.pcre*) ;;
  *) VA="$VA, pcre:/etc/postfix/srs_accept.pcre" ;;
esac

# One -e, then every assignment: postconf's -e is a MODE flag, and repeating it
# fails the whole call.
postconf -e "sender_canonical_maps = tcp:127.0.0.1:10001" \
            "sender_canonical_classes = envelope_sender" \
            "recipient_canonical_maps = tcp:127.0.0.1:10002" \
            "recipient_canonical_classes = envelope_recipient,header_recipient" \
            "virtual_alias_maps = $VA"

install -m 755 "$MD_ASSETS/postfix/srs-sync.sh" /usr/local/sbin/srs-sync.sh

write_file /etc/cron.d/ilexa-srs 0644 root:root <<'EOF'
# Keep postsrsd's exclude list in step with the domains hosted here.
# Without this, a domain added through PostfixAdmin has its users' outbound
# envelope sender rewritten and loses SPF alignment for their own domain.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
23 4 * * *   root  /usr/local/sbin/srs-sync.sh >/dev/null 2>&1
EOF

# Once main.cf names the tcp: tables, postsrsd is on the critical mail path:
# an unreachable lookup table is a TEMPORARY error, so Postfix queues mail
# instead of delivering it. Nothing is lost, but it stalls. Order Postfix
# after postsrsd so a reboot cannot come up in that state.
mkdir -p /etc/systemd/system/postfix.service.d
write_file /etc/systemd/system/postfix.service.d/10-srs.conf 0644 root:root <<'EOF'
# Managed by ilexa-installer (modules/22-srs.sh).
# sender_canonical_maps/recipient_canonical_maps point at postsrsd's tcp
# tables. If postsrsd is not up, those lookups fail with a temporary error and
# Postfix defers every message, so it must start first. Wants, not Requires:
# stopping postsrsd by hand should not take Postfix down with it.
[Unit]
Wants=postsrsd.service
After=postsrsd.service
EOF
systemctl daemon-reload >/dev/null 2>&1 || true

# RESTART, not enable: on Debian the package has already started postsrsd on
# its packaged defaults seconds ago, and 90-enable's `enable --now` does
# nothing to a running service, so the config above would never reach it.
systemctl enable postsrsd >/dev/null 2>&1 || true
if systemctl restart postsrsd >/dev/null 2>&1; then
  log_info "SRS active: third-party senders rewritten as SRS0=...@${SRS_DOMAIN}"
  log_info "hosted domains excluded: ${EXCLUDES}"
else
  log_warn "postsrsd would not start, and main.cf now points at its lookup tables."
  log_warn "Postfix will DEFER (queue, not lose) mail until it is up. Fix with:"
  log_warn "  systemctl status postsrsd   then   systemctl start postsrsd"
fi

mark_done 22-srs
