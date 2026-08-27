#!/usr/bin/env bash
#
# 58-report-learn — user spam/ham report addresses (spam@<domain> / ham@<domain>).
#
# Users forward a mis-classified message AS AN ATTACHMENT to spam@ or ham@ of
# their own domain; the handler extracts the message/rfc822 original, strips
# scanner-added headers, feeds it to rspamd (Bayes learn + local fuzzy
# add/del) and — for spam — saves a copy into the reporter's own Spam folder
# so the report shows up in the console's quarantine view. This is the main
# training path for POP3 users, whose clients delete mail from the server
# (webmail users also have mark-as-junk buttons; this works for everyone).
#
# Ported from the reference host's live implementation. The pieces:
#   - dedicated no-login system user `rspamreport` (pipe transports run as it;
#     never as postfix/root)
#   - /usr/local/sbin/rspamd-report-learn  (python3 handler; hardened: sender
#     must be a REAL ACTIVE MAILBOX, size caps, rate limit, never bounces)
#   - /usr/local/sbin/rspamd-report-senders + /etc/rspamd-report/senders.txt
#     (the address allow-list the handler checks against, refreshed every 15
#     minutes by /etc/cron.d/ilexa-report-senders — a domain-level check let
#     any forged local sender poison Bayes, see that script's header)
#   - /etc/rspamd-report/domains.txt       (which sender domains may report;
#     regenerated on every run from the live `domain` table unioned with
#     PRIMARY_DOMAIN+EXTRA_DOMAINS — hand-edits do not survive a re-run, and no
#     longer need to: a domain added in PostfixAdmin is picked up by re-running
#     this module, which is also how a host installed before this fix gets the
#     addresses it is missing)
#   - narrow sudoers rule: rspamreport may run exactly
#     `doveadm save -u <user> -m Spam` (append-only, one folder)
#   - two master.cf pipe services (rspamreport-spam / rspamreport-ham)
#   - transport map entries routing rspamlearn-{spam,ham}@localhost.<primary>
#     to those services
#   - alias rows for EVERY active mail domain: spam@<d> / ham@<d> -> the
#     routing addresses. INSERT IGNORE on purpose: if a real spam@/ham@ mailbox
#     or alias already exists in a domain, it is left alone (warned, not
#     clobbered).
#
# Re-running this module is safe and is the supported way to pick up domains
# added after the install: `./deploy.sh --only 58-report-learn`.
#
# Learning needs no controller password: worker-controller.inc sets
# secure_ip = 127.0.0.1, and the handler talks to 127.0.0.1:11334.
# Runs after 50-web (domain rows exist) and 40-rspamd (controller configured).
source "$MD_ROOT/lib/common.sh"
# db.sh provides db_exec() for the alias seeding below. Modules run in their
# OWN shell, so nothing another module sourced carries over -- the exact bug
# 55-ilexa's header documents, faithfully reproduced here on first ship:
# every alias INSERT died "command not found", logged as "alias seed failed",
# and the report addresses silently did not exist on the first real install.
source "$MD_ROOT/lib/db.sh"
step_guard 58-report-learn || exit 0

: "${ENABLE_REPORT_ADDRESSES:=yes}"
if [ "$ENABLE_REPORT_ADDRESSES" != yes ]; then
  log_info "report addresses disabled (ENABLE_REPORT_ADDRESSES=no) — skipping"
  mark_done 58-report-learn; exit 0
fi

route_dom="localhost.${PRIMARY_DOMAIN}"

if [ "$DRY_RUN" = 1 ]; then
  log_info "[dry-run] would create user rspamreport, install rspamd-report-learn +"
  log_info "[dry-run] rspamd-report-senders (+15min cron for the address allow-list),"
  log_info "[dry-run] write /etc/rspamd-report/domains.txt, add sudoers rule,"
  log_info "[dry-run] append 2 master.cf pipe services + 2 transport entries (${route_dom}),"
  log_info "[dry-run] and seed spam@/ham@ aliases for every active mail domain (answers + the domain table)"
  mark_done 58-report-learn; exit 0
fi

pkg_install python3 >/dev/null 2>&1 || true   # handler is python3; present on both families

# --- dedicated runtime user + state/config dirs ------------------------------
getent passwd rspamreport >/dev/null \
  || useradd -r -s /sbin/nologin -d /var/lib/rspamd-report -M rspamreport \
  || die "cannot create the rspamreport user"
install -d -m 0755 -o rspamreport -g rspamreport /var/lib/rspamd-report
install -d -m 0755 /etc/rspamd-report
# Where a REFUSED report is kept instead of being destroyed. The handler is a
# Postfix pipe that exits 0 on every path, so without this a refusal silently
# discards the user's mail. Created here rather than by the handler because
# the handler runs unprivileged and cannot make a directory under /var/spool.
# 0700 rspamreport: a refused report is still somebody's mail.
install -d -m 0700 -o rspamreport -g rspamreport /var/spool/rspamd-report-denied

# --- handler ----------------------------------------------------------------
install -m 0755 -o root -g root "$MD_ASSETS/report/rspamd-report-learn" \
  /usr/local/sbin/rspamd-report-learn
