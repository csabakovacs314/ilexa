#!/bin/bash
# update-firehol.sh — FireHOL level1 IP blocklist → rspamd multimap (score-only).
# Conservative list (Spamhaus DROP, DShield top attackers, known bad /24s). Atomic install;
# rspamd hot-reloads the map on mtime change. Keeps the previous map on any failure.
set -uo pipefail
URL="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
DEST="/etc/rspamd/local.d/maps.d/firehol.inc"
LOG="/var/log/feeds-refresh-firehol.log"
TMP="$(mktemp)"; CLEAN="$(mktemp)"
trap 'rm -f "$TMP" "$CLEAN" "$CLEAN.out"' EXIT
log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

if ! curl -fsS --max-time 90 "$URL" -o "$TMP"; then
    log "FETCH FAILED — keeping previous"; exit 1
fi
grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' "$TMP" | /usr/local/sbin/ip-public-filter.py | sort -u > "$CLEAN"
n=$(wc -l < "$CLEAN")
if [ "$n" -lt 100 ]; then
    log "SANITY FAIL (only $n entries) — keeping previous"; exit 1
fi
{ echo "# FireHOL level1 — auto-generated $(date '+%F %T') — $n entries — DO NOT EDIT"; cat "$CLEAN"; } > "$CLEAN.out"
install -m 0644 -o root -g root "$CLEAN.out" "$DEST"
log "OK $n entries"
