#!/bin/bash
# Rebuild the rspamd URLhaus host map from abuse.ch URLhaus.
#
# Source = URLhaus "hostfile" download (deduplicated malware-distribution
# HOSTNAMES, already excludes IP-literal URLs — those are the ipset's job, not a
# URL-domain map's). Emits a plain hostname list that rspamd's multimap module
# matches against URL hosts in a message (symbol URLHAUS_MALWARE). rspamd watches
# the local map file and hot-reloads on change, so NO rspamd reload is needed.
#
# FP-safe by design: it is a score nudge (weight in local.d/groups.conf), never a
# standalone block; URLhaus occasionally lists malware hosted on a hacked but
# otherwise-legit site, so a suffix whitelist (shared with the OTX URI loader)
# drops shared/legit parent platforms, and the whole thing only raises score.
#
# Env toggles:
#   DRY_RUN=1   build to /tmp/urlhaus_hosts.preview and print stats, install nothing
set -euo pipefail

api_key_file="/etc/ilexa/secrets/abuse_api_key"
map_file="/etc/rspamd/local.d/maps.d/urlhaus_hosts.inc"
whitelist="/var/lib/ilexa/otx-uri-whitelist.txt"     # reuse the hand-maintained OTX suffix whitelist
url="https://urlhaus.abuse.ch/downloads/hostfile/"
min_entries=100                             # hostfile is typ. ~350; refuse a broken/tiny fetch
api_timeout=45

[ -r "$api_key_file" ] || { echo "urlhaus: cannot read $api_key_file" >&2; exit 1; }
# Fail closed if the whitelist is missing (mirrors the OTX URI loader): without it
# we could score a shared/legit platform host that URLhaus listed for hosted malware.
[ -r "$whitelist" ] || { echo "urlhaus: whitelist $whitelist unreadable — refusing to build" >&2; exit 1; }
key="$(cat "$api_key_file")"

tmp_raw="$(mktemp)"; tmp_clean="$(mktemp)"
trap 'rm -f "$tmp_raw" "$tmp_clean"' EXIT

# --- 1. Fetch the hostfile ----------------------------------------------------
if ! curl -s --fail --max-time "$api_timeout" --retry 3 --retry-delay 3 \
        -H "Auth-Key: $key" "$url" -o "$tmp_raw"; then
  echo "urlhaus: fetch failed ($url)" >&2
  exit 75   # EX_TEMPFAIL: transient; keep last-good map (cron-alert soft-fails)
fi

# --- 2. Extract + normalise hostnames ----------------------------------------
# hostfile lines: "127.0.0.1<TAB>hostname"  (plus '#' comment header). Take col2,
# lowercase, drop IP-literals and single-label/bare-TLD entries, drop any host
# equal to or under a whitelisted suffix.
WL="$whitelist" python3 - "$tmp_raw" > "$tmp_clean" <<'PY'
import ipaddress, os, sys
wl = []
with open(os.environ["WL"]) as f:
    for line in f:
        s = line.split('#', 1)[0].strip().lower().lstrip('.')
        if s:
            wl.append(s)
def whitelisted(h):
    return any(h == w or h.endswith('.' + w) for w in wl)
seen = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        host = (parts[1] if len(parts) >= 2 else parts[0]).strip('.').lower()
        if not host or host in seen:
            continue
        if '.' not in host:                 # bare TLD / single label
            continue
        try:
            ipaddress.ip_address(host)       # skip IP-literals
            continue
        except ValueError:
            pass
        if whitelisted(host):
            continue
        seen.add(host)
        print(host)
PY

entry_count="$(wc -l < "$tmp_clean")"
echo "urlhaus: $entry_count unique malware hosts after cleaning" >&2

# --- 3. Guard against a bad/empty fetch wiping the live map -------------------
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "urlhaus: only $entry_count entries (< $min_entries), aborting without changes" >&2
  exit 75   # EX_TEMPFAIL — last-good map stays live
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "urlhaus: DRY_RUN — built $entry_count hosts, not installing. Sample:" >&2
  head -5 "$tmp_clean" >&2
  cp "$tmp_clean" /tmp/urlhaus_hosts.preview
  echo "urlhaus: full preview at /tmp/urlhaus_hosts.preview" >&2
  exit 0
fi

# --- 4. Atomic install; rspamd hot-reloads the file map (no service reload) ----
header="# abuse.ch URLhaus malware-distribution hosts — rebuilt by /usr/local/sbin/load-urlhaus.sh ($(date -u +%FT%TZ)). $entry_count hosts."
{ echo "$header"; cat "$tmp_clean"; } > "${map_file}.new"
chmod 644 "${map_file}.new"
mv -f "${map_file}.new" "$map_file"
command -v restorecon >/dev/null 2>&1 && restorecon "$map_file" || true
echo "urlhaus: installed $entry_count hosts to $map_file" >&2
