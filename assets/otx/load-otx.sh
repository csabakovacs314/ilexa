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
#
# Reliability/throughput (2026-08-23): this account subscribes to ~9000 OTX
# pulses, and OTX's backend is routinely slow (tens of seconds per request,
# sometimes a full timeout) -- confirmed live: a single 5-result page took
# 27s, a slightly larger one timed out entirely at 60s. Fetching every
# pulse's indicators serially, one HTTP round-trip at a time, from scratch,
# every 6-hourly run, made even a SUCCESSFUL run take 11-35 minutes and
# left 3 of the last 6 scheduled runs failing outright. Three independent
# fixes for that, all below: (1) a per-pulse indicator cache with a TTL, so
# a pulse that has not changed since the last run is not re-fetched at all
# -- most of any given run becomes free; (2) bounded parallelism (6
# concurrent) for whatever pulses DO need a real fetch; (3) an outer retry
# around the pulse-ID enumeration page fetch, so one transient hiccup on
# page 2 does not zero out pages already fetched successfully.
set -euo pipefail

api_key_file="/etc/ilexa/secrets/otx_api_key"
ipset_xml="/etc/firewalld/ipsets/otx_block.xml"
# Whitelist: hand-maintained infra file + auto-refreshed CF/Google file (see
# /usr/bin/update-otx-whitelist.sh). Both are CIDR-aware.
whitelist_static="/var/lib/ilexa/otx-whitelist.txt"
whitelist_auto="/var/lib/ilexa/otx-whitelist-auto.txt"
lookback_days="${LOOKBACK_DAYS:-30}"
min_entries=350                               # refuse to install a suspiciously small ROLLING set (see step 4c)
min_fresh="${MIN_FRESH:-100}"                 # below this, this run's FETCH is treated as broken, not the feed as quiet (step 4a)
min_whitelist_nets=50                         # fail closed if the whitelist didn't load (CF+Google alone ~185)

# Rolling-set state: indicator <TAB> first_seen <TAB> last_seen (unix epoch).
# The ipset is rebuilt from this, not from one run's fetch -- see step 4b for
# why. age_out_days is the only thing that removes an entry: 45 days without
# OTX reconfirming it. Chosen above the 30-day lookback window on purpose, so
# an indicator has to be genuinely absent for a full window-and-a-half before
# it is dropped, rather than flickering out on one quiet fortnight.
otx_state="/var/lib/ilexa/otx-rolling.tsv"
age_out_days="${AGE_OUT_DAYS:-45}"
api="https://otx.alienvault.com/api/v1"

# Per-pulse indicator cache. TTL a bit under a day (not exactly 24h) so a
# pulse still gets a real refresh at least once daily even if one of the
# four 6-hourly runs is skipped or fails -- not tied to OTX's own per-pulse
# "modified" timestamp because subscribed_pulse_ids (the cheap enumeration
# endpoint) does not expose one; the modified_since filter already used
# there is what keeps a pulse in scope at all, this cache just avoids
# re-fetching its indicators every single run regardless.
cache_dir="/var/lib/ilexa/otx-pulse-cache"
cache_ttl_min=1200   # 20h
parallel_jobs=6

install -d -m 755 "$cache_dir"

[ -r "$api_key_file" ] || { echo "otx: cannot read $api_key_file" >&2; exit 1; }
key="$(cat "$api_key_file")"

