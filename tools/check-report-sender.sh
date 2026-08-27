#!/usr/bin/env bash
#
# check-report-sender.sh — verify the spam/ham report handler's sender gate.
#
# THE BUG CLASS THIS EXISTS FOR. The gate decides who may train the Bayes
# classifier every user on the server depends on. It used to check only that
# the envelope sender's DOMAIN was local, so "nobody@hernad.hu" — an address
# that does not exist — could mail ham@ with spam content and teach the filter
# to accept spam. The envelope sender is asserted by whoever connects; nothing
# upstream on the reference host rejects a forged local one (policyd-spf runs
# TestOnly=1, the domains publish ~all).
#
# So this pins the decision table, including the two fail-closed cases: an
# allow-list that is missing or empty must DENY, never fall back to the weaker
# domain check.
#
# Runs against a COPY of the handler with its three paths redirected into a
# temp tree — no test seam is added to the shipped file, which runs privileged.
# Nothing here reaches rspamd: every case is either denied at the gate, or (for
# the one address that must be accepted) passes the gate and then stops on a
# report carrying no original to learn.
#
#   tools/check-report-sender.sh [--quiet]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/assets/report/rspamd-report-learn"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

[ -r "$SRC" ] || { echo "check-report-sender: cannot read $SRC" >&2; exit 2; }

T=$(mktemp -d /tmp/check-report-sender.XXXXXX) || exit 2
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT

sed -e "s#'/etc/rspamd-report/domains.txt'#'$T/domains.txt'#" \
    -e "s#'/etc/rspamd-report/senders.txt'#'$T/senders.txt'#" \
    -e "s#'/var/lib/rspamd-report'#'$T/state'#" \
    -e "s#'/var/spool/rspamd-report-denied'#'$T/denied'#" \
    "$SRC" > "$T/handler.py"
python3 -m py_compile "$T/handler.py" || { echo "check-report-sender: handler does not compile"; exit 1; }

printf 'hernad.hu\nlinuxforum.hu\n'                > "$T/domains.txt"
printf 'real@hernad.hu\nother@linuxforum.hu\n'     > "$T/senders.txt"
# No message/rfc822 part: an accepted sender therefore stops at "no original",
# which proves the gate passed without anything being learned.
printf 'From: u\nSubject: r\n\nplain body\n'       > "$T/report.eml"

pass=0; fail=0
# The handler logs its decision to syslog and always exits 0. Capture the
# decision by monkey-patching syslog in a wrapper rather than reading journald,
# which needs privileges this may not have and is racy.
verdict() { # class sender -> decision text
    python3 - "$T/handler.py" "$1" "$2" "$T/report.eml" <<'PY' 2>&1
import sys, syslog, runpy
mod, cls, sender, report = sys.argv[1:5]
seen = []
syslog.openlog = lambda *a, **k: None
syslog.syslog  = lambda *a: seen.append(a[-1])
sys.argv = ['handler', cls, sender]
sys.stdin = open(report, 'rb')
class B:            # the handler reads sys.stdin.buffer
    buffer = sys.stdin
sys.stdin = B()
try:
    runpy.run_path(mod, run_name='__main__')
except SystemExit:
    pass
print(seen[-1] if seen else '(no decision logged)')
PY
}
ok() { # label expected-substring actual
    if [[ "$3" == *"$2"* ]]; then
        pass=$((pass+1)); [ "$QUIET" = 1 ] || printf '  ok   %s\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL %s\n         wanted ~%q\n         got    %q\n' "$1" "$2" "$3"
    fi
}

# ---- the address gate ------------------------------------------------------
ok "a real mailbox passes the sender gate" \
   "no message/rfc822 attachment" "$(verdict spam real@hernad.hu)"
ok "a NON-EXISTENT address at a local domain is denied (the poisoning path)" \
   "not an active mailbox" "$(verdict spam nobody@hernad.hu)"
ok "a forged address at another local domain is denied" \
   "not an active mailbox" "$(verdict ham forged@linuxforum.hu)"
ok "a foreign domain is denied before the address check" \
   "not an internal domain" "$(verdict spam evil@elsewhere.com)"
ok "an empty sender is denied" \
   "not an internal domain" "$(verdict spam '')"
ok "a bare local-part with no domain is denied" \
   "not an internal domain" "$(verdict spam nobody)"
ok "case is folded, so a mixed-case real mailbox still passes" \
   "no message/rfc822 attachment" "$(verdict spam REAL@Hernad.HU)"

# ---- fail closed -----------------------------------------------------------
: > "$T/senders.txt"
ok "an EMPTY allow-list denies, and says so distinctly" \
   "allow-list unavailable" "$(verdict spam real@hernad.hu)"
rm -f "$T/senders.txt"
ok "a MISSING allow-list denies rather than falling back to the domain check" \
   "allow-list unavailable" "$(verdict spam real@hernad.hu)"
printf 'real@hernad.hu\n' > "$T/senders.txt"
: > "$T/domains.txt"
ok "an empty domain list denies every report" \
   "no reportable domains" "$(verdict spam real@hernad.hu)"

# ── refused reports must not silently vanish ────────────────────────────────
#
# The handler is a Postfix pipe that exits 0 on every path, which tells Postfix
# "delivered". Every refusal therefore DESTROYS the user's message unless it is
# spooled first. These pin which refusals keep the message and, just as
# importantly, which must not: spooling foreign-domain reports would let anyone
# fill this disk by mailing ham@ in a loop, trading mail loss for an outage.
spooled() { find "$T/denied" -type f 2>/dev/null | wc -l | tr -d ' '; }

# The gate tests above deliberately empty these to prove the fail-closed paths,
# and leave them that way. Restore them, or every assertion below silently
# measures the "our fault, list is broken" branch instead of the one named.
printf 'hernad.hu\nlinuxforum.hu\n'            > "$T/domains.txt"
printf 'real@hernad.hu\nother@linuxforum.hu\n' > "$T/senders.txt"

rm -rf "$T/denied"; verdict spam real@hernad.hu >/dev/null
ok "a verified reporter's inline forward is KEPT, not binned" 1 "$(spooled)"

rm -rf "$T/denied"; verdict ham nobody@hernad.hu >/dev/null
ok "a local-domain refusal is KEPT for review" 1 "$(spooled)"

rm -rf "$T/denied"; verdict ham attacker@evil.example >/dev/null
ok "a FOREIGN-domain refusal is discarded (disk-fill guard)" 0 "$(spooled)"

rm -rf "$T/denied"; mv "$T/senders.txt" "$T/senders.off"
verdict ham real@hernad.hu >/dev/null
ok "an our-fault list failure keeps the message" 1 "$(spooled)"
mv "$T/senders.off" "$T/senders.txt"

# The spool must be bounded, or preserving becomes its own outage.
rm -rf "$T/denied"; mkdir -p "$T/denied"
i=0; while [ $i -lt 205 ]; do : > "$T/denied/old-$i.eml"; i=$((i+1)); done
verdict ham nobody@hernad.hu >/dev/null
n=$(spooled); [ "$n" -le 200 ] && n=capped
ok "the spool is capped, so preserving cannot fill the disk" capped "$n"

rm -rf "$T/denied"; verdict ham nobody@hernad.hu >/dev/null
ok "the spool directory is private (0700)" 700 "$(stat -c%a "$T/denied" 2>/dev/null)"
ok "a preserved report is private (0600)" 600 \
   "$(stat -c%a "$(find "$T/denied" -type f | head -1)" 2>/dev/null)"

[ "$QUIET" = 1 ] && [ "$fail" = 0 ] || echo "check-report-sender: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
