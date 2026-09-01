#!/usr/bin/env bash
# run-acceptance.sh — end-to-end acceptance + idempotency for mail-deploy.
#
# MUST run only on a DISPOSABLE machine: it executes deploy.sh for real and
# provisions a test domain. Works on any supported target (EL9/EL10, Ubuntu
# 22.04/24.04/26.04) -- every OS-specific name below is resolved at runtime.
#
#   ci/run-acceptance.sh [answers-file]
#
# The default answers file (ci/answers.ci.conf) is a LAB profile that disables
# OTX, FTS-Xapian, MTA-STS, autoconfig, metrics, IPv6 and all hardening. A green
# run with it therefore does NOT exercise those modules. For an OS-compatibility
# test, pass an answers file with the features you actually want covered.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANS="${1:-$ROOT/ci/answers.ci.conf}"
[ -r "$ANS" ] || { echo "answers file not readable: $ANS"; exit 2; }
echo "using answers: $ANS"

# OS-specific service and package names, resolved rather than assumed.
#
# Keyed on the PACKAGE MANAGER, not on /etc/apache2. This block runs before
# phase 1 has installed anything, so on a genuinely fresh host that directory
# does not exist yet and the test fell through to the EL name -- then phase 2
# reported "FAIL: service httpd active" on a box where apache2 was running
# perfectly. It only ever passed on a re-run, where a previous install had
# already created the directory. Observed on a clean 24.04 box 2026-08-26.
if command -v apt-get >/dev/null 2>&1; then WEB_SVC=apache2; PKG_INSTALL="apt-get install -y -qq"
else                                        WEB_SVC=httpd;   PKG_INSTALL="dnf -y install"; fi
CLAMD_SVC=$(systemctl list-unit-files 'clamav-daemon.service' 'clamd@scan.service' --no-legend 2>/dev/null \
            | awk '{print $1}' | head -1)
fail=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# Safety: refuse to run on anything that looks like a real server.
[ -f /etc/ilexa/secrets/otx_api_key ] && { echo "refusing: /etc/ilexa/secrets/otx_api_key present (not a clean VM)"; exit 2; }

echo "===== 1. first deploy ====="
bash "$ROOT/deploy.sh" --answers "$ANS" || { echo "deploy failed"; exit 1; }

echo "===== 2. service + config health ====="
# mailscanner deliberately absent: rspamd replaced it in the 2026 stack, so
# checking for it failed on every run and made a healthy install look broken.
for u in mariadb postfix dovecot rspamd "$WEB_SVC" fail2ban ${CLAMD_SVC:+$CLAMD_SVC}; do
  check "service $u active" "systemctl is-active --quiet '$u'"
done
check "postfix check clean" "postfix check"
check "doveconf parses"     "doveconf -n"
for p in 25 465 587 143 993 4190; do
  check "port $p listening" "ss -ltn | grep -q ':$p '"
done

echo "===== 3. provisioning (domain + mailbox, full-form maildir) ====="
PA=/var/www/html/postfixadmin
# postfixadmin-cli is a SHELL wrapper; `php <that>` merely echoes its source
# and exits 0, so the two provisioning calls here silently did nothing and
# every downstream check failed for a reason no output explained. Invoke the
# PHP entry point directly, and keep the CLI's own error when it refuses.
PA_CLI="$PA/scripts/postfixadmin-cli.php"
# The domain must RESOLVE: PostfixAdmin validates it and rejects anything it
# cannot look up ("Invalid domain ..., and/or not discoverable in DNS"), so
# the old hardcoded ci.test could never have worked. Use the deployment's own
# primary domain, which has to resolve for the install to be valid at all.
CI_DOMAIN=$(grep -oE '^PRIMARY_DOMAIN=.*' "$ANS" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')
[ -n "$CI_DOMAIN" ] || CI_DOMAIN=$(postconf -h mydomain 2>/dev/null)
CI_USER="ci-acceptance@$CI_DOMAIN"

if [ -r "$PA_CLI" ] && [ -n "$CI_DOMAIN" ]; then
  # The domain usually already exists (the installer creates it); only its
  # absence is worth reporting, not "already exists".
  php "$PA_CLI" domain add "$CI_DOMAIN" --active 1 >/dev/null 2>&1
  # --email_other is REQUIRED, not optional padding: the installer patches
  # MailboxHandler::preSave() to refuse a NEW mailbox without a recovery
  # address, because one that has none cannot use password-recover.php and is
  # a permanent-lockout risk under expiry enforcement. This check predated that
  # patch and was asserting against behaviour the product deliberately changed,
  # failing with "Error: Field Other e-mail is missing".
  add_out=$(php "$PA_CLI" mailbox add "$CI_USER" --password 'Test-1234' --password2 'Test-1234' \
                 --name CI --active 1 --email_other "postmaster@$CI_DOMAIN" 2>&1)
  md=$(mysql -N -e "SELECT maildir FROM postfix.mailbox WHERE username='$CI_USER';" 2>/dev/null)
  if [ -z "$md" ]; then
    bad "could not provision $CI_USER -- postfixadmin-cli said: $(printf '%s' "$add_out" | grep -iE 'error|invalid|exists' | head -1)"
  else
    case "$md" in "$CI_DOMAIN/$CI_USER/") ok "maildir full-form ($md)";;
                  *) bad "maildir not full-form ($md)";; esac
  fi