install -m 0755 -o root -g root "$MD_ASSETS/report/rspamd-report-senders" \
  /usr/local/sbin/rspamd-report-senders

# --- which domains get report addresses -------------------------------------
#
# THE ANSWERS FILE IS NOT THE SOURCE OF TRUTH FOR THIS. It names the domains
# that existed when the installer ran; PostfixAdmin adds more afterwards, and a
# domain added later used to get no spam@/ham@ at all -- silently, because
# nothing re-ran this module and nothing checked.
#
# On the reference host that left 121 of 142 mailboxes -- every domain except
# the primary, including the one holding 91 of them -- with nowhere to report
# to, while /etc/rspamd-report/domains.txt cheerfully listed those same domains
# as permitted senders. The feature looked configured and worked for 15% of
# users.
#
# So the live `domain` table is the source, unioned with the answers values
# (which still matter on the very first run, before 50-web has inserted the
# rows, and for a domain configured but not yet created).
#
# The shape filter is not decoration: these values are interpolated into the
# SQL below and written to a config file, so anything that is not a plain
# lowercase hostname is dropped rather than escaped.
report_domains=$(
  { printf '%s\n' $PRIMARY_DOMAIN $EXTRA_DOMAINS
    db_exec "SELECT domain FROM domain WHERE active=1 AND domain<>'ALL';" postfix 2>/dev/null
  } | tr 'A-Z' 'a-z' | tr -d '[:blank:]' \
    | grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' | sort -u
)
[ -n "$report_domains" ] || die "no mail domains found for report addresses"

# Sender domains allowed to report. Regenerated every run (see header) -- now
# from the same list the aliases are seeded from, so the two cannot disagree.
printf '%s\n' $report_domains > /etc/rspamd-report/domains.txt
chmod 0644 /etc/rspamd-report/domains.txt

# --- who may report: the ADDRESS allow-list ---------------------------------
#
# domains.txt above says which domains may report; this says which ADDRESSES,
# and it is the gate that actually stops Bayes poisoning. Without it the
# handler accepted any sender at a local domain, including addresses that do
# not exist -- and the envelope sender is asserted by the connecting party,
# not verified. Regenerated on a schedule because mailboxes come and go through
# PostfixAdmin long after the installer last ran.
# Exits 0 with an informational line when there are simply no mailboxes yet,
# which is the normal state on a fresh install -- so this warns only on a real
# failure, not on "nothing to allow".
/usr/local/sbin/rspamd-report-senders \
  || log_warn "sender allow-list not generated — reports will be DENIED until \
/usr/local/sbin/rspamd-report-senders succeeds (the handler fails closed on purpose)"

# --- require SMTP authentication to reach a report address --------------------
#
# The handler's own gate can only inspect the ENVELOPE sender, which an
# unauthenticated party asserts and nothing verifies. This closes the hole at
# the door instead: spam@/ham@ are the one endpoint that only ever legitimately
# receives mail from OUR OWN users, so they can demand authentication without
# touching global mail acceptance.
#
# WHY THIS IS SAFE WHERE TIGHTENING SPF IS NOT. SPF affects every inbound
# message from the whole internet -- on the reference host that would have
# rejected ~205 legitimate messages a day. This affects two addresses per
# domain. Measured before shipping: real reports arrive either SASL-
# authenticated or via local pickup (which bypasses smtpd entirely), and
# webmail uses markasjunk's cmd_learn driver, which calls rspamc and never
# sends mail at all. Nothing legitimate travels the path being closed.
#
# A refusal here is a VISIBLE 550 telling the user what to do -- strictly
# better than the old behaviour, where such a message was accepted and then
# silently discarded by the handler.
report_msg='550 5.7.1 Report addresses accept authenticated submissions only. Use webmail, or enable SMTP authentication in your mail client.'
{
  echo "# Report addresses requiring SMTP AUTH -> the restriction class in main.cf."
  echo "# Regenerated by 58-report-learn; hand edits do not survive a re-run."
  for d in $report_domains; do
    printf 'spam@%s\treport_auth_only\nham@%s\treport_auth_only\n' "$d" "$d"
  done
} > /etc/postfix/report_auth
{
  echo "# Refusal text, reached only after the permit_* rules inside the class declined."
  for d in $report_domains; do
    printf 'spam@%s\t%s\nham@%s\t%s\n' "$d" "$report_msg" "$d" "$report_msg"
  done
} > /etc/postfix/report_deny
chmod 0644 /etc/postfix/report_auth /etc/postfix/report_deny
postmap hash:/etc/postfix/report_auth
postmap hash:/etc/postfix/report_deny

