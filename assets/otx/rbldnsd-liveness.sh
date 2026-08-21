#!/bin/bash
# rbldnsd-liveness.sh — end-to-end liveness probe for the otx.rbl DNSBL that feeds
# postscreen (see memory: otx-rbldnsd-dnsbl). Catches the failure nothing else does:
# an rbldnsd-otx that is "active" per systemd but HUNG (not answering). rbldnsd has
# no sd_notify watchdog, so systemd's Restart=on-failure only covers a clean crash.
#
# HOW: query the permanent sentinel 127.0.0.2 (reversed => 2.0.0.127.otx.rbl), which
# otx-rbldnsd-sync.sh always writes into the zone, and expect the answer 127.0.0.2.
#
# ★ Probe rbldnsd DIRECTLY on 127.0.0.1:530, NOT through unbound. unbound caches the
#   stub-zone answer for the zone TTL (1800s) with no stub-no-cache, so a probe via
#   unbound would keep returning a CACHED 127.0.0.2 for up to 30 min after rbldnsd
#   died — blind to exactly the hang this monitor exists to catch. Direct-to-:530 is
#   cache-immune and detects immediately. (The unbound->rbldnsd hop is static config
#   that doesn't spontaneously hang; if unbound itself is down, every DNSBL fails and
#   that's a separate, louder alarm.)
#
# On failure: reset-failed (in case a start-limit trip would refuse the restart),
# restart rbldnsd-otx once, re-probe.
#   - recovered by restart -> journal WARNING, exit 0 (self-healed, no mail)
#   - still not answering  -> exit non-zero -> cron-alert.sh mails root
#
# FIRST-FAILURE-ONLY alerting: the still-down path exits non-zero (=> mail) only on
# the FIRST cron run of an outage; while the outage persists, later runs exit 0
# (journal only, no repeat mail). Recovery clears the flag and re-arms the alert.
# State flag lives in /run (tmpfs) so a reboot re-arms — a persistent outage across
# a reboot is worth one fresh alert. Invoked from cron via /usr/bin/cron-alert.sh.
# NO 'set -e' (failures handled explicitly).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SVC=rbldnsd-otx.service
SENTINEL_Q=2.0.0.127.otx.rbl   # reverse of sentinel IP 127.0.0.2
EXPECT=127.0.0.2
PORT=530                        # rbldnsd's own listener (cache-immune)
FLAG=/run/rbldnsd-liveness.alerted   # edge-trigger: present == already alerted this outage

# probe() -> 0 iff rbldnsd answers the sentinel with EXPECT (queried directly).
probe() {
    local ans
    ans="$(dig +short +time=3 +tries=1 -p "$PORT" @127.0.0.1 "$SENTINEL_Q" A 2>/dev/null)"
    [ "$ans" = "$EXPECT" ]
}

if probe; then
    if [ -e "$FLAG" ]; then
        rm -f "$FLAG"
        echo "rbldnsd-live: RECOVERED — otx.rbl DNSBL answering again on :$PORT" >&2
    fi
    exit 0
fi

echo "rbldnsd-live: sentinel $SENTINEL_Q did not return $EXPECT from rbldnsd on :$PORT — DNSBL not answering; restarting $SVC" >&2
systemctl reset-failed "$SVC" 2>/dev/null
systemctl restart "$SVC"
sleep 3

if probe; then
    if [ -e "$FLAG" ]; then
        rm -f "$FLAG"
        echo "rbldnsd-live: RECOVERED — $SVC was down, restart succeeded; DNSBL answering again" >&2
    else
        echo "rbldnsd-live: WARNING — $SVC was not answering and was restarted; otx.rbl DNSBL recovered" >&2
    fi
    exit 0
fi

# Still not answering after a restart. Alert ONCE per outage: mail on the first run
# that sees it, journal-only thereafter until recovery clears the flag (re-arming).
if [ -e "$FLAG" ]; then
    echo "rbldnsd-live: $SVC STILL down (already alerted this outage — journal only, suppressing repeat mail)" >&2
    exit 0
fi
: > "$FLAG"
echo "rbldnsd-live: $SVC STILL not answering after restart — otx.rbl DNSBL DOWN. postscreen loses only the OTX port-25 signal (weight 2 < threshold 3); mail still flows (fail-open). Alerting once; further failures journal-only until recovery." >&2
systemctl status "$SVC" --no-pager 2>&1 | head -12 >&2
exit 1
