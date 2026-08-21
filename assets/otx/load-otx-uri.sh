#!/bin/bash
# Rebuild the rspamd OTX URI-scoring map from AlienVault OTX subscribed pulses.
# Companion to /usr/local/sbin/load-otx.sh (which does IP blocking); this one feeds OTX
# domain / hostname / URL-host indicators into rspamd as a *scoring* signal
# (never an outright block — false positives must only nudge the score, not drop
# mail). Reconnected to rspamd 2026-08-15: the prior consumer was a SpamAssassin
# rule loaded only by MailScanner, which has been inactive (rspamd is the live
# enforcer) since the 2026-08-06 cutover -- this feed had zero live effect for
# over a week before this change, with nothing surfacing that.
#
# Mechanism: a plain sorted hostname list, one per line, at
#   /etc/rspamd/local.d/maps.d/otx_uri_hosts.inc
# matched against message URL hosts by the "otx_uri" multimap rule in
# /etc/rspamd/local.d/multimap.conf (symbol FEED_OTX_URI, weight in
# /etc/rspamd/local.d/groups.conf). Subdomains match implicitly via the dedup
# pass below, so enlisting a registered domain covers all its hosts. rspamd
# watches the map file's mtime and hot-reloads on change -- no service restart
# needed, unlike the SpamAssassin/MailScanner path this replaced.
#
# Env toggles:
#   DRY_RUN=1        build to /tmp and print stats, install nothing
#   LOOKBACK_DAYS=N  override the rolling window (default 30)
set -euo pipefail

api_key_file="/etc/ilexa/secrets/otx_api_key"
map_file="/etc/rspamd/local.d/maps.d/otx_uri_hosts.inc"
whitelist="/var/lib/ilexa/otx-uri-whitelist.txt"          # hand-maintained suffix whitelist (shared/legit platforms)
lookback_days="${LOOKBACK_DAYS:-30}"
min_entries=500                                  # refuse to install a suspiciously small list (empty/broken fetch)
api="https://otx.alienvault.com/api/v1"

[ -r "$api_key_file" ] || { echo "otx-uri: cannot read $api_key_file" >&2; exit 1; }
[ -r "$whitelist" ]    || { echo "otx-uri: cannot read $whitelist (fail-closed: refusing to build)" >&2; exit 1; }
key="$(cat "$api_key_file")"

# --fail so OTX's frequent 504 returns non-zero (caught by guards) instead of
# feeding a 504 HTML page to jq and aborting the run under set -e.
curl_otx() { curl -s --fail -H "X-OTX-API-KEY: $key" --max-time 60 --retry 3 --retry-delay 3 "$@"; }

tmp_ids="$(mktemp)"; tmp_ind="$(mktemp)"; tmp_cf="$(mktemp)"
trap 'rm -f "$tmp_ids" "$tmp_ind" "$tmp_cf" "${tmp_ind}.clean"' EXIT

since="$(date -u -d "${lookback_days} days ago" +%Y-%m-%dT%H:%M:%S)"

# --- 1. Enumerate subscribed pulse IDs modified within the window -------------
# (the /pulses/subscribed endpoint 504s — enumerate IDs cheaply, fetch each pulse.)
url="${api}/pulses/subscribed_pulse_ids?modified_since=${since}&limit=500"
pages=0
while [ -n "$url" ] && [ "$url" != "null" ]; do
  resp="$(curl_otx "$url")" || { echo "otx-uri: pulse-id fetch failed, stopping enumeration" >&2; break; }
  echo "$resp" | jq -r '.results[]?' 2>/dev/null >> "$tmp_ids" || true
  url="$(echo "$resp" | jq -r '.next // ""' 2>/dev/null)" || url=""
  pages=$((pages + 1)); [ "$pages" -gt 200 ] && break
done
echo "otx-uri: $(wc -l < "$tmp_ids") pulses modified since ${since} (${lookback_days}d window)" >&2

# --- 2. Pull domain / hostname / URL indicators from each pulse --------------
failed=0
while read -r pid; do
  [ -n "$pid" ] || continue
  purl="${api}/pulses/${pid}/indicators?limit=1000"; guard=0
  while [ -n "$purl" ] && [ "$purl" != "null" ]; do
    presp="$(curl_otx "$purl")" || { failed=$((failed + 1)); break; }
    echo "$presp" | jq -r '.results[]? | select(.type=="domain" or .type=="hostname" or .type=="URL") | "\(.type)\t\(.indicator)"' 2>/dev/null >> "$tmp_ind" || true
    purl="$(echo "$presp" | jq -r '.next // ""' 2>/dev/null)" || purl=""
    guard=$((guard + 1)); [ "$guard" -gt 50 ] && break
  done
done < "$tmp_ids"
[ "$failed" -gt 0 ] && echo "otx-uri: WARNING $failed pulse indicator fetches failed" >&2

