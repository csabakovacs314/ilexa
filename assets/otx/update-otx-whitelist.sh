#!/bin/bash
# Refresh the auto-maintained OTX whitelist (Cloudflare + Google crawler ranges)
# so the 6h blocklist rebuild never blocks these as they add new ranges.
# Writes /var/lib/ilexa/otx-whitelist-auto.txt ONLY if both fetches return a sane count;
# otherwise keeps the last-good file untouched (fail safe, never empties it).
set -euo pipefail

out="/var/lib/ilexa/otx-whitelist-auto.txt"
cf_url="https://www.cloudflare.com/ips-v4"
gb_url="https://developers.google.com/search/apis/ipranges/googlebot.json"
cf_min=10       # Cloudflare publishes ~15 IPv4 ranges
gb_min=50       # Googlebot JSON publishes ~150+ prefixes

tmp_cf="$(mktemp)"; tmp_gb="$(mktemp)"; tmp_out="$(mktemp)"
trap 'rm -f "$tmp_cf" "$tmp_gb" "$tmp_out"' EXIT

curl -sL --max-time 30 "$cf_url" -o "$tmp_cf"
curl -sL --max-time 30 "$gb_url" -o "$tmp_gb"

cf_n="$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$tmp_cf" || true)"
gb_n="$(jq -r '.prefixes[].ipv4Prefix // empty' "$tmp_gb" 2>/dev/null | grep -c . || true)"

if [ "$cf_n" -lt "$cf_min" ] || [ "$gb_n" -lt "$gb_min" ]; then
  echo "otx-wl: unhealthy fetch (cf=$cf_n gb=$gb_n) — keeping last-good $out" >&2
  exit 1
fi

{
  echo "# OTX whitelist (auto-refreshed by /usr/bin/update-otx-whitelist.sh)"
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). DO NOT edit by hand — see otx-whitelist.txt."
  echo ""
  echo "# --- Cloudflare IPv4 ($cf_n ranges) ---"
  grep -E '^[0-9]' "$tmp_cf"
  echo ""
  echo "# --- Googlebot / Google crawlers ($gb_n prefixes) ---"
  jq -r '.prefixes[].ipv4Prefix // empty' "$tmp_gb"
} > "$tmp_out"

install -m 644 "$tmp_out" "$out"
echo "otx-wl: refreshed $out (cf=$cf_n gb=$gb_n)" >&2
