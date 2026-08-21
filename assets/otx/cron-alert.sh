#!/bin/bash
# Generic cron wrapper: run a command, record a one-line result to the journal,
# and email $MAILTO ONLY if the command fails (non-zero exit). Turns the
# otherwise-silent OTX cron jobs (update-otx.sh, update-otx-whitelist.sh) into
# alerting jobs instead of '>/dev/null 2>&1'.
#
#   Usage: cron-alert.sh <tag> <command> [args...]
#
# Design notes:
#  - NO 'set -e': we must capture the child's failure and still send mail.
#  - Explicit PATH: cron's minimal PATH lacks /usr/sbin (logger/mail/firewall-cmd
#    are fine, but be safe — matches the ss/swapon-under-cron gotcha on this box).
#  - Success is journal-only (no mail) so a healthy 6h job never spams the inbox.
#  - Only HARD failures of the wrapped command mail: for update-otx.sh those are
#    key unreadable, whitelist<50 (exit 3), entry count<350 (exit 1), or
#    check-config/reload failure. A flaky-but-survivable OTX run (some pulses
#    lost, count still >=350) exits 0 -> journal WARNING only, deliberately NO
#    mail (OTX 504s constantly; alerting on that would be pure noise).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

tag="${1:?usage: cron-alert.sh <tag> <command> [args...]}"
shift
[ "$#" -ge 1 ] || { echo "cron-alert: no command given" >&2; exit 2; }

# Notification recipient. Resolution order:
#   1. MAILTO from the environment (a cron file, or an operator overriding once)
#   2. /etc/ilexa/alerts.conf, managed from the console's Admin tab
#   3. nothing -- and nothing means NO MAIL AT ALL
#
# The default used to be "root", so a fresh install mailed the root mailbox
# about every failure whether or not anyone had asked for alerts. On a mail
# server that is worse than noise: a failing mail path then tries to mail about
# itself. Silence is now the default and an address must be entered before
# anything is sent; the failure is still journalled either way, so nothing is
# lost -- it just does not arrive uninvited.
ALERTS_CONF=/etc/ilexa/alerts.conf
if [ -z "${MAILTO:-}" ] && [ -r "$ALERTS_CONF" ]; then
    MAILTO="$(grep -vE '^\s*#|^\s*$' "$ALERTS_CONF" | head -1 | tr -d '[:space:]')"
fi
: "${MAILTO:=}"

# Optional edge-triggered suppression for transient failures. A job may mark
# certain exit codes as "soft" (e.g. update-otx.sh's below-floor OTX abort =
# EX_TEMPFAIL 75, which keeps last-good and self-heals next run). A single soft
# failure is journal-only; mail fires once the streak of consecutive soft
# failures reaches SOFT_FAIL_THRESHOLD, then stays quiet until a success clears
# it. Default (SOFT_FAIL_RC empty) = every non-zero mails, exactly as before.
: "${SOFT_FAIL_RC:=}"            # space/comma list of exit codes treated as soft
: "${SOFT_FAIL_THRESHOLD:=2}"    # mail once this many consecutive soft-fails accrue
: "${CRON_ALERT_STATE_DIR:=/run}"   # override for jobs whose user cannot write /run
# (qa-feed-sample runs as apache: an unwritable streak file would suppress the
#  alert PERMANENTLY, not throttle it, since the counter could never persist)
streak_file="${CRON_ALERT_STATE_DIR}/cron-alert.${tag}.softstreak"   # tmpfs default: reboot re-arms the streak

is_soft_rc() {
  local c
  for c in ${SOFT_FAIL_RC//,/ }; do [ "$c" = "$1" ] && return 0; done
  return 1
}

host="$(hostname -f 2>/dev/null || hostname)"
out="$(mktemp)"
# Separate file for the composed alert body: it is written once and then either
# mailed or discarded, and keeping it out of "$out" leaves the captured command
# output intact for the journal path.
body="$(mktemp)"
trap 'rm -f "$out" "$body"' EXIT

start="$(date +%s)"
"$@" >"$out" 2>&1
rc=$?
dur=$(( $(date +%s) - start ))

# One-line summary to the journal (previously these runs left NO record at all).
summary="$(grep -Ei 'installed|refreshed|aborting|refusing|only .* entries|WARNING|error|fail' "$out" | tail -1)"
logger -t "$tag" "rc=$rc dur=${dur}s ${summary:-done}"

# --- Recovery: a success clears any accrued soft-failure streak --------------
if [ "$rc" -eq 0 ]; then
  if [ -f "$streak_file" ]; then
    prev="$(cat "$streak_file" 2>/dev/null || echo 0)"
    rm -f "$streak_file"
    [ "${prev:-0}" -ge 1 ] && logger -t "$tag" "recovered after ${prev} consecutive soft failure(s)"
  fi
  exit 0
fi

# --- Non-zero: decide whether this failure is mail-worthy --------------------
soft_note=""
if is_soft_rc "$rc"; then
  streak="$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))"
  echo "$streak" > "$streak_file"
  if [ "$streak" -ne "$SOFT_FAIL_THRESHOLD" ]; then
    # below threshold (suppress) or past it (already alerted) -> journal only
    if [ "$streak" -lt "$SOFT_FAIL_THRESHOLD" ]; then
      logger -t "$tag" "soft failure (rc=$rc) streak=${streak}/${SOFT_FAIL_THRESHOLD}, suppressing mail"
    else
      logger -t "$tag" "soft failure (rc=$rc) streak=${streak}, mail already sent, suppressing"
    fi
    exit "$rc"
  fi
  # streak just reached the threshold -> alert once
  soft_note="${streak} consecutive soft failures (rc=$rc); earlier ones suppressed, further ones stay quiet until a successful run."
else
  # Hard failure: distinct event; reset the soft streak so it re-arms clean.
  rm -f "$streak_file"
fi

{
  echo "Command:  $*"
  echo "Host:     $host"
  echo "Exit:     $rc"
  echo "Duration: ${dur}s"
  echo "Time:     $(date '+%F %T %Z')"
  [ -n "$soft_note" ] && { echo; echo "Note:     $soft_note"; }
  echo
  echo "----- output (stdout+stderr) -----"
  cat "$out"
} > "$body"

# No recipient configured => journal only. Deliberately logs at the same point
# it would have mailed, so "did this fail?" stays answerable from the journal
# without notifications ever being switched on.
if [ -z "$MAILTO" ]; then
    logger -t "$tag" "FAILED (rc=$rc) — no alert recipient configured, journal only (set one in the console's Admin tab)"
    exit "$rc"
fi
mail -s "[$tag] FAILED (rc=$rc) on $host" "$MAILTO" < "$body"

exit "$rc"
