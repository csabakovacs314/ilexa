#!/bin/bash
# Rebuild the firewalld 'abuse_c2_block' ipset from abuse.ch C2 IP feeds:
#   - ThreatFox recent ip:port IOCs (confidence-filtered)
#   - Feodo Tracker IP blocklist (active botnet C2)
#
# These are individual malware C2 / payload-delivery IPs (not netblocks) with real
# churn/reassignment risk, so — like the OTX IP ipset and UNLIKE Spamhaus DROP —
# they are applied with per-service rich rules that EXCLUDE :25. The mail path is
# already covered by postscreen + rspamd, so keeping SMTP inbound off this block
# means a reassigned C2 IP can never bounce a legitimate sender; the value here is
# infra protection (web/mail-TLS/SSH/Webmin scanning + C2 callbacks), not spam.
# The one-time rich rules are added out of band (see update-abuse-c2.sh).
#
# Env toggles:
#   DRY_RUN=1        build to /tmp/abuse_c2_block.preview.xml, install nothing
#   TF_MIN_CONF=N    ThreatFox confidence floor (default 50)
set -euo pipefail

api_key_file="/etc/ilexa/secrets/abuse_api_key"
ipset_xml="/etc/firewalld/ipsets/abuse_c2_block.xml"
tf_url="https://threatfox.abuse.ch/export/csv/recent/"
feodo_url="https://feodotracker.abuse.ch/downloads/ipblocklist.txt"
min_entries=300                 # ThreatFox recent alone is typ. ~2000; refuse a broken fetch
min_conf="${TF_MIN_CONF:-50}"
api_timeout=45

[ -r "$api_key_file" ] || { echo "c2: cannot read $api_key_file" >&2; exit 1; }
key="$(cat "$api_key_file")"

tmp_tf="$(mktemp)"; tmp_feodo="$(mktemp)"; tmp_ips="$(mktemp)"; tmp_xml="$(mktemp)"
trap 'rm -f "$tmp_tf" "$tmp_feodo" "$tmp_ips" "$tmp_xml"' EXIT

curl_ac() { curl -s --fail --max-time "$api_timeout" --retry 3 --retry-delay 3 -H "Auth-Key: $key" "$@"; }

# --- 1. Fetch both feeds (fail-closed: a fetch error keeps the last-good set) ---
if ! curl_ac "$tf_url" -o "$tmp_tf"; then
  echo "c2: ThreatFox fetch failed" >&2; exit 75   # EX_TEMPFAIL
fi
# Feodo is best-effort (often only a handful of IPs, sometimes empty = valid).
curl_ac "$feodo_url" -o "$tmp_feodo" || : > "$tmp_feodo"

# --- 2. Parse ThreatFox CSV (ip:port IOCs, confidence >= floor) + Feodo IPs ----
TF_CSV="$tmp_tf" FEODO="$tmp_feodo" MIN_CONF="$min_conf" python3 - > "$tmp_ips" <<'PY'
import csv, os, ipaddress, sys
min_conf = int(os.environ["MIN_CONF"])
out = set()

def add_ip(tok):
    tok = tok.strip().strip('"').split(':', 1)[0].strip()   # drop :port
    if not tok:
        return
    try:
        ip = ipaddress.ip_address(tok)
    except ValueError:
        return
    if ip.version == 4 and ip.is_global:
        out.add(str(ip))

# ThreatFox CSV: leading '#' comment lines, then quoted rows. Columns (0-based):
# 2=ioc(ip:port), 3=ioc_type, 9=confidence.
with open(os.environ["TF_CSV"], newline='') as f:
    for row in csv.reader(f, skipinitialspace=True):
        if not row or row[0].lstrip().startswith('#'):
            continue
        if len(row) < 10:
            continue
        if row[3].strip() != 'ip:port':
            continue
        try:
            conf = int(row[9].strip() or 0)
        except ValueError:
            conf = 0
        if conf < min_conf:
            continue
        add_ip(row[2])

# Feodo plain list (CRLF), one IP per non-comment line.
try:
    with open(os.environ["FEODO"]) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                add_ip(line)
except FileNotFoundError:
    pass

for ip in out:
    print(ip)
PY

# Drop our own IPs (belt-and-suspenders; C2 feeds won't list us, but never self-block)
own="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]' || true)"
if [ -n "$own" ]; then
  grep -vxF "$own" "$tmp_ips" > "${tmp_ips}.f" 2>/dev/null || cp "$tmp_ips" "${tmp_ips}.f"
  mv "${tmp_ips}.f" "$tmp_ips"
fi

entry_count="$(sort -u "$tmp_ips" | tee "${tmp_ips}.u" >/dev/null; wc -l < "${tmp_ips}.u")"
mv "${tmp_ips}.u" "$tmp_ips"
echo "c2: $entry_count unique global C2 IPs (ThreatFox conf>=$min_conf + Feodo)" >&2

# --- 3. Guard against a bad/empty fetch wiping the live list ------------------
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "c2: only $entry_count entries (< $min_entries), aborting without changes" >&2
  exit 75
fi

# --- 4. Build ipset XML (hash:ip — individual IPs, not nets) ------------------
if [ -f "$ipset_xml" ]; then
  sed '/<entry>/,$d' "$ipset_xml" > "$tmp_xml"
else
  cat > "$tmp_xml" <<'HDR'
<?xml version="1.0" encoding="utf-8"?>
<ipset type="hash:ip">
  <short>abuse.ch C2</short>
  <description>abuse.ch ThreatFox + Feodo botnet C2 IPs, rebuilt by /usr/local/sbin/load-abuse-c2.sh. Applied per-service EXCLUDING :25.</description>
  <option name="hashsize" value="4096"/>
  <option name="maxelem" value="65536"/>
HDR
fi
sort -u "$tmp_ips" | sed 's|.*|  <entry>&</entry>|' >> "$tmp_xml"
echo '</ipset>' >> "$tmp_xml"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "c2: DRY_RUN — built $entry_count entries, not installing. Preview:" >&2
  grep -m5 '<entry>' "$tmp_xml" >&2
  cp "$tmp_xml" /tmp/abuse_c2_block.preview.xml
  echo "c2: full preview at /tmp/abuse_c2_block.preview.xml" >&2
  exit 0
fi

install -m 644 "$tmp_xml" "$ipset_xml"
command -v restorecon >/dev/null 2>&1 && restorecon "$ipset_xml" || true
echo "c2: installed $entry_count entries to $ipset_xml (run: firewall-cmd --reload)" >&2
