#!/bin/bash
#
# Per-user Dovecot FTS Xapian optimize, memory-aware.
#
# WHY THIS EXISTS AT ALL
# ----------------------
# Dovecot's FTS Xapian plugin keeps a per-user full-text index so the console's
# Archive search (and any IMAP SEARCH) can look inside message bodies without
# reading every message. The index is written incrementally as mail arrives, and
# incremental writes fragment it: deleted mail leaves dead entries behind and
# the on-disk size grows well past what the live data needs. Xapian's compact
# operation rewrites the index cleanly, which reclaims that space and keeps
# search fast. Nothing schedules that by itself, so an unmaintained server ends
# up with indexes several times larger than necessary and steadily slower
# searches.
#
# WHY NOT JUST `doveadm fts optimize -A`
# --------------------------------------
# Compact reads the source index and writes a new one, so peak memory scales
# with index size. Run across all users at once on a mail server sized for mail
# rather than for search, that reliably triggers the kernel OOM killer -- and
# the process it kills is not necessarily doveadm. This script therefore:
#
#   * caps each doveadm call with `ulimit -v`, so an oversized index fails that
#     one user's optimize with ENOMEM instead of taking the machine down;
#   * skips indexes larger than half the cap, because those cannot succeed
#     under it and would only waste an hour failing;
#   * runs at nice 15 / ionice idle, so live mail always wins;
#   * pauses between users to let freed memory actually return.
#
# Limits are derived from this host's RAM at RUN TIME, not baked in at install:
# a box that gets more memory later should use it, and one under pressure today
# should back off. Override in /etc/ilexa/fts-optimize.conf.
set -uo pipefail

CONF=/etc/ilexa/fts-optimize.conf
[ -r "$CONF" ] && . "$CONF"

# Enabled flag lives in the config file so the console can switch this off
# without removing the cron entry -- same pattern as the feed sources.
if [ "${FTS_OPTIMIZE_ENABLED:-yes}" != yes ]; then
    exit 0
fi

MAIL_DIR="${MAIL_STORE:-/data/mail}"
LOG="${FTS_OPTIMIZE_LOG:-/var/log/dovecot-fts-optimize.log}"
SLEEP_SEC="${FTS_OPTIMIZE_SLEEP:-15}"

# Derive the cap from total RAM when not pinned: a quarter of it, floored at
# 256MB so tiny boxes still attempt something, ceilinged at 2GB because beyond
# that the guard stops being the useful constraint.
if [ -z "${FTS_OPTIMIZE_MEM_MB:-}" ]; then
    _total_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)
    FTS_OPTIMIZE_MEM_MB=$(( _total_mb / 4 ))
    [ "$FTS_OPTIMIZE_MEM_MB" -lt 256 ]  && FTS_OPTIMIZE_MEM_MB=256
    [ "$FTS_OPTIMIZE_MEM_MB" -gt 2048 ] && FTS_OPTIMIZE_MEM_MB=2048
fi
# An index larger than half the cap cannot compact under it.
: "${FTS_OPTIMIZE_MAX_INDEX_MB:=$(( FTS_OPTIMIZE_MEM_MB / 2 ))}"

MEM_LIMIT_KB=$(( FTS_OPTIMIZE_MEM_MB * 1024 ))

exec >> "$LOG" 2>&1
echo "=== fts-optimize start $(date '+%F %T') mem_limit=${FTS_OPTIMIZE_MEM_MB}MB max_index=${FTS_OPTIMIZE_MAX_INDEX_MB}MB store=$MAIL_DIR ==="

users=$(doveadm user '*' 2>/dev/null | sort) || true
if [ -z "$users" ]; then
    echo "ERROR: doveadm user '*' returned nothing -- aborting (is dovecot running?)"
    exit 1
fi

total=0; skipped_noindex=0; skipped_toobig=0; ok=0; failed=0
while IFS= read -r user; do
    [ -n "$user" ] || continue
    total=$(( total + 1 ))
    domain="${user##*@}"
    idx_dir="$MAIL_DIR/$domain/$user/xapian-indexes"
    if [ ! -d "$idx_dir" ]; then
        skipped_noindex=$(( skipped_noindex + 1 ))
        continue
    fi
    size_mb=$(du -sm "$idx_dir" 2>/dev/null | awk '{print $1}')
    size_mb=${size_mb:-0}
    if [ "$size_mb" -gt "$FTS_OPTIMIZE_MAX_INDEX_MB" ]; then
        printf 'SKIP  %-45s index=%dMB > %dMB cap\n' "$user" "$size_mb" "$FTS_OPTIMIZE_MAX_INDEX_MB"
        skipped_toobig=$(( skipped_toobig + 1 ))
        continue
    fi
    before=$size_mb
    if ( ulimit -v "$MEM_LIMIT_KB"; nice -n 15 ionice -c3 doveadm fts optimize -u "$user" ) 2>&1; then
        after=$(du -sm "$idx_dir" 2>/dev/null | awk '{print $1}'); after=${after:-$before}
        printf 'OK    %-45s %dMB -> %dMB\n' "$user" "$before" "$after"
        ok=$(( ok + 1 ))
    else
        printf 'FAIL  %-45s index=%dMB (ENOMEM under %dMB cap, or doveadm error)\n' "$user" "$before" "$FTS_OPTIMIZE_MEM_MB"
        failed=$(( failed + 1 ))
    fi
    sleep "$SLEEP_SEC"
done <<< "$users"

echo "=== fts-optimize done $(date '+%F %T'): $total users, $ok optimized, $skipped_noindex without index, $skipped_toobig too large, $failed failed ==="
[ "$failed" -eq 0 ]
