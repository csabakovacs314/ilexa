#!/bin/bash
# Rebuild the firewalld 'otx_block' ipset from AlienVault OTX subscribed pulses.
# Pulls IPv4 / CIDR indicators from pulses modified in the last $LOOKBACK_DAYS days
# (the heavy /pulses/subscribed endpoint 504s, so we enumerate pulse IDs cheaply and
# fetch each pulse's indicators separately). Writes the permanent ipset definition;
# apply it with 'firewall-cmd --reload'.
#
# Env toggles:
#   DRY_RUN=1        build to a temp file and print stats, install nothing
#   LOOKBACK_DAYS=N  override the rolling window (default 30)
set -euo pipefail

api_key_file="/etc/ilexa/secrets/otx_api_key"
ipset_xml="/etc/firewalld/ipsets/otx_block.xml"
# Whitelist: hand-maintained infra file + auto-refreshed CF/Google file (see
# /usr/bin/update-otx-whitelist.sh). Both are CIDR-aware.
whitelist_static="/var/lib/ilexa/otx-whitelist.txt"
whitelist_auto="/var/lib/ilexa/otx-whitelist-auto.txt"
lookback_days="${LOOKBACK_DAYS:-30}"
min_entries=350                               # refuse to install a suspiciously small list (typ. ~700)
min_whitelist_nets=50                         # fail closed if the whitelist didn't load (CF+Google alone ~185)
api="https://otx.alienvault.com/api/v1"

[ -r "$api_key_file" ] || { echo "otx: cannot read $api_key_file" >&2; exit 1; }
key="$(cat "$api_key_file")"

# --fail: HTTP >=400 (e.g. OTX's frequent 504) returns non-zero so it hits the
# guards below instead of feeding a 504 HTML page to jq and aborting under set -e.
curl_otx() { curl -s --fail -H "X-OTX-API-KEY: $key" --max-time 60 --retry 3 --retry-delay 3 "$@"; }

tmp_ids="$(mktemp)"; tmp_ips="$(mktemp)"; tmp_xml="$(mktemp)"
trap 'rm -f "$tmp_ids" "$tmp_ips" "$tmp_xml"' EXIT

since="$(date -u -d "${lookback_days} days ago" +%Y-%m-%dT%H:%M:%S)"

# --- 1. Enumerate subscribed pulse IDs modified within the window -------------
url="${api}/pulses/subscribed_pulse_ids?modified_since=${since}&limit=500"
pages=0
while [ -n "$url" ] && [ "$url" != "null" ]; do
  resp="$(curl_otx "$url")" || { echo "otx: pulse-id fetch failed, stopping enumeration" >&2; break; }
  echo "$resp" | jq -r '.results[]?' 2>/dev/null >> "$tmp_ids" || true
  url="$(echo "$resp" | jq -r '.next // ""' 2>/dev/null)" || url=""
  pages=$((pages + 1))
  [ "$pages" -gt 200 ] && break   # safety stop
done
pulse_count="$(wc -l < "$tmp_ids")"
echo "otx: $pulse_count pulses modified since ${since} (${lookback_days}d window)" >&2

# --- 2. Pull IPv4 / CIDR indicators from each pulse --------------------------
failed=0
while read -r pid; do
  [ -n "$pid" ] || continue
  purl="${api}/pulses/${pid}/indicators?limit=1000"
  guard=0
  while [ -n "$purl" ] && [ "$purl" != "null" ]; do
    presp="$(curl_otx "$purl")" || { failed=$((failed + 1)); break; }
    echo "$presp" | jq -r '.results[]? | select(.type=="IPv4" or .type=="CIDR") | .indicator' 2>/dev/null >> "$tmp_ips" || true
    purl="$(echo "$presp" | jq -r '.next // ""' 2>/dev/null)" || purl=""
    guard=$((guard + 1)); [ "$guard" -gt 50 ] && break
  done
