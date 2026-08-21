#!/bin/bash
# Rebuild the firewalld 'spamhaus_drop' ipset from the Spamhaus DROP list.
#
# DROP (Don't Route Or Peer) is Spamhaus's most conservative list: netblocks that
# are hijacked or wholly criminal-operated, published specifically for firewall/BGP
# DROP of ALL traffic. Legitimate mail essentially cannot originate from these by
# definition, so — unlike the noisy OTX ipset which excludes :25 and only nudges
# the spam score — this list is applied as a plain all-ports source-drop rich rule
# (added once, out of band; see the header comment for the exact command).
#
# NO whitelist: DROP is authoritative and hyper-conservative; second-guessing it
# with a whitelist would be needless complexity. We keep only the fail-closed
# empty/small-list guard so a broken fetch never wipes the live set.
#
# Env toggles:
#   DRY_RUN=1        build to /tmp/spamhaus_drop.preview.xml and print stats, install nothing
#   DROP_URL=...     override source URL (default the combined IPv4 DROP JSON)
#
# Apply a freshly-written set with: firewall-cmd --reload
# One-time rich rule (all ports, inbound source drop):
#   firewall-cmd --permanent \
#     --add-rich-rule='rule family="ipv4" source ipset="spamhaus_drop" drop'
set -euo pipefail

ipset_xml="/etc/firewalld/ipsets/spamhaus_drop.xml"
drop_url="${DROP_URL:-https://www.spamhaus.org/drop/drop_v4.json}"
min_entries=1000        # DROP combined is ~1600; refuse a suspiciously small/broken fetch
api_timeout=45

tmp_json="$(mktemp)"; tmp_cidr="$(mktemp)"; tmp_xml="$(mktemp)"
trap 'rm -f "$tmp_json" "$tmp_cidr" "$tmp_xml"' EXIT

# --- 1. Fetch the DROP JSON (JSONL: one {cidr,sblid,rir} per line + a trailing
#        {"type":"metadata",...} line). --fail so an HTTP error hits the guards
#        below instead of feeding an error page to jq under set -e.
if ! curl -s --fail --max-time "$api_timeout" --retry 3 --retry-delay 3 "$drop_url" -o "$tmp_json"; then
  echo "drop: fetch failed ($drop_url)" >&2
  exit 75   # EX_TEMPFAIL: transient source problem, keep last-good set (see cron wrapper)
fi

# --- 2. Extract CIDRs, skip the metadata line ---------------------------------
jq -r 'select(.cidr != null) | .cidr' "$tmp_json" 2>/dev/null > "$tmp_cidr" || {
  echo "drop: jq parse failed — source not valid JSONL?" >&2
  exit 75
}

# --- 3. Clean: dedupe, drop non-global (private/reserved) and our own IPs ------
own_ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]' || true)"
DROP_OWN="$own_ips" python3 - "$tmp_cidr" > "${tmp_cidr}.clean" <<'PY'
import ipaddress, os, sys
own = set()
for line in os.environ.get("DROP_OWN", "").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        own.add(ipaddress.ip_network(line, strict=False))
    except ValueError:
        pass
seen = set()
kept = []
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
        if net.version != 4 or not net.is_global:
            continue
        if any(net.overlaps(w) for w in own):   # never drop our own netblock
            continue
        kept.append(net)

# Collapse overlapping and adjacent networks before emitting. firewalld's
# nftables backend stores a hash:net ipset as an nft INTERVAL set, and nft
# rejects the whole transaction if any two intervals overlap:
#   'python-nftables' failed: Error: conflicting intervals specified
# One overlapping pair therefore loses the entire list, not just that entry.
# The published DROP list genuinely contains them: 40 true containment
# overlaps among 1687 entries on the day this was written.
#
# NOTE, corrected after measuring rather than assuming: this is NOT
# platform-independent. Whether the kernel rejects them differs by host --
# EL9 (kernel 5.14, firewalld 1.3.4) loads the very same 40 overlaps into an
# nft interval set without complaint, while Ubuntu 24.04 (kernel 6.8,
# firewalld 2.1.1) refuses the whole transaction. Collapsing is correct on
# both: it is required on the newer kernel and a harmless no-op on the older
# one, since the merged set covers exactly the same addresses.
# collapse_addresses also merges adjacent blocks (1.2.0.0/24 + 1.2.1.0/24 ->
# 1.2.0.0/23), which covers exactly the same addresses in fewer entries.
for net in ipaddress.collapse_addresses(kept):
    print(net.with_prefixlen)
PY

entry_count="$(wc -l < "${tmp_cidr}.clean")"
echo "drop: $entry_count unique global IPv4 CIDRs after cleaning" >&2

# --- 4. Guard against a bad/empty fetch wiping the live list ------------------
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "drop: only $entry_count entries (< $min_entries), aborting without changes" >&2
  rm -f "${tmp_cidr}.clean"
  exit 75   # EX_TEMPFAIL — last-good set stays live, treated as soft failure by cron-alert
fi

# --- 5. Build the ipset XML (preserve existing header/options if present) ------
if [ -f "$ipset_xml" ]; then
  sed '/<entry>/,$d' "$ipset_xml" > "$tmp_xml"
else
  cat > "$tmp_xml" <<'HDR'
<?xml version="1.0" encoding="utf-8"?>
<ipset type="hash:net">
  <short>Spamhaus DROP</short>
  <description>Spamhaus DROP (hijacked/criminal netblocks), rebuilt by /usr/local/sbin/load-spamhaus-drop.sh. Applied as an all-ports source drop.</description>
  <option name="hashsize" value="4096"/>
  <option name="maxelem" value="65536"/>
HDR
fi
sed 's|.*|  <entry>&</entry>|' "${tmp_cidr}.clean" >> "$tmp_xml"
echo '</ipset>' >> "$tmp_xml"
rm -f "${tmp_cidr}.clean"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "drop: DRY_RUN — built $entry_count entries, not installing. Preview:" >&2
  grep -m5 '<entry>' "$tmp_xml" >&2
  cp "$tmp_xml" /tmp/spamhaus_drop.preview.xml
  echo "drop: full preview at /tmp/spamhaus_drop.preview.xml" >&2
  exit 0
fi

install -m 644 "$tmp_xml" "$ipset_xml"
command -v restorecon >/dev/null 2>&1 && restorecon "$ipset_xml" || true
echo "drop: installed $entry_count entries to $ipset_xml (run: firewall-cmd --reload)" >&2
