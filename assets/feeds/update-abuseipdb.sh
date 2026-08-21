#!/bin/bash
# update-abuseipdb.sh — AbuseIPDB blacklist (confidence>=90) → rspamd multimap (score-only).
# Needs an API key in /etc/ilexa/secrets/abuseipdb_key (0600). If the key is absent it exits 0 quietly so
# the feed simply stays empty until a key is provided. Atomic install; keeps previous on failure.
set -uo pipefail
KEYFILE="/etc/ilexa/secrets/abuseipdb_key"
CONF_MIN="${ABUSEIPDB_CONF:-90}"
DEST="/etc/rspamd/local.d/maps.d/abuseipdb.inc"
LOG="/var/log/feeds-refresh-abuseipdb.log"
TMP="$(mktemp)"; CLEAN="$(mktemp)"
trap 'rm -f "$TMP" "$CLEAN" "$CLEAN.out"' EXIT
log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

if [ ! -r "$KEYFILE" ]; then
    log "NO KEY ($KEYFILE) — skipping (feed stays as-is)"; exit 0
fi
KEY="$(tr -d '[:space:]' < "$KEYFILE")"
if [ -z "$KEY" ]; then log "EMPTY KEY — skipping"; exit 0; fi

if ! curl -fsS --max-time 90 -G "https://api.abuseipdb.com/api/v2/blacklist" \
        --data-urlencode "confidenceMinimum=${CONF_MIN}" \
        -H "Key: ${KEY}" -H "Accept: text/plain" -o "$TMP"; then
    log "FETCH FAILED (check key / plan limit) — keeping previous"; exit 1
fi
grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' "$TMP" | /usr/local/sbin/ip-public-filter.py | sort -u > "$CLEAN"
n=$(wc -l < "$CLEAN")
if [ "$n" -lt 20 ]; then
    log "SANITY FAIL (only $n entries; API error?) — keeping previous"; exit 1
fi
{ echo "# AbuseIPDB confidence>=${CONF_MIN} — auto-generated $(date '+%F %T') — $n entries — DO NOT EDIT"; cat "$CLEAN"; } > "$CLEAN.out"
install -m 0644 -o root -g root "$CLEAN.out" "$DEST"
log "OK $n entries"