done < "$tmp_ids"
[ "$failed" -gt 0 ] && echo "otx: WARNING $failed pulse indicator fetches failed" >&2

# --- 3. Clean: dedupe, drop non-global (private/reserved), self, whitelist ----
# CIDR-aware: a whitelist entry like 172.70.0.0/16 must exclude individual IPs
# such as 172.70.46.121 (Cloudflare egress), so exact-match grep is not enough.
own_ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]' || true)"
{
  echo "$own_ips"
  [ -r "$whitelist_static" ] && cat "$whitelist_static" || true
  [ -r "$whitelist_auto" ]   && cat "$whitelist_auto"   || true
} > "${tmp_ips}.wl"

OTX_WL="${tmp_ips}.wl" OTX_MIN_WL="$min_whitelist_nets" python3 - "$tmp_ips" > "${tmp_ips}.clean" <<'PY'
import ipaddress, os, sys
wl = []
with open(os.environ["OTX_WL"]) as f:
    for line in f:
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        try:
            wl.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            pass
# Fail closed: never build the blocklist against an empty/broken whitelist,
# or Cloudflare/Googlebot ranges would get blocked and break the website.
if len(wl) < int(os.environ["OTX_MIN_WL"]):
    sys.stderr.write("otx: whitelist only %d nets (< %s) — refusing to build\n" % (len(wl), os.environ["OTX_MIN_WL"]))
    sys.exit(3)
seen = set()
with open(sys.argv[1]) as f:
    for line in f:
        tok = line.strip()
        if not tok or tok in seen:
            continue
        seen.add(tok)
        try:
            net = ipaddress.ip_network(tok, strict=False)
        except ValueError:
            continue
        if net.version != 4 or not net.is_global:   # is_global drops private/reserved/loopback/link-local/multicast
            continue
        if any(net.overlaps(w) for w in wl):
            continue
        print(tok)
PY
rm -f "${tmp_ips}.wl"

entry_count="$(wc -l < "${tmp_ips}.clean")"
echo "otx: $entry_count unique IPv4/CIDR indicators after cleaning" >&2

# --- 4. Guard against a bad/empty fetch wiping the live list -----------------
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "otx: only $entry_count entries (< $min_entries), aborting without changes" >&2
  # EX_TEMPFAIL: a below-floor result means OTX was degraded this run (slow /
  # 504ing pulses dropped indicators); last-good set stays live and it usually
  # self-heals next run. Distinct code so cron-alert.sh can treat it as a
  # transient/soft failure (edge-triggered mail) vs. a hard config failure.
  exit 75
fi

# --- 5. Build the ipset XML (preserve existing header/options) ---------------
if [ -f "$ipset_xml" ]; then
  sed '/<entry>/,$d' "$ipset_xml" > "$tmp_xml"
else
  cat > "$tmp_xml" <<'HDR'
<?xml version="1.0" encoding="utf-8"?>
<ipset type="hash:net">
  <short>OTX malicious IPs</short>
  <description>AlienVault OTX IOC IPs, rebuilt from subscribed pulses by /usr/local/sbin/load-otx.sh</description>
  <option name="hashsize" value="4096"/>
  <option name="maxelem" value="65536"/>
HDR
fi
sed 's|.*|  <entry>&</entry>|' "${tmp_ips}.clean" >> "$tmp_xml"
echo '</ipset>' >> "$tmp_xml"
rm -f "${tmp_ips}.clean"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "otx: DRY_RUN — built $entry_count entries, not installing. Preview:" >&2
  grep -m5 '<entry>' "$tmp_xml" >&2
  cp "$tmp_xml" /tmp/otx_block.preview.xml
  echo "otx: full preview at /tmp/otx_block.preview.xml" >&2
  exit 0
fi

install -m 644 "$tmp_xml" "$ipset_xml"
command -v restorecon >/dev/null 2>&1 && restorecon "$ipset_xml" || true
echo "otx: installed $entry_count entries to $ipset_xml" >&2