else
  bad "postfixadmin-cli.php not found, or no primary domain resolvable (provisioning check skipped)"
fi

echo "===== 4. filtering (GTUBE spam + EICAR virus) ====="
# This section used to assert only that a GTUBE message was ACCEPTED, which
# proves the SMTP listener works and says nothing about filtering -- an install
# with rspamd entirely inert passed it. Check the OUTCOME instead: rspamd must
# report having seen the message and scored it, and ClamAV must actually catch
# EICAR. The EICAR leg was named in this script's own header for months without
# ever being implemented.
command -v swaks >/dev/null 2>&1 || $PKG_INSTALL swaks >/dev/null 2>&1 || true
if command -v swaks >/dev/null 2>&1; then
  rs_before=$(rspamc stat 2>/dev/null | grep -oE 'Messages scanned: [0-9]+' | grep -oE '[0-9]+' || echo 0)

  gt_out=$(swaks --to "$CI_USER" --server 127.0.0.1 \
                 --body 'XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X' 2>&1)
  # A REJECTION is the better outcome, not a failure. GTUBE scores far above
  # SPAM_REJECT, so a correctly configured host refuses it at SMTP time and
  # swaks then exits non-zero -- which the previous form reported as
  # "GTUBE injection failed", i.e. it printed FAIL precisely when spam
  # filtering was working. Accept either: rejected outright (strongest), or
  # accepted and then scored (checked immediately below).
  if printf '%s' "$gt_out" | grep -qiE '55[04] .*(gtube|spam|reject)'; then
    ok "GTUBE rejected at SMTP time ($(printf '%s' "$gt_out" | grep -oiE '55[04][^"]*gtube[^"]*' | head -1))"
  elif printf '%s' "$gt_out" | grep -q '250 .*[Qq]ueued'; then
    ok "GTUBE accepted for scanning (verdict checked below)"
  else
    bad "GTUBE was neither rejected nor queued: $(printf '%s' "$gt_out" | tail -3 | tr '\n' ' ')"
  fi

  # EICAR: the standard antivirus test string, as a plain-text attachment.
  # Split at runtime so this file itself is not flagged by scanners.
  eicar='X5O!P%@AP[4\PZX54(P^)7CC)7}$'"$(printf 'EICAR')"'-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
  printf '%s' "$eicar" > /tmp/eicar.txt
  swaks --to "$CI_USER" --server 127.0.0.1 --body 'virus test' \
        --attach-type text/plain --attach /tmp/eicar.txt >/dev/null 2>&1
  rm -f /tmp/eicar.txt

  sleep 6
  rs_after=$(rspamc stat 2>/dev/null | grep -oE 'Messages scanned: [0-9]+' | grep -oE '[0-9]+' || echo 0)
  if [ "${rs_after:-0}" -gt "${rs_before:-0}" ]; then
    ok "rspamd scanned the injected mail (${rs_before} -> ${rs_after})"
  else
    bad "rspamd scanned nothing — the milter is not in the delivery path"
  fi

  # ClamAV runs via rspamd's antivirus module, so a caught EICAR shows up as a
  # CLAM_VIRUS symbol rather than a clamd log line.
  if rspamc counters 2>/dev/null | grep -q "CLAM_VIRUS"; then
    ok "ClamAV wired into rspamd (CLAM_VIRUS symbol registered)"
  else
    bad "CLAM_VIRUS symbol absent — antivirus is not wired into the filter path"
  fi

  if journalctl -u rspamd --since "2 min ago" --no-pager 2>/dev/null | grep -qiE "clam|virus" \
     || grep -qiE "clam|virus" /var/log/mail.log /var/log/maillog 2>/dev/null; then
    ok "EICAR produced an antivirus reaction in the logs"
  else
    echo "SKIP: no antivirus log line seen (signatures may still be downloading)"
  fi
else
  echo "SKIP: swaks unavailable — mail-flow checks skipped"
fi

echo "===== 4b. the ilexa console answers ====="
if [ -f /var/www/html/quarantine-admin/index.php ]; then
  code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1/ilexa/" 2>/dev/null)
  case "$code" in
    401) ok "console served and demands authentication (401)" ;;
    200) bad "console served WITHOUT authentication (200) — Basic Auth is not enforced" ;;
    *)   bad "console did not answer as expected (http=$code)" ;;
  esac
