#!/bin/bash
# update-dshield.sh — DShield/SANS ISC top-attacker list → rspamd multimap (score-only).
# Top 20 currently-attacking /24 subnets (by targets-scanned), refreshed by DShield every
# few hours. Atomic install; rspamd hot-reloads the map on mtime change. Keeps the
# previous map on any failure.
set -uo pipefail
URL="https://www.dshield.org/block.txt"
DEST="/etc/rspamd/local.d/maps.d/dshield.inc"
LOG="/var/log/feeds-refresh-dshield.log"
TMP="$(mktemp)"; CLEAN="$(mktemp)"
trap 'rm -f "$TMP" "$CLEAN" "$CLEAN.out"' EXIT
log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

if ! curl -fsS --max-time 90 "$URL" -o "$TMP"; then
    log "FETCH FAILED — keeping previous"; exit 1
fi
grep -v '^#' "$TMP" | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /^[0-9]+$/ {print $1"/"$3}' \
    | /usr/local/sbin/ip-public-filter.py | sort -u > "$CLEAN"
n=$(wc -l < "$CLEAN")
# List is naturally tiny (top-20 subnets) -- 100/50-entry guards used by sibling
# feeds would always fail here, so this one gets its own, much lower bar.
if [ "$n" -lt 10 ]; then
    log "SANITY FAIL (only $n entries) — keeping previous"; exit 1
fi
{ echo "# DShield/SANS ISC top attackers — auto-generated $(date '+%F %T') — $n entries — DO NOT EDIT"; cat "$CLEAN"; } > "$CLEAN.out"
install -m 0644 -o root -g root "$CLEAN.out" "$DEST"
log "OK $n entries"