# --fail: HTTP >=400 (e.g. OTX's frequent 504) returns non-zero so it hits the
# guards below instead of feeding a 504 HTML page to jq and aborting under set -e.
#
# Single attempt only, no internal --retry: the enumeration and per-pulse
# loops below each have their OWN outer retry with a sleep between
# attempts. Stacking curl's own multi-attempt --retry underneath an outer
# retry loop does not add resilience -- it MULTIPLIES worst-case latency
# (confirmed live: a 180s test hung on just 6 pulses, because one already-
# slow request could burn 60s x 4 curl-internal attempts, THEN get retried
# again by the outer loop). One retry layer, with a latency budget that is
# actually reasoned about, beats two stacked ones.
# Two timeouts, not one: the enumeration call (modified_since + limit=500,
# against ~9000 subscribed pulses) is inherently a slow, heavy query even
# when OTX is healthy -- confirmed live at ~31s, just over a 25s budget --
# but it only runs a handful of times per script run. Per-pulse indicator
# fetches run up to thousands of times, so THOSE stay on the tighter 25s
# budget: keeping this call fast matters far more for overall throughput
# than the odd fast-failing pulse does (a failed pulse just keeps its old
# cache entry and gets retried next run).
curl_otx() { curl -s --fail -H "X-OTX-API-KEY: $key" --max-time 25 "$@"; }
curl_otx_enum() { curl -s --fail -H "X-OTX-API-KEY: $key" --max-time 45 "$@"; }
export -f curl_otx
export key

tmp_ids="$(mktemp)"; tmp_ips="$(mktemp)"; tmp_xml="$(mktemp)"
trap 'rm -f "$tmp_ids" "$tmp_ips" "$tmp_xml" "${tmp_ids}.errs"' EXIT

since="$(date -u -d "${lookback_days} days ago" +%Y-%m-%dT%H:%M:%S)"

# --- 1. Enumerate subscribed pulse IDs modified within the window -------------
# Each page gets its own retry (3 attempts, 10s apart -- worst case ~95s for
# one page) -- a single already-slow/timed-out attempt was enough to abort
# the WHOLE run before (confirmed live: a bad moment on one page zeroed out
# a run that would otherwise have completed).
url="${api}/pulses/subscribed_pulse_ids?modified_since=${since}&limit=500"
pages=0
while [ -n "$url" ] && [ "$url" != "null" ]; do
  resp=""; attempt=0
  while [ "$attempt" -lt 3 ]; do
    resp="$(curl_otx_enum "$url")" && break
    attempt=$((attempt + 1))
    echo "otx: page fetch failed (attempt $attempt/3), retrying in 10s" >&2
    sleep 10
    resp=""
  done
  if [ -z "$resp" ]; then
    echo "otx: pulse-id fetch failed after 3 attempts, stopping enumeration" >&2
    break
  fi
  echo "$resp" | jq -r '.results[]?' 2>/dev/null >> "$tmp_ids" || true
  url="$(echo "$resp" | jq -r '.next // ""' 2>/dev/null)" || url=""
  pages=$((pages + 1))
  [ "$pages" -gt 200 ] && break   # safety stop
done
pulse_count="$(wc -l < "$tmp_ids")"
echo "otx: $pulse_count pulses modified since ${since} (${lookback_days}d window)" >&2

# --- 2. Pull IPv4 / CIDR indicators from each pulse (cached, parallel) --------
# fetch_pulse writes ONLY to its own pulse's cache file ($cache_dir/$pid) --
# never to a shared file -- so running many of these concurrently via xargs
# -P is safe with no interleaved-write risk. Assembly from the cache back
# into $tmp_ips (step below) is a separate, serial, purely-local pass.
fetch_pulse() {
  local pid="$1" cache_file purl guard presp attempt ok
  cache_file="$cache_dir/$pid"
  if [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mmin "-${cache_ttl_min}" 2>/dev/null)" ]; then
    return 0   # fresh enough -- the assembly pass below will read it
  fi
  purl="${api}/pulses/${pid}/indicators?limit=1000"
  guard=0
  : > "${cache_file}.tmp"
  while [ -n "$purl" ] && [ "$purl" != "null" ]; do
    ok=0; attempt=0
    while [ "$attempt" -lt 2 ]; do
      presp="$(curl_otx "$purl")" && { ok=1; break; }
      attempt=$((attempt + 1))
      sleep 2
    done
    if [ "$ok" -ne 1 ]; then rm -f "${cache_file}.tmp"; echo "$pid"; return 1; fi
    echo "$presp" | jq -r '.results[]? | select(.type=="IPv4" or .type=="CIDR") | .indicator' 2>/dev/null >> "${cache_file}.tmp" || true
    purl="$(echo "$presp" | jq -r '.next // ""' 2>/dev/null)" || purl=""
    guard=$((guard + 1)); [ "$guard" -gt 50 ] && break
  done
  mv "${cache_file}.tmp" "$cache_file"
  return 0
}
export -f fetch_pulse
export cache_dir cache_ttl_min api

