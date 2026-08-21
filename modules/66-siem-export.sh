#!/usr/bin/env bash
# 66-siem-export — seed the SIEM-export config file (optional, off by default).
#
# "Installer seeds it, console owns it after" -- same division of labor as
# the Spamhaus DQS key (qa-spamhaus-dqs.sh): qa-siem-config.sh (installed by
# modules/55-ilexa.sh's helpers.list copy loop, which runs before this
# module) is the SOLE renderer of /etc/rsyslog.d/60-siem-forward.conf from
# here on, driven by the ilexa console's Admin -> SIEM-exportálás card. This
# module only calls it once, at install time, to produce that file's default
# safe state (imfile inputs active, forwarding off) -- there is nothing else
# for this module to render or maintain itself, and duplicating the file's
# content a second way here would just be two copies to keep in sync, the
# exact bug class that produced [[project_mailserver_deployer]]'s
# helpers.list refactor in the first place.
#
# Requires ilexa (ENABLE_ILEXA=yes, the default): qa-siem-config.sh is one
# of its bundled helpers, and there is no other UI to manage this setting.
source "$MD_ROOT/lib/common.sh"
step_guard 66-siem-export || exit 0

if [ "${ENABLE_SIEM_EXPORT:-no}" != yes ]; then
  log_info "SIEM export prep disabled (ENABLE_SIEM_EXPORT=no) — skipping"
  mark_done 66-siem-export; exit 0
fi

if [ ! -x /usr/local/sbin/qa-siem-config.sh ]; then
  log_warn "qa-siem-config.sh not installed (requires ENABLE_ILEXA=yes) — SIEM export prep skipped"
  mark_done 66-siem-export; exit 0
fi

pkg_install rsyslog >/dev/null 2>&1 || true

if [ "$DRY_RUN" != 1 ]; then
  # `disable` (not `set`) deliberately: it renders the file in its always-
  # active-inputs / forwarding-off state without requiring a host/port from
  # the operator at install time, and is idempotent against a re-run that
  # finds the console has since turned it on -- `disable` only ever writes
  # enabled=no, `set` with a stale seed value could otherwise clobber a
  # collector an admin already configured through the console.
  if [ -s /etc/ilexa/siem.conf ]; then
    log_info "SIEM export already configured (console-managed) — leaving /etc/ilexa/siem.conf as-is"
  elif out=$(/usr/local/sbin/qa-siem-config.sh disable 2>&1); then
    log_info "SIEM export prep installed (local2=fail2ban local3=apache-ssl local4=ilexa-audit; forwarding off — configure a collector from Admin -> SIEM-exportálás)"
  else
    log_error "qa-siem-config.sh disable failed: $out"
  fi
else
  log_info "[dry-run] would seed SIEM export prep via qa-siem-config.sh"
fi

mark_done 66-siem-export
