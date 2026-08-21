#!/bin/bash
# Firewall blocking report for this mail server.
# Summarises the two firewalld drop ipsets: geoblock (country CIDRs) and
# otx_block (AlienVault OTX malicious IPs). Read-only; run anytime.
#   /usr/bin/firewall-report.sh            # to screen
#   /usr/bin/firewall-report.sh > report.txt
set -uo pipefail

geoblock_loader="/usr/local/sbin/load-countries.sh"
otx_xml="/etc/firewalld/ipsets/otx_block.xml"
otx_rbl_zone="/var/lib/rbldnsd/otx.rbl"
rbldnsd_svc="rbldnsd-otx.service"

# country code -> name (extend as needed)
country_name() {
  case "$1" in
    ru) echo "Russia" ;;      cn) echo "China" ;;
    br) echo "Brazil" ;;      kr) echo "South Korea" ;;
    us) echo "United States";; in) echo "India" ;;
    *)  echo "${1^^}" ;;
  esac
}

# blocked services/ports for a given ipset, parsed from the live rich-rules
blocked_targets() {
  firewall-cmd --list-rich-rules 2>/dev/null \
    | grep "ipset=\"$1\"" \
    | sed -E 's/.*service name="([^"]+)".*/\1/; s/.*port port="([0-9]+)".*/port \1/' \
    | paste -sd' ' -
}

ipset_count() { firewall-cmd --info-ipset="$1" 2>/dev/null | tr ' ' '\n' | grep -cE '^[0-9]+\.[0-9]'; }

echo "=================================================================="
echo " FIREWALL BLOCKING REPORT — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "=================================================================="

# ---------------------------------------------------------------- geoblock ---
echo
echo "### GEO-BLOCK (country networks) #################################"
countries="$(grep -E '^countries=' "$geoblock_loader" 2>/dev/null | cut -d'"' -f2)"
geo_total="$(ipset_count geoblock)"
echo "Blocked on: $(blocked_targets geoblock)"
echo "Total networks: ${geo_total}"
echo
printf "  %-14s %-6s %10s\n" "Country" "Code" "CIDRs"
printf "  %-14s %-6s %10s\n" "-------" "----" "-----"
for c in $countries; do
  zf="/var/lib/ilexa/geoip/${c}.zone"
  n="n/a"; [ -r "$zf" ] && n="$(grep -cE '^[0-9]' "$zf")"
  printf "  %-14s %-6s %10s\n" "$(country_name "$c")" "$c" "$n"
done
echo "  (per-country counts from the last geoblock refresh; zone files in /root)"

# --------------------------------------------------------------- otx_block ---
echo
echo "### OTX MALICIOUS-IP BLOCK #######################################"
otx_total="$(ipset_count otx_block)"
otx_when="$( [ -f "$otx_xml" ] && date -r "$otx_xml" '+%Y-%m-%d %H:%M:%S' || echo unknown )"
echo "Blocked on: $(blocked_targets otx_block)"
echo "Total IPs: ${otx_total}"
echo "Last refresh: ${otx_when} (source: AlienVault OTX, rolling 30-day window)"
echo
echo "  Top source /24 networks:"
firewall-cmd --info-ipset=otx_block 2>/dev/null | tr ' ' '\n' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed -E 's/\.[0-9]+$/.0\/24/' | sort | uniq -c | sort -rn | head -8 \
  | awk '{printf "    %-20s %s IP(s)\n", $2, $1}'

# ---------------------------------------------- otx port-25 DNSBL (rbldnsd) ---
# Same OTX IPs served to postscreen as a soft-weight DNSBL on inbound port 25
# (which the firewalld block deliberately excludes). READ-ONLY probe: query the
# sentinel directly on rbldnsd's :530 — do NOT restart (that is the liveness cron's
# job). A daemon that is systemd-active but HUNG shows as active + NOT ANSWERING.
echo
echo "### OTX PORT-25 DNSBL (postscreen / rbldnsd) #####################"
rbl_state="$(systemctl is-active "$rbldnsd_svc" 2>/dev/null || true)"
rbl_answer="$(dig +short +time=3 +tries=1 -p 530 @127.0.0.1 2.0.0.127.otx.rbl A 2>/dev/null)"
[ "$rbl_answer" = "127.0.0.2" ] && rbl_live="answering (sentinel OK)" || rbl_live="NOT ANSWERING"
rbl_entries="$( [ -r "$otx_rbl_zone" ] && grep -cE '^[0-9]' "$otx_rbl_zone" || echo n/a )"
rbl_when="$( [ -f "$otx_rbl_zone" ] && date -r "$otx_rbl_zone" '+%Y-%m-%d %H:%M:%S' || echo unknown )"
ps_site="$(postconf -h postscreen_dnsbl_sites 2>/dev/null | tr ' ' '\n' | grep -E '^otx\.rbl\*' | head -1)"
ps_thr="$(postconf -h postscreen_dnsbl_threshold 2>/dev/null)"
echo "Purpose: soft-weight DNSBL on inbound port 25 (firewalld block excludes 25)"
echo "Service: ${rbldnsd_svc} = ${rbl_state:-unknown}   |   Liveness: ${rbl_live}"
echo "Zone entries: ${rbl_entries} (incl. 1 liveness sentinel 127.0.0.2)"
echo "Last refresh: ${rbl_when} (derived from otx_block ipset)"
echo "postscreen: ${ps_site:-<not configured>} (threshold ${ps_thr:-?} — adds signal, never blocks alone)"
[ -e /run/rbldnsd-liveness.alerted ] && \
  echo "  ** OUTAGE ALERT ACTIVE: liveness monitor flagged an unrecovered failure **"

# ------------------------------------------------------------------- totals ---
echo
echo "### TOTAL ########################################################"
echo "Combined blocked networks (geoblock + otx_block): $(( geo_total + otx_total ))"
echo "=================================================================="