: > "${tmp_ids}.errs"
if [ "$pulse_count" -gt 0 ]; then
  xargs -P "$parallel_jobs" -I{} bash -c 'fetch_pulse "$1"' _ {} < "$tmp_ids" >> "${tmp_ids}.errs" 2>/dev/null || true
fi
failed="$(wc -l < "${tmp_ids}.errs")"
[ "$failed" -gt 0 ] && echo "otx: WARNING $failed pulse indicator fetches failed (kept last-good cache for those, if any)" >&2

# Serial assembly from cache -- fast, local disk I/O only, no network.
: > "$tmp_ips"
cache_hits=0
while read -r pid; do
  [ -n "$pid" ] || continue
  if [ -f "$cache_dir/$pid" ]; then
    cat "$cache_dir/$pid" >> "$tmp_ips"
    cache_hits=$((cache_hits + 1))
  fi
done < "$tmp_ids"
echo "otx: assembled indicators from $cache_hits/$pulse_count cached pulses" >&2

# Prune cache entries for pulses no longer in scope (dropped out of the
# lookback window or unsubscribed) -- only when enumeration produced at
# least some IDs; a total enumeration failure (pulse_count=0) must never
# wipe a perfectly good cache built by earlier successful runs.
if [ "$pulse_count" -gt 0 ]; then
  find "$cache_dir" -maxdepth 1 -type f ! -name '*.tmp' -printf '%f\n' 2>/dev/null | while read -r f; do
    grep -qxF "$f" "$tmp_ids" || rm -f "$cache_dir/$f"
  done
fi

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

fresh_count="$(wc -l < "${tmp_ips}.clean")"
echo "otx: $fresh_count unique IPv4/CIDR indicators after cleaning (this run's fetch)" >&2

# --- 4a. Guard: did this run's FETCH work at all? ----------------------------
# Deliberately a low bar, unrelated to how big the final blocklist should be.
# Its only job is telling "OTX returned little because the feed is quiet" from
# "OTX returned little because the fetch broke" -- because the merge below
# treats a successful run as evidence about which indicators are still live,
# and a broken fetch is not evidence of anything. Below this, nothing is
# merged and nothing ages out: the state file and the live set are left
# exactly as they were.
if [ "$fresh_count" -lt "$min_fresh" ]; then
  echo "otx: fetch returned only $fresh_count indicators (< $min_fresh) -- treating as a failed fetch, not a quiet feed; leaving state and live set untouched" >&2
  exit 75
fi

# --- 4b. Merge into the rolling set, age out what has gone quiet -------------
# The ipset is NOT a snapshot of whatever OTX happened to return this run.
# An IP that was malicious last week does not become safe because the pulse
# naming it stopped being edited, and OTX's 30-day modified_since window is a
# statement about PULSE activity, not about whether an address is still
# hostile. Measured 2026-08-24: the same subscription yielded 803 indicators
# on Aug 22 and 257 two days later, with no change to this host, the script,
# or the lookback window -- a snapshot model turns that ordinary feed
# volatility into an 68% collapse of the live blocklist.
#
# So: union each run's fresh indicators with what is already known, remembering
# when each was last confirmed, and drop an entry only after it has gone
# unconfirmed for $age_out_days. Steady state is "everything seen in the last
# 45 days", which is both larger and more stable than any single run.
state_new="${tmp_ips}.state"
OTX_STATE="$otx_state" OTX_STATE_NEW="$state_new" OTX_FRESH="${tmp_ips}.clean" \
OTX_AGE_DAYS="$age_out_days" OTX_SEED_XML="$ipset_xml" \
python3 - > "${tmp_ips}.union" <<'PY'
import os, sys, time, re

