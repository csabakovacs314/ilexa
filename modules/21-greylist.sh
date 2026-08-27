#!/usr/bin/env bash
# 21-greylist — postgrey: temporarily defer mail from an unseen sender triplet.
#
# WHAT IT BUYS, measured on the reference host over ~3 months rather than
# assumed: 7,045 distinct sender triplets greylisted, of which 45% NEVER came
# back — 3,169 senders blocked outright. Those are incremental: postscreen runs
# first and had already let them through, so this catches what the cheaper
# layer missed, and it blocks more than rspamd rejects outright (2,547).
#
# WHAT IT COSTS: a one-time delay per unseen sender, not per message.
# --auto-whitelist-clients=5 promotes a client to the whitelist after five
# successful deliveries, so ordinary correspondents are delayed once and never
# again. On the reference host that left 3,611 of the day's deliveries under a
# minute and only 8 beyond 6.5 minutes.
#
# WHY IT IS OPTIONAL. It is the worst cost/benefit of the three filtering
# layers even though clearly positive — postscreen blocks four times as much
# for no delay at all — and the delay lands hardest on exactly the mail people
# notice: password resets, 2FA codes and ticket confirmations from a sender
# they have never corresponded with before. An operator serving citizens may
# reasonably refuse that trade, and should not have to edit Postfix to do it.
#
# Runs after 20-postfix (main.cf already references the policy service) and
# before 90-enable (which starts it). If this module is skipped or the package
# is unavailable, main.cf's default_action=DUNNO means Postfix carries on
# without greylisting rather than deferring every message — see deploy.sh.
source "$MD_ROOT/lib/common.sh"
step_guard 21-greylist || exit 0

: "${ENABLE_GREYLISTING:=yes}"
if [ "$ENABLE_GREYLISTING" != yes ]; then
  log_info "greylisting disabled (ENABLE_GREYLISTING=no) — skipping"
  mark_done 21-greylist; exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log_info "[dry-run] would install postgrey and configure it on 127.0.0.1:10023"
  log_info "[dry-run] delay=300, auto-whitelist after 5 deliveries, max-age=35 days"
  mark_done 21-greylist; exit 0
fi

# pkg_try, not pkg_install: greylisting is optional, so a missing package must
# not abort an otherwise good build. On EL it comes from EPEL, which
# 05-base.sh has already enabled.
if ! pkg_try postgrey; then
  log_warn "postgrey not available — continuing without greylisting."
  log_warn "main.cf uses default_action=DUNNO, so mail flows normally; set"
  log_warn "ENABLE_GREYLISTING=no to stop this warning."
  mark_done 21-greylist; exit 0
fi

# --- one config, two packaging conventions ----------------------------------
#
# Both families ship the same daemon and the same options; only the defaults
# file differs. EL reads /etc/sysconfig/postgrey and splits the invocation
# across several variables its unit file concatenates; Debian reads
# /etc/default/postgrey and passes POSTGREY_OPTS wholesale.
#
# Both are normalised to inet:127.0.0.1:10023 because main.cf names that
# explicitly. Debian's packaged default is "--inet=10023" (no address), which
# happens to bind the same place but would silently stop matching if the
# template ever changed — better that both say the same thing.
#
#   --delay=300                  hold an unseen triplet for 5 minutes
#   --auto-whitelist-clients=5   after 5 good deliveries, stop delaying it
#   --max-age=35                 forget a triplet after 35 days
GREY_DELAY=300
GREY_AUTOWL=5
GREY_MAXAGE=35
GREY_TEXT='Greylisted for %s seconds'

if [ "$PKG_MGR" = apt ]; then
  write_file /etc/default/postgrey 0644 root:root <<EOF
# Managed by ilexa-installer (modules/21-greylist.sh). See that file for why
# these values, and for what greylisting costs as well as what it buys.
POSTGREY_OPTS="--inet=127.0.0.1:10023 --delay=${GREY_DELAY} --auto-whitelist-clients=${GREY_AUTOWL} --max-age=${GREY_MAXAGE}"
POSTGREY_TEXT="${GREY_TEXT}"
EOF
else
  write_file /etc/sysconfig/postgrey 0644 root:root <<EOF
# Managed by ilexa-installer (modules/21-greylist.sh). See that file for why
# these values, and for what greylisting costs as well as what it buys.
POSTGREY_TYPE="--inet=127.0.0.1:10023"
POSTGREY_PID="--pidfile=/var/run/postgrey.pid"
POSTGREY_GROUP="--group=postgrey"
POSTGREY_USER="--user=postgrey"
POSTGREY_DELAY="--delay=${GREY_DELAY}"
POSTGREY_OPTS="--auto-whitelist-clients=${GREY_AUTOWL} --max-age=${GREY_MAXAGE}"
EOF
fi

# RESTART, not merely enable — the same trap 30-auth.sh documents at length.
# On Debian the package starts postgrey at install time, seconds ago, on the
# distribution's default socket; 90-enable's `enable --now` does nothing to an
# already-running service, so the config written above would never reach the
# process and Postfix would dial a port nothing was listening on.
if systemctl list-unit-files 2>/dev/null | grep -q '^postgrey\.service'; then
  systemctl restart postgrey >/dev/null 2>&1 \
    && log_info "postgrey configured on 127.0.0.1:10023 (delay ${GREY_DELAY}s, auto-whitelist after ${GREY_AUTOWL})" \
    || log_warn "postgrey installed but would not start — mail still flows (default_action=DUNNO)"
else
  log_warn "postgrey.service not found after install — mail still flows (default_action=DUNNO)"
fi

mark_done 21-greylist