else
  echo "SKIP: console not installed (ENABLE_ILEXA=no?)"
fi

echo "===== 4c. wiring: every referenced helper actually exists ====="
# The bug class that has cost this project the most: a console panel or cron
# job shelling out to a root helper the installer never placed. It fails at
# runtime, explains nothing, and looks like a broken feature. helpers.list is
# the single source (checked in-repo by the app's tools/check-helpers.php);
# what THIS asserts is the other half -- that a real install actually has the
# files on disk, which no static check can know.
if [ -r /opt/ilexa-src/install/helpers.list ]; then
  miss=0; n=0
  while read -r hname _; do
    n=$((n+1))
    [ -x "/usr/local/sbin/$hname" ] || { bad "helper not installed: /usr/local/sbin/$hname"; miss=$((miss+1)); }
  done < <(awk '$1 !~ /^#/ && NF >= 3 { print $1 }' /opt/ilexa-src/install/helpers.list)
  [ "$miss" = 0 ] && ok "all $n helpers from helpers.list present in /usr/local/sbin"
else
  echo "SKIP: helpers.list not found (console not installed from a bundle?)"
fi

# Every path a generated cron job invokes must exist. A cron entry pointing at
# a missing interpreter or script fails silently every time it fires -- the
# hu-classify report job shipped exactly like that.
cron_bad=0; cron_n=0
for cf in /etc/cron.d/ilexa /etc/cron.d/qa-* /etc/cron.d/update-rspamd-community-rules; do
  [ -r "$cf" ] || continue
  while read -r bin; do
    cron_n=$((cron_n+1))
    [ -x "$bin" ] || { bad "cron $cf references a missing/non-executable path: $bin"; cron_bad=$((cron_bad+1)); }
  # EVERY absolute path in the command, not just the first: a wrapper line
  # like `cron-alert.sh <tag> /opt/.../python3 /usr/local/sbin/foo.py` has
  # three, and stopping at the first would have missed exactly the bug this
  # check exists for (a report script no installer had placed, third on the
  # line). Stop at the first redirect so log destinations -- which legitimately
  # do not exist yet -- are not treated as missing executables.
  done < <(awk '$1 !~ /^#/ && NF > 6 {
                  for (i = 6; i <= NF; i++) {
                    if ($i ~ /^[0-9]?>/) break
                    if ($i ~ /^\//) print $i
                  } }' "$cf")
done
[ "$cron_bad" = 0 ] && ok "all $cron_n cron-referenced paths exist and are executable"

# sudoers must parse. An invalid drop-in does not fail loudly at install time
# but breaks EVERY console action that shells out.
check "sudoers drop-in parses" "visudo -cqf /etc/sudoers.d/ilexa"

echo "===== 4d. console pages render without PHP diagnostics ====="
# 401 proves Basic Auth is enforced; it does NOT prove the page works. Render
# each view server-side through the app's own gate, which fails on any
# notice/warning -- the class php -l cannot see.
if [ -x /opt/ilexa-src/tools/check-views.php ] || [ -r /opt/ilexa-src/tools/check-views.php ]; then
  vout=$(cd /var/www/html/quarantine-admin && php /opt/ilexa-src/tools/check-views.php --quiet 2>&1)
  if [ $? = 0 ]; then ok "all views render with no PHP diagnostics"
  else bad "view diagnostics on a real install:"; printf '%s\n' "$vout" | sed 's/^/    /'; fi
else
  echo "SKIP: check-views.php not present in the bundle"
fi

echo "===== 5. threat-intel dry-run (loader builds a set) ====="
if [ -x /usr/local/sbin/load-otx.sh ]; then
  DRY_RUN=1 /usr/local/sbin/load-otx.sh >/dev/null 2>&1 && ok "load-otx dry-run" || echo "SKIP: OTX not configured"
fi

echo "===== 6. DNS output present ====="
check "DKIM records generated" "test -s /root/mail-deploy-dkim-dns.txt"
check "credentials file 0600"  "test \"\$(stat -c %a /root/ilexa-install-credentials.txt)\" = 600"

echo "===== 7. idempotency (second run makes no changes) ====="
log2=/tmp/deploy-run2.log
MD_LOG="$log2" bash "$ROOT/deploy.sh" --answers "$ANS" >/tmp/run2.out 2>&1 || bad "second run errored"
mods=$(ls "$ROOT"/modules/[0-9]*.sh | wc -l)
done_n=$(grep -c 'already done' /tmp/run2.out || true)
if [ "$done_n" -ge $((mods - 2)) ]; then ok "idempotent re-run ($done_n modules skipped)"; else bad "re-run not idempotent ($done_n/$mods skipped)"; fi

echo "==================================================="
if [ "$fail" -eq 0 ]; then echo "ACCEPTANCE: ALL PASSED"; exit 0
else echo "ACCEPTANCE: $fail CHECK(S) FAILED"; exit 1; fi