# main.cf is rendered by 20-postfix from templates/postfix/main.cf.tmpl, which
# now carries BOTH the restriction class and the check itself
# (@@REPORT_AUTH_CLASS@@ / @@REPORT_AUTH_CHECK@@). This module only owns the
# two maps above.
#
# It used to add them here with postconf -e, after main.cf had been rendered.
# That is a silent trap: any later re-render drops them, the maps and the class
# survive so nothing looks wrong, and unauthenticated mail to spam@/ham@ is
# quietly accepted again -- the Bayes-poisoning path reopened. Reproduced on the
# test host: clearing 20-postfix's step marker and re-running was enough, and
# `deploy.sh --only 20-postfix` does the same thing.
#
# Kept as a REPAIR for hosts installed before that fix, where main.cf was
# rendered without the placeholders. Adds nothing when the template already
# supplied it.
_rr=$(postconf -h smtpd_recipient_restrictions | tr -d '\n' | sed 's/  */ /g')
case "$_rr" in
  *report_auth*)
    : ;;   # template supplied it (or an earlier repair did)
  *)
    log_info "repairing pre-template host: adding the report-address auth check to main.cf"
    postconf -e "smtpd_restriction_classes = report_auth_only"
    postconf -e "report_auth_only = permit_mynetworks, permit_sasl_authenticated, check_recipient_access hash:/etc/postfix/report_deny"
    postconf -e "smtpd_recipient_restrictions = check_recipient_access hash:/etc/postfix/report_auth, $_rr" ;;
esac

install -d -m 0755 /etc/cron.d
cat > /etc/cron.d/ilexa-report-senders <<'EOF'
# Keep the spam/ham report allow-list in step with the mailbox table.
# The handler denies every report while this list is missing or empty, so a
# failure here is visible as reports stopping, not as reports being accepted
# from addresses that no longer exist.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/15 * * * * root /usr/local/sbin/rspamd-report-senders --quiet
EOF
chmod 0644 /etc/cron.d/ilexa-report-senders

# --- sudoers: append-only Spam-folder save, nothing else --------------------
cat > /etc/sudoers.d/ilexa-report-doveadm <<'EOF'
# rspamd-report-learn (running as rspamreport via the Postfix rspamreport-*
# pipe transports) saves a reported message into the REPORTER's Spam folder so
# it is visible in the ilexa console. Exactly this one command shape; the -u
# wildcard is the reporting user's own address, taken from ${sender}.
rspamreport ALL=(root) NOPASSWD: /usr/bin/doveadm save -u * -m Spam
EOF
chmod 0440 /etc/sudoers.d/ilexa-report-doveadm
visudo -c -f /etc/sudoers.d/ilexa-report-doveadm >/dev/null \
  || { rm -f /etc/sudoers.d/ilexa-report-doveadm; die "sudoers rule failed visudo -c"; }

# --- master.cf pipe services (append-if-absent; 20-postfix owns the file) ----
if ! grep -q '^rspamreport-spam ' /etc/postfix/master.cf; then
  backup /etc/postfix/master.cf
  cat >> /etc/postfix/master.cf <<'EOF'

# User spam/ham report handling (58-report-learn): learns the attached
# original into rspamd and (spam only) saves it to the reporter's Spam folder.
# Routed here by transport_maps (rspamlearn-spam/ham@localhost.<primary>).
rspamreport-spam unix - n n - - pipe
  flags=DRhu user=rspamreport argv=/usr/local/sbin/rspamd-report-learn spam ${sender}
rspamreport-ham  unix - n n - - pipe
  flags=DRhu user=rspamreport argv=/usr/local/sbin/rspamd-report-learn ham ${sender}
EOF
fi

# --- transport routing ------------------------------------------------------
touch /etc/postfix/transport
if ! grep -q "^rspamlearn-spam@${route_dom}" /etc/postfix/transport; then
  backup /etc/postfix/transport
  printf '%s\t%s\n' "rspamlearn-spam@${route_dom}" "rspamreport-spam:" >> /etc/postfix/transport
  printf '%s\t%s\n' "rspamlearn-ham@${route_dom}"  "rspamreport-ham:"  >> /etc/postfix/transport
fi
postmap /etc/postfix/transport

# --- alias rows: spam@/ham@ in every mail domain ----------------------------
seeded=0; skipped=0
for d in $report_domains; do
  for cls in spam ham; do
    # INSERT IGNORE: never clobber an existing spam@/ham@ mailbox or alias.
    db_exec "INSERT IGNORE INTO alias (address,goto,domain,created,modified,active)
             VALUES ('${cls}@${d}','rspamlearn-${cls}@${route_dom}','${d}',NOW(),NOW(),1);" postfix \
      || log_warn "alias seed failed: ${cls}@${d}"
    got=$(db_exec "SELECT goto FROM alias WHERE address='${cls}@${d}';" postfix 2>/dev/null | head -1)
    if [ "$got" = "rspamlearn-${cls}@${route_dom}" ]; then
      log_info "report address: ${cls}@${d}"
      seeded=$((seeded+1))
    else
      skipped=$((skipped+1))
      log_warn "report address ${cls}@${d} NOT seeded — a different ${cls}@${d} already exists (goto: ${got:-none}); left untouched"
    fi
  done
done
log_info "report addresses: ${seeded} routed, ${skipped} left alone, across $(printf '%s\n' $report_domains | wc -l) domain(s)"

postfix check || die "postfix check failed after report-learn changes"
svc_reload postfix

mark_done 58-report-learn
log_info "spam/ham report addresses configured (route: rspamlearn-*@${route_dom})"
