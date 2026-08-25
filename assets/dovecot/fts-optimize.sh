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
# the on-disk size grows well past what the live data needs.
#
# IMPORTANT, corrected 2026-08-25 after measuring: `doveadm fts optimize` does
# NOT reclaim that space. Read fts-xapian 1.5.5's own source --
# fts_backend_xapian_optimize() only delete_document()s the expunged UIDs and
# commits; there is no compact call anywhere in it. Deleting from a Xapian glass
# DB never returns blocks to the OS, so the file does not shrink and often GROWS
# (measured: a 73-message mailbox went 30MB -> 35MB through an optimize that
# correctly purged 83 stale docs). Every line of this script's own first run
# logged that fact as "273MB -> 273MB" and nobody read it that way.
#
# Reclaiming the space needs a real Xapian compact, which is what this script
# now does as a second step, after the optimize. Measured on this host:
# 705MB -> 283MB on a mailbox with zero stale docs, 35MB -> 4.6MB on one with
# stale docs. Nothing else schedules that, so an unmaintained server ends up
# with indexes several times larger than necessary and steadily slower
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

# ---------------------------------------------------------------------------
# compact_user_index <xapian-indexes dir> -> echoes "<before_mb> <after_mb>"
#
# Each db_* subdirectory under a user's xapian-indexes is one mailbox's Xapian
# glass DB. xapian-compact rewrites one cleanly into a new directory; we then
# swap it in atomically.
#
# Safe to run while Dovecot is live, for a specific reason worth recording:
# fts-xapian derives "last indexed UID" from the index itself
# (get_value_upper_bound on slot 1 -- fts-backend-xapian.cpp:137), NOT from
# separate state. So if a message gets indexed between the compact and the
# swap, the swapped-in copy simply reports a lower last-UID and Dovecot's
# autoindex re-indexes it. The failure mode is redundant work, not a permanent
# hole in search results.
#
# Refuses to swap unless the compacted copy opens and reports a document count,
# and unless it is actually smaller. A broken or bigger index is left alone and
# the original is never touched.
compact_user_index() {
    local idx_dir="$1" db tmp before after rc=0
    before=$(du -sm "$idx_dir" 2>/dev/null | awk '{print $1}'); before=${before:-0}

    for db in "$idx_dir"/db_*/; do
        [ -d "$db" ] || continue
        db="${db%/}"
        tmp="${db}.compact.$$"

        if ! ( ulimit -v "$MEM_LIMIT_KB"; nice -n 15 ionice -c3 \
                 xapian-compact --no-renumber "$db" "$tmp" ) >/dev/null 2>&1; then
            echo "      compact FAILED (kept original): $(basename "$db")" >&2
            rm -rf -- "$tmp" 2>/dev/null
            rc=1
            continue
        fi

        # Never swap in something we cannot open, or that got bigger.
        if ! xapian-delve "$tmp" 2>/dev/null | grep -q "number of documents"; then
            echo "      compact produced an unreadable DB (kept original): $(basename "$db")" >&2
            rm -rf -- "$tmp" 2>/dev/null
            rc=1
            continue
        fi
        local sz_old sz_new
        sz_old=$(du -sb "$db"  2>/dev/null | cut -f1)
        sz_new=$(du -sb "$tmp" 2>/dev/null | cut -f1)
        if [ "${sz_new:-0}" -ge "${sz_old:-0}" ]; then
            rm -rf -- "$tmp" 2>/dev/null
            continue
        fi

        # Match the original's ownership/permissions before it goes live.
        chown --reference="$db" -R "$tmp" 2>/dev/null
        chmod --reference="$db" "$tmp" 2>/dev/null
        find "$tmp" -type f -exec chmod 0600 {} + 2>/dev/null

        # Atomic-ish swap: rename new into place, then drop the old copy.
        if mv -T -- "$db" "${db}.old.$$" 2>/dev/null && mv -T -- "$tmp" "$db" 2>/dev/null; then
            rm -rf -- "${db}.old.$$" 2>/dev/null
        else
            # Roll back to whatever is still there; never leave the user without an index.
            [ -d "${db}.old.$$" ] && [ ! -d "$db" ] && mv -T -- "${db}.old.$$" "$db" 2>/dev/null
            rm -rf -- "$tmp" 2>/dev/null
            echo "      compact swap FAILED (original restored): $(basename "$db")" >&2
            rc=1
        fi
    done

    after=$(du -sm "$idx_dir" 2>/dev/null | awk '{print $1}'); after=${after:-$before}
    echo "$before $after"
    return $rc
}

exec >> "$LOG" 2>&1
echo "=== fts-optimize start $(date '+%F %T') mem_limit=${FTS_OPTIMIZE_MEM_MB}MB max_index=${FTS_OPTIMIZE_MAX_INDEX_MB}MB store=$MAIL_DIR ==="

# Optional argument: restrict to users matching a glob (e.g. one address, or
# '*@example.com'). Defaults to every user, so the cron entry is unaffected.
# Exists so a change here can be proven on one mailbox before it runs on 145.
# NOTE: `doveadm user <exact-address>` prints that user's userdb FIELD/VALUE
# table, not a username -- only a glob lists usernames. So always enumerate with
# '*' and match the filter here, which behaves correctly for an exact address
# and a glob alike.
USER_FILTER="${1:-*}"

users=$(doveadm user '*' 2>/dev/null | sort) || true
if [ -z "$users" ]; then
    echo "ERROR: doveadm user '*' returned nothing -- aborting (is dovecot running?)"
    exit 1
fi

total=0; skipped_noindex=0; skipped_toobig=0; ok=0; failed=0; reclaimed_mb=0
while IFS= read -r user; do
    [ -n "$user" ] || continue
    # shellcheck disable=SC2254  # unquoted on purpose: $USER_FILTER IS a glob
    case "$user" in $USER_FILTER) ;; *) continue ;; esac
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
        # Step 2: the optimize above only DELETED the expunged docs -- it does
        # not shrink the file (see the header). Compact to actually reclaim.
        read -r _cb after <<<"$(compact_user_index "$idx_dir")"
        after=${after:-$before}
        saved=$(( before - after ))
        printf 'OK    %-45s %dMB -> %dMB (reclaimed %dMB)\n' "$user" "$before" "$after" "$saved"
        reclaimed_mb=$(( reclaimed_mb + (saved > 0 ? saved : 0) ))
        ok=$(( ok + 1 ))
    else
        printf 'FAIL  %-45s index=%dMB (ENOMEM under %dMB cap, or doveadm error)\n' "$user" "$before" "$FTS_OPTIMIZE_MEM_MB"
        failed=$(( failed + 1 ))
    fi
    sleep "$SLEEP_SEC"
done <<< "$users"

echo "=== fts-optimize done $(date '+%F %T'): $total users, $ok optimized, ${reclaimed_mb}MB reclaimed, $skipped_noindex without index, $skipped_toobig too large, $failed failed ==="
[ "$failed" -eq 0 ]