now       = int(time.time())
age_secs  = int(os.environ["OTX_AGE_DAYS"]) * 86400
state_f   = os.environ["OTX_STATE"]
fresh_f   = os.environ["OTX_FRESH"]
seed_xml  = os.environ["OTX_SEED_XML"]

# indicator -> [first_seen, last_seen]
state = {}
if os.path.exists(state_f):
    with open(state_f) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            try:
                state[parts[0]] = [int(parts[1]), int(parts[2])]
            except ValueError:
                continue
else:
    # First run after this change: adopt whatever is already live rather than
    # discarding it. Their last_seen is the ipset's own mtime -- the honest
    # answer to "when was this last confirmed", not now(), which would silently
    # grant every legacy entry a fresh full age-out window it did not earn.
    if os.path.exists(seed_xml):
        seeded_at = int(os.path.getmtime(seed_xml))
        with open(seed_xml) as f:
            for m in re.finditer(r"<entry>([^<]+)</entry>", f.read()):
                state[m.group(1).strip()] = [seeded_at, seeded_at]
        sys.stderr.write("otx: seeded rolling state with %d entries already live (last confirmed %s)\n"
                         % (len(state), time.strftime("%Y-%m-%d", time.localtime(seeded_at))))

fresh = set()
with open(fresh_f) as f:
    for line in f:
        tok = line.strip()
        if tok:
            fresh.add(tok)

added = 0
for tok in fresh:
    if tok in state:
        state[tok][1] = now
    else:
        state[tok] = [now, now]
        added += 1

cutoff  = now - age_secs
expired = [k for k, v in state.items() if v[1] < cutoff]
for k in expired:
    del state[k]

with open(os.environ["OTX_STATE_NEW"], "w") as f:
    for tok, (first, last) in sorted(state.items()):
        f.write("%s\t%d\t%d\n" % (tok, first, last))

for tok in sorted(state):
    print(tok)

sys.stderr.write("otx: rolling set %d entries (%d new this run, %d aged out after %s days unconfirmed)\n"
                 % (len(state), added, len(expired), os.environ["OTX_AGE_DAYS"]))
PY
merge_rc=$?
if [ "$merge_rc" -ne 0 ]; then
  echo "otx: rolling-set merge failed (rc=$merge_rc) -- leaving state and live set untouched" >&2
  exit 75
fi

mv "${tmp_ips}.union" "${tmp_ips}.clean"
entry_count="$(wc -l < "${tmp_ips}.clean")"

# --- 4c. Guard against a bad merge wiping the live list ----------------------
# Now applied to the UNION, not to one run's fetch: with the rolling set this
# can only trip if the accumulated history itself has collapsed, which is a
# real problem worth refusing to install.
if [ "$entry_count" -lt "$min_entries" ]; then
  echo "otx: rolling set only $entry_count entries (< $min_entries), aborting without changes" >&2
  # EX_TEMPFAIL: distinct code so cron-alert.sh treats it as a transient/soft
  # failure (edge-triggered mail) rather than a hard config failure.
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
  echo "otx: full preview at /tmp/otx_block.preview.xml (rolling state NOT written)" >&2
  # The merge above computed a new state but must not persist it here: a
  # dry run that advanced every last_seen would silently reset the age-out
  # clock for the whole set, so the next real run would age nothing out.
  exit 0
fi

install -m 644 "$tmp_xml" "$ipset_xml"
command -v restorecon >/dev/null 2>&1 && restorecon "$ipset_xml" || true

# State is committed only after the ipset it describes is actually installed,
# and via a same-filesystem atomic rename -- so a crash between the two leaves
# the previous state intact rather than a state file claiming indicators were
# confirmed for a set that never went live.
install -m 640 "$state_new" "$otx_state"
echo "otx: installed $entry_count entries to $ipset_xml (rolling state: $otx_state)" >&2
