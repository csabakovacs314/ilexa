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
#   - /usr/local/sbin/rspamd-report-learn  (python3 handler; hardened:
#     internal-sender check, size caps, rate limit, never bounces)
#   - /etc/rspamd-report/domains.txt       (which sender domains may report;
#     regenerated from PRIMARY_DOMAIN+EXTRA_DOMAINS on every run — hand-edits
#     do not survive a re-run, add domains to the answers file instead)
#   - narrow sudoers rule: rspamreport may run exactly
#     `doveadm save -u <user> -m Spam` (append-only, one folder)
#   - two master.cf pipe services (rspamreport-spam / rspamreport-ham)
#   - transport map entries routing rspamlearn-{spam,ham}@localhost.<primary>
#     to those services
#   - alias rows per mail domain: spam@<d> / ham@<d> -> the routing addresses.
#     INSERT IGNORE on purpose: if a real spam@/ham@ mailbox or alias already
#     exists in a domain, it is left alone (warned, not clobbered).
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
  log_info "[dry-run] would create user rspamreport, install rspamd-report-learn,"
  log_info "[dry-run] write /etc/rspamd-report/domains.txt, add sudoers rule,"
  log_info "[dry-run] append 2 master.cf pipe services + 2 transport entries (${route_dom}),"
  log_info "[dry-run] and seed spam@/ham@ aliases for: $PRIMARY_DOMAIN $EXTRA_DOMAINS"
  mark_done 58-report-learn; exit 0
fi

pkg_install python3 >/dev/null 2>&1 || true   # handler is python3; present on both families

# --- dedicated runtime user + state/config dirs ------------------------------
getent passwd rspamreport >/dev/null \
  || useradd -r -s /sbin/nologin -d /var/lib/rspamd-report -M rspamreport \
  || die "cannot create the rspamreport user"
install -d -m 0755 -o rspamreport -g rspamreport /var/lib/rspamd-report
install -d -m 0755 /etc/rspamd-report

# --- handler ----------------------------------------------------------------
install -m 0755 -o root -g root "$MD_ASSETS/report/rspamd-report-learn" \
  /usr/local/sbin/rspamd-report-learn

# Sender domains allowed to report. Regenerated every run (see header).
{
  for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do echo "$d"; done
} > /etc/rspamd-report/domains.txt
chmod 0644 /etc/rspamd-report/domains.txt

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
for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do
  for cls in spam ham; do
    # INSERT IGNORE: never clobber an existing spam@/ham@ mailbox or alias.
    db_exec "INSERT IGNORE INTO alias (address,goto,domain,created,modified,active)
             VALUES ('${cls}@${d}','rspamlearn-${cls}@${route_dom}','${d}',NOW(),NOW(),1);" postfix \
      || log_warn "alias seed failed: ${cls}@${d}"
    got=$(db_exec "SELECT goto FROM alias WHERE address='${cls}@${d}';" postfix 2>/dev/null | head -1)
    if [ "$got" = "rspamlearn-${cls}@${route_dom}" ]; then
      log_info "report address: ${cls}@${d}"
    else
      log_warn "report address ${cls}@${d} NOT seeded — a different ${cls}@${d} already exists (goto: ${got:-none}); left untouched"
    fi
  done
done

postfix check || die "postfix check failed after report-learn changes"
svc_reload postfix

mark_done 58-report-learn
log_info "spam/ham report addresses configured (route: rspamlearn-*@${route_dom})"
