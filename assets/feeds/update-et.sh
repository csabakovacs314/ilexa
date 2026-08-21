#!/bin/bash
# update-et.sh — EmergingThreats compromised-IPs list → rspamd multimap (score-only).
set -uo pipefail
URL="https://rules.emergingthreats.net/blockrules/compromised-ips.txt"
DEST="/etc/rspamd/local.d/maps.d/emergingthreats.inc"
LOG="/var/log/feeds-refresh-et.log"
TMP="$(mktemp)"; CLEAN="$(mktemp)"
trap 'rm -f "$TMP" "$CLEAN" "$CLEAN.out"' EXIT
log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

if ! curl -fsS --max-time 90 "$URL" -o "$TMP"; then
    log "FETCH FAILED — keeping previous"; exit 1
fi
grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "$TMP" | /usr/local/sbin/ip-public-filter.py | sort -u > "$CLEAN"
n=$(wc -l < "$CLEAN")
if [ "$n" -lt 50 ]; then
    log "SANITY FAIL (only $n entries) — keeping previous"; exit 1
fi
{ echo "# EmergingThreats compromised-ips — auto-generated $(date '+%F %T') — $n entries — DO NOT EDIT"; cat "$CLEAN"; } > "$CLEAN.out"
install -m 0644 -o root -g root "$CLEAN.out" "$DEST"
log "OK $n entries"
