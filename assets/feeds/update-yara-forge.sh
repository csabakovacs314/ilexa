#!/bin/bash
#
# update-yara-forge.sh — install the YARA Forge "core" rule pack into ClamAV.
#
# YARA Forge (https://yarahq.github.io/) aggregates ~45 vetted public YARA rule
# repositories, standardises the metadata and quality-checks the result into
# three tiers. Only "core" is used here: it is the low-false-positive tier, and
# on a mail path a false positive means a rejected business email. The extended
# and full tiers trade FP rate for breadth, which is the wrong trade here.
#
# WHY THIS IS WORTH INSTALLING: ClamAV's YARA support is switched on by
# clamav-unofficial-sigs, but the only .yara files it ships are two Sanesecurity
# files last updated in 2015/2016 — six rules in total. This takes that to ~4200.
#
# WHAT CLAMAV WILL REFUSE: it supports no YARA modules (pe/hash/elf/math), no
# `import`, no external variables, no global/private rules, and every rule must
# have a strings section. Roughly 16% of the core pack is silently skipped for
# those reasons — measured, not estimated: 5034 rules in, 4204 loaded. That is
# expected and not an error; ClamAV logs and moves on.
#
# COST: about +100MB resident in clamd. Note that clamd holds TWO database
# copies during a reload, so the transient peak is what matters on a memory-tight
# host, not the steady state.
#
# SAFETY: the pack is test-loaded with clamscan into a scratch directory BEFORE
# it is allowed near /var/lib/clamav. Everything in that directory is loaded by
# clamd, so a malformed file there does not degrade scanning — it breaks it.
set -uo pipefail

URL="${YARA_FORGE_URL:-https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-core.zip}"
DEST_DIR="${CLAMAV_DB_DIR:-/var/lib/clamav}"
DEST="$DEST_DIR/yara-forge-core.yar"
LOG="${YARA_FORGE_LOG:-/var/log/feeds-refresh-yara_forge.log}"
MIN_RULES="${YARA_FORGE_MIN_RULES:-1000}"   # sanity floor; a truncated download must not replace a good pack
TIMEOUT="${YARA_FORGE_TIMEOUT:-180}"

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL --max-time "$TIMEOUT" "$URL" -o "$tmp/core.zip"; then
    log "FETCH FAILED ($URL) — keeping previous"; exit 1
fi

# A GitHub redirect to an HTML error page is the realistic failure here, and it
# arrives with a 200. Check what we actually got rather than trusting the code.
case "$(file -b --mime-type "$tmp/core.zip")" in
    application/zip) : ;;
    *) log "NOT A ZIP (got $(file -b --mime-type "$tmp/core.zip")) — keeping previous"; exit 1 ;;
esac

if ! unzip -qo "$tmp/core.zip" -d "$tmp/x" 2>/dev/null; then
    log "UNZIP FAILED — keeping previous"; exit 1
fi

src="$(find "$tmp/x" -name '*.yar' -type f | head -1)"
[ -n "$src" ] || { log "NO .yar IN ARCHIVE — keeping previous"; exit 1; }

count="$(grep -cE '^rule ' "$src" 2>/dev/null || echo 0)"
if [ "$count" -lt "$MIN_RULES" ]; then
    log "SANITY FAIL (only $count rules, floor $MIN_RULES) — keeping previous"; exit 1
fi

# Test-load in isolation. clamscan -d <file> uses ONLY that file, so this proves
# the pack parses and reports how many rules survive ClamAV's restrictions,
# without any risk to the live database directory.
probe="$tmp/probe.txt"; echo "probe" >"$probe"
loaded="$(clamscan -d "$src" "$probe" 2>/dev/null | awk -F': *' '/^Known viruses:/{print $2}')"
if [ -z "$loaded" ] || [ "$loaded" -lt 1 ] 2>/dev/null; then
    log "TEST LOAD FAILED (clamscan loaded nothing) — keeping previous"; exit 1
fi

install -m 0644 -o root -g root "$src" "$DEST" || { log "INSTALL FAILED to $DEST"; exit 1; }
# clamd re-reads the database directory on its own schedule; ask freshclam's
# notify path to pick it up promptly where available, but never fail on it.
command -v clamdscan >/dev/null 2>&1 && clamd_reload=1 || clamd_reload=0
if [ "$clamd_reload" = 1 ] && systemctl is-active --quiet clamav-daemon 2>/dev/null; then
    systemctl reload clamav-daemon >/dev/null 2>&1 || true
elif [ "$clamd_reload" = 1 ] && systemctl is-active --quiet clamd@scan 2>/dev/null; then
    systemctl reload clamd@scan >/dev/null 2>&1 || true
fi

log "OK $count rules in pack, $loaded loaded by ClamAV -> $DEST"
echo "yara-forge: $count rules in pack, $loaded accepted by ClamAV" >&2