# --- 3. Normalise + clean (fail-CLOSED, mirrors the IP loader's is_global guard)
# Python does: extract host from URL; lowercase; drop IP-literals, bare TLDs and
# public suffixes (a wildcard like 'com' would score ALL mail), and any host that
# equals or is a subdomain of a whitelist suffix; then drop hosts already covered
# by an enlisted parent domain (implicit subdomain match makes them redundant).
OTX_WL="$whitelist" python3 - "$tmp_ind" > "${tmp_ind}.clean" <<'PY'
import ipaddress, os, sys
from urllib.parse import urlsplit

# Public suffixes that must never be enlisted alone (would match every subdomain
# under them). Not the full PSL — just the common multi-label ones OTX junk hits;
# the < 2-label floor below catches every bare TLD.
PUBLIC_SUFFIXES = {
    "co.uk","org.uk","gov.uk","ac.uk","com.au","net.au","org.au","co.jp","or.jp",
    "co.nz","co.za","com.br","com.cn","com.mx","com.tr","com.ar","co.in","co.kr",
    "com.sg","com.hk","com.tw","co.il","com.ua","com.pl","co.id",
}

def load_wl(path):
    wl = []
    with open(path) as f:
        for line in f:
            line = line.split('#', 1)[0].strip().lower().rstrip('.')
            if line:
                wl.append(line)
    return wl

def host_of(typ, ind):
    ind = ind.strip().lower()
    if typ == "URL":
        if "://" not in ind:
            ind = "//" + ind
        h = urlsplit(ind).hostname or ""
    else:
        h = ind
    return h.strip().rstrip('.')

def is_ip(h):
    try:
        ipaddress.ip_address(h.strip('[]'))
        return True
    except ValueError:
        return False

wl = load_wl(os.environ["OTX_WL"])
def whitelisted(h):
    return any(h == w or h.endswith('.' + w) for w in wl)

hosts = set()
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t', 1)
        if len(parts) != 2:
            continue
        h = host_of(parts[0], parts[1])
        if not h or '.' not in h:            # bare TLD / empty  -> would wildcard
            continue
        if is_ip(h):                          # IP-literals handled by the IP block, not here
            continue
        labels = h.split('.')
        if len(labels) < 2:                   # belt-and-braces with the '.' check above
            continue
        if h in PUBLIC_SUFFIXES:              # e.g. a stray 'co.uk' -> would wildcard
            continue
        if any(not lb for lb in labels):      # malformed (leading/trailing/double dot)
            continue
        if whitelisted(h):
            continue
        hosts.add(h)

# Drop hosts already covered by an enlisted parent (implicit subdomain match).
# e.g. if evil.com is present, www.evil.com is redundant.
final = []
for h in hosts:
    parts = h.split('.')
    covered = False
    for i in range(1, len(parts) - 1):        # proper parent suffixes, excluding the TLD-only tail
        if '.'.join(parts[i:]) in hosts:
            covered = True
            break
    if not covered:
        final.append(h)

for h in sorted(final):
    print(h)
PY

entry_count="$(wc -l < "${tmp_ind}.clean")"
echo "otx-uri: $entry_count unique URI hosts after cleaning/whitelisting" >&2

# --- 4. Guard against a bad/empty fetch wiping the live map ------------------
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "otx-uri: only $entry_count entries (< $min_entries), aborting without changes" >&2
  # EX_TEMPFAIL: a below-floor result means OTX was degraded this run (the flaky
  # /pulses/subscribed_pulse_ids enumeration or per-pulse indicator fetches
  # 504'd/timed out, dropping indicators); the last-good map stays live and it
  # usually self-heals next run. Distinct code so cron-alert.sh treats it as a
  # transient/soft failure (edge-triggered mail after SOFT_FAIL_THRESHOLD) rather
  # than a hard fetch failure. Mirrors load-otx.sh's / load-urlhaus.sh's own
  # below-floor guards.
  exit 75
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "otx-uri: DRY_RUN — built $entry_count hosts, not installing. Sample:" >&2
  head -5 "${tmp_ind}.clean" >&2
  cp "${tmp_ind}.clean" /tmp/otx_uri_hosts.preview
  echo "otx-uri: full preview at /tmp/otx_uri_hosts.preview" >&2
  exit 0
fi

# --- 5. Atomic install; rspamd hot-reloads the file map (no service reload) --
header="# AlienVault OTX malicious URI hosts -- rebuilt by /usr/local/sbin/load-otx-uri.sh ($(date -u +%FT%TZ)). $entry_count hosts. Score-only (FP-safe, weight in rspamd groups.conf), never blocks."
{ echo "$header"; cat "${tmp_ind}.clean"; } > "${map_file}.new"
chmod 644 "${map_file}.new"
mv -f "${map_file}.new" "$map_file"
command -v restorecon >/dev/null 2>&1 && restorecon "$map_file" || true
echo "otx-uri: installed $entry_count hosts to $map_file" >&2
