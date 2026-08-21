#!/bin/bash
# otx-rbldnsd-sync.sh — regenerate the rbldnsd "otx.rbl" zone from the live
# firewalld otx_block ipset and reload rbldnsd.
#
# The firewalld ipset (/etc/firewalld/ipsets/otx_block.xml) is the authoritative,
# already-whitelisted (Cloudflare/Google/self/private excluded by load-otx.sh) OTX
# IP set. We derive the postscreen DNSBL zone from it so both stay in sync and the
# whitelist is inherited for free. See memory: firewalld-otx / otx-sa-uri.
#
# postscreen uses this as a WEIGHTED DNSBL below threshold (otx.rbl*2, threshold 3)
# — it adds signal but can never block inbound mail on its own. FP-safe by design.
set -euo pipefail

SRC=/etc/firewalld/ipsets/otx_block.xml
ZONEDIR=/var/lib/rbldnsd
ZONEFILE="$ZONEDIR/otx.rbl"
MIN_ENTRIES=350            # same floor as load-otx.sh; below this, keep last-good
TMP="$(mktemp "${ZONEFILE}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

[ -r "$SRC" ] || { echo "otx-rbldnsd-sync: cannot read $SRC" >&2; exit 1; }

# Extract IP/CIDR entries from the ipset XML (<entry>1.2.3.4</entry>).
mapfile -t ENTRIES < <(grep -oP '(?<=<entry>)[^<]+' "$SRC" | sort -u)
COUNT=${#ENTRIES[@]}

if [ "$COUNT" -lt "$MIN_ENTRIES" ]; then
    echo "otx-rbldnsd-sync: only $COUNT entries (< $MIN_ENTRIES floor) — keeping last-good zone, not reloading" >&2
    exit 1
fi

{
    echo "\$SOA 1800 ns.otx.rbl. hostmaster.otx.rbl. 0 3600 1800 604800 1800"
    echo "\$NS 1800 ns.otx.rbl."
    echo "\$TTL 1800"
    echo ":127.0.0.2:OTX listed (AlienVault malicious IP)"
    printf '%s\n' "${ENTRIES[@]}"
    # Permanent liveness sentinel (probed by /usr/bin/rbldnsd-liveness.sh). 127.0.0.2
    # is the canonical DNSBL self-test address; load-otx.sh drops non-global IPs so
    # OTX can never supply it, keeping it uniquely ours. Not routable => postscreen
    # never queries it in production; it exists solely so the probe has a stable target.
    echo "127.0.0.2"
} > "$TMP"

install -o rbldns -g rbldns -m 0644 "$TMP" "$ZONEFILE"
rm -f "$TMP"; trap - EXIT

# Reload the instance (rbldnsd re-reads on SIGHUP; also auto-checks every -c interval).
if systemctl is-active --quiet rbldnsd-otx.service; then
    systemctl reload rbldnsd-otx.service
fi

echo "otx-rbldnsd-sync: wrote $COUNT entries to $ZONEFILE and reloaded rbldnsd-otx"
