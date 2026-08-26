#!/usr/bin/env bash
# 95-sources — make sure every ENABLED reputation source has actually been
# fetched before the install is declared finished.
#
# Why this module exists: 72-feeds installs every loader, enables each source
# it has a key for, and writes /etc/cron.d/ilexa-feeds -- but it never performs
# an initial fetch. The cron entries are the only thing that ever populates the
# data, and they run at fixed times (03:00-ish daily, and geoblock at 03:00 on
# MONDAYS). So a freshly installed server had every source switched on and
# completely empty: no Spamhaus DROP set, no URLhaus map, and up to a full week
# with no geoblock at all, while the console cheerfully reported the sources as
# enabled. Same story for the OTX suite, whose loaders only ran inside
# 70-otx when an API key happened to be present at install time.
#
# This module closes that gap: for each source the operator actually enabled,
# run its updater once, synchronously, and report the result.
source "$MD_ROOT/lib/common.sh"
step_guard 95-sources || exit 0

FEEDS_CONFIG=/usr/local/sbin/qa-feeds-config.sh
# Per-source budget. Generous because these are network fetches and geoblock
# pulls a zone file per country, but bounded so a hung mirror cannot stall the
# install indefinitely. A timeout is a warning, never fatal: mail must serve
# with an empty list, and cron retries on its own schedule anyway.
SOURCE_TIMEOUT="${SOURCE_TIMEOUT:-300}"

# source -> updater. This MUST stay in step with the case block in
# assets/ilexa/feeds-refresh.sh, which is the console's own copy of the same
# mapping; the drift check below fails the module if the two ever diverge,
# because a source missing from this table would silently never get its
# initial fetch again.
SOURCE_CMDS="
otx|/usr/bin/update-otx.sh
otx_uri|/usr/bin/update-otx-uri.sh
urlhaus|/usr/local/sbin/load-urlhaus.sh
spamhaus|/usr/bin/update-spamhaus-drop.sh
c2|/usr/bin/update-abuse-c2.sh
geoblock|/usr/bin/update-geoip.sh
firehol|/usr/local/sbin/update-firehol.sh
abuseipdb|/usr/local/sbin/update-abuseipdb.sh
et|/usr/local/sbin/update-et.sh
dshield|/usr/local/sbin/update-dshield.sh
rspamd_rules|/usr/local/sbin/update-rspamd-community-rules.sh
yara_forge|/usr/local/sbin/update-yara-forge.sh
"

# --- drift check against the console's own mapping --------------------------
# Compare source NAMES only: the console resolves some of them to a different
# path than the installer does, but the SET of sources must match exactly.
# The INSTALLED helper, which is the copy that actually runs, rather than a
# source path -- this repo no longer keeps its own copy of it.
_refresh_asset=/usr/local/sbin/feeds-refresh.sh
[ -r "$_refresh_asset" ] || _refresh_asset="$ILEXA_SRC/install/feeds-refresh.sh"
if [ -r "$_refresh_asset" ]; then
  # Compare name AND path. Names alone would have compared equal right through
  # the /root -> $ILEXA_SBIN relocation while the two files pointed at different
  # binaries -- precisely the false confidence this guard exists to prevent.
  _theirs=$(sed -n '/^case "\$feed"/,/^esac/p' "$_refresh_asset" \
            | grep -oE "^[[:space:]]*[a-z0-9_]+\)[[:space:]]*script=[^ ;]+" \
            | sed -E 's/^[[:space:]]*([a-z0-9_]+)\)[[:space:]]*script=(.*)$/\1|\2/' | sort -u)
  _ours=$(printf '%s\n' "$SOURCE_CMDS" | grep -E '^[a-z0-9_]+\|' | sort -u)
  if [ -n "$_theirs" ] && [ "$_theirs" != "$_ours" ]; then
    # die, not warn. These are two hand-maintained copies of one mapping, which
    # is the drift risk this whole guard exists for -- and the consequence is
    # silent (a source that never gets its initial fetch, so a feed stays
    # enabled-but-empty until its cron happens to run). A warning in a long
    # install log is not enough to catch that; the previous version only warned.
    log_error "source drift vs feeds-refresh.sh (name|path) — a source would never get its initial fetch:"
    log_error "  only in feeds-refresh.sh: $(comm -23 <(echo "$_theirs") <(echo "$_ours") | tr '\n' ' ')"
    log_error "  only in 95-sources.sh:    $(comm -13 <(echo "$_theirs") <(echo "$_ours") | tr '\n' ' ')"
    die "reconcile SOURCE_CMDS in 95-sources.sh with the case block in assets/ilexa/feeds-refresh.sh, then re-run"
  fi
fi

# --- refresh every enabled source -------------------------------------------
src_ok=0; src_fail=0; src_skip=0; src_off=0

if [ ! -x "$FEEDS_CONFIG" ]; then
  log_info "feeds not installed (ENABLE_FEEDS=no) — nothing to refresh"
else
  while IFS='|' read -r name cmd; do
    [ -n "$name" ] || continue
    if ! "$FEEDS_CONFIG" is-enabled "$name" >/dev/null 2>&1; then
      src_off=$((src_off + 1)); continue
    fi
    if [ ! -x "$cmd" ]; then
      log_warn "source '$name' is enabled but its updater is missing ($cmd)"
      src_skip=$((src_skip + 1)); continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      log_info "[dry-run] would refresh source '$name' via $cmd"; continue
    fi
    log_info "refreshing source '$name' (up to ${SOURCE_TIMEOUT}s)"
    if timeout "$SOURCE_TIMEOUT" "$cmd" >/dev/null 2>&1; then
      log_info "  OK   $name"
      src_ok=$((src_ok + 1))
    else
      rc=$?
      [ "$rc" = 124 ] && log_warn "  SLOW $name — timed out after ${SOURCE_TIMEOUT}s; cron will retry" \
                      || log_warn "  FAIL $name (exit $rc) — cron will retry on its normal schedule"
      src_fail=$((src_fail + 1))
    fi
  done <<< "$(printf '%s\n' "$SOURCE_CMDS" | grep -E '^[a-z0-9_]+\|')"
fi

# --- ClamAV third-party signature sources -----------------------------------
# clamav-unofficial-sigs has its own hourly cron (shipped by the package), so
# like the feeds above its databases are empty until that first fires. Run it
# once here so the console's signature panel has something to show.
if [ "$DRY_RUN" != 1 ] && [ -x /usr/sbin/clamav-unofficial-sigs.sh ] \
   && [ -f /etc/clamav-unofficial-sigs/user.conf ]; then
  log_info "running clamav-unofficial-sigs for the first time (up to ${SOURCE_TIMEOUT}s)"
  if timeout "$SOURCE_TIMEOUT" /usr/sbin/clamav-unofficial-sigs.sh >/dev/null 2>&1; then
    log_info "  OK   clamav-unofficial-sigs"
    src_ok=$((src_ok + 1))
  else
    log_warn "  FAIL clamav-unofficial-sigs — its hourly cron will retry"
    src_fail=$((src_fail + 1))
  fi
fi

if [ "$DRY_RUN" != 1 ]; then
  log_info "sources: $src_ok updated, $src_fail failed, $src_skip missing updater, $src_off not enabled"
  [ "$src_fail" -gt 0 ] && log_warn "some sources are enabled but still empty — check with 'qa-feeds-config.sh list'"
fi

mark_done 95-sources
log_info "95-sources done"
