#!/usr/bin/env bash
# 72-feeds — reputation/blocklist feeds.
#
# Every updater is installed unconditionally, so the set on disk is always
# complete and a source can be turned on later without reinstalling anything.
# What varies is which sources are ENABLED:
#
#   * a source needing an API key is enabled only if a key was supplied;
#     with no key it is installed but left disabled, and nothing schedules it
#   * keyless sources are enabled by default
#
# Either way the operator can change their mind afterwards from the ilexa Admin
# tab, which drives the same qa-feeds-config.sh helper this module uses.
source "$MD_ROOT/lib/common.sh"
step_guard 72-feeds || exit 0

if [ "${ENABLE_FEEDS:-no}" != yes ]; then
  log_info "feeds disabled (ENABLE_FEEDS=no) — skipping"
  mark_done 72-feeds; exit 0
fi

# ---- the control helper (also used by the ilexa Admin tab) -----------------
install_bin() { # src dst mode
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] install $2"; return 0; fi
  install -m "$3" -o root -g root "$1" "$2"
}
# 55-ilexa (which runs first) installs this from the app repo inside the
# bundle, and the app is its single source -- this repo no longer keeps a copy,
# because the two had drifted before. Install from the bundle if the console
# module did not run (ENABLE_ILEXA=no), otherwise leave the installed one alone.
if [ -x /usr/local/sbin/qa-feeds-config.sh ]; then
  log_info "qa-feeds-config.sh already installed by 55-ilexa"
elif [ -f "$ILEXA_SRC/install/qa-feeds-config.sh" ]; then
  install_bin "$ILEXA_SRC/install/qa-feeds-config.sh" /usr/local/sbin/qa-feeds-config.sh 0755
else
  log_warn "qa-feeds-config.sh not found (looked in /usr/local/sbin and $ILEXA_SRC/install) — feed enable/disable will fail"
fi

# ---- every updater, always -------------------------------------------------
# Wrappers reload firewalld after the loader rebuilds an ipset.
for f in update-abuse-c2.sh update-spamhaus-drop.sh; do
  install_bin "$MD_ASSETS/feeds/$f" "/usr/bin/$f" 0755
done
for f in update-firehol.sh update-abuseipdb.sh update-et.sh update-dshield.sh update-yara-forge.sh; do
  install_bin "$MD_ASSETS/feeds/$f" "/usr/local/sbin/$f" 0755
done
# Shared helper those three pipe every fetched list through, to drop private/
# reserved ranges before they can score internal mail. It was present on the
# reference host but had never been vendored here, so on a fresh install all
# three died with "/usr/local/sbin/ip-public-filter.py: No such file or
# directory" and their feeds stayed permanently empty -- on EL just as much as
# on Debian. Found by 95-sources actually running them.
install_bin "$MD_ASSETS/feeds/ip-public-filter.py" /usr/local/sbin/ip-public-filter.py 0755
# Loaders do the actual fetching. They live in $ILEXA_SBIN with every other
# helper -- they hold no secrets themselves, and they read the 0600 key files
# from $ILEXA_SECRETS, which they can do from anywhere since they run as root.
# load-countries.sh is deliberately NOT here. 60-firewalld renders it from
# templates/firewalld/load-countries.sh.tmpl, which reads the country list from
# /etc/ilexa/geoblock.conf so the console's geoblock setting actually takes
# effect. This module used to install a second, hardcoded copy over the top of
# it -- and since 72 runs after 60, that copy won: the live loader carried
# countries="ru cn br kr" and ignored the config file entirely, so changing
# geoblock countries in the console silently did nothing.
for f in load-abuse-c2.sh load-spamhaus-drop.sh load-urlhaus.sh; do
  install_bin "$MD_ASSETS/feeds/$f" "$ILEXA_SBIN/$f" 0755
done

# ---- apply the key answers -------------------------------------------------
# set_source KEYVALUE SOURCE...  — one key may unlock several sources
# (abuse.ch covers both URLhaus and the ThreatFox/Feodo C2 list).
# Seeds a feed's key ONCE, then leaves it to the console.
#
# This used to replay the answers file over the live state on every run, so a
# re-run with an older answers file silently reverted whatever the admin had
# since done in ilexa → Admin → feed sources: an out-of-date key overwrote a
# newer one, and an answers file with no key at all *disabled* a feed the
# admin had enabled. Same "the installer quietly undoes the operator" shape as
# geoblock.conf and header_checks, which are already seed-once.
#
# So: if the source already has a key, don't touch it. qa-feeds-config.sh's
# `list` reports has_key per source, which is what decides that.
#
# Known limitation: "never configured" and "the admin deliberately cleared the
# key" both look like has_key=false, so a re-run still re-seeds the latter from
# the answers file. Telling them apart needs state nothing records today. The
# common case -- a key rotated in the console being reverted by a stale
# answers file -- is covered.
_feed_has_key() { # source
  /usr/local/sbin/qa-feeds-config.sh list 2>/dev/null \
    | grep -qE "\"$1\":\{[^}]*\"has_key\":true"
}

set_source() {
  local key="$1"; shift
  local s
  for s in "$@"; do
    if [ "$DRY_RUN" = 1 ]; then
      [ -n "$key" ] && log_info "[dry-run] would set key + enable feed '$s' (only if it has none yet)" \
                    || log_info "[dry-run] no key for '$s' — would install but leave it as-is"
      continue
    fi
    if _feed_has_key "$s"; then
      log_info "feed '$s' already has a key — leaving its key and enabled state to the console"
      continue
    fi
    if [ -n "$key" ]; then
      printf '%s' "$key" | /usr/local/sbin/qa-feeds-config.sh set-key "$s" >/dev/null \
        && /usr/local/sbin/qa-feeds-config.sh enable "$s" >/dev/null \
        && log_info "feed '$s' enabled" \
        || log_warn "feed '$s' could not be enabled"
    else
      /usr/local/sbin/qa-feeds-config.sh disable "$s" >/dev/null
      log_warn "feed '$s' installed but DISABLED — no API key given. Add one later in ilexa → Admin → feed sources."
    fi
  done
}

set_source "${OTX_API_KEY:-}"       otx otx_uri
set_source "${ABUSECH_API_KEY:-}"   urlhaus c2
set_source "${ABUSEIPDB_API_KEY:-}" abuseipdb

# ---- urlhaus rspamd weight ---------------------------------------------------
# The multimap RULE lives in templates/rspamd/multimap.conf.tmpl (rendered by
# 40-rspamd, survives every re-render). Its weight does not belong there: on
# the reference host URLHAUS_MALWARE is scored in groups.conf, not inline --
# same split as otx_uri, appended by 70-otx.sh just below its own multimap
# rule. groups.conf is never rendered by any module, so appending here is
# stable across re-runs the same way otx_uri's weight append is.
if [ -n "${ABUSECH_API_KEY:-}" ] && [ "$DRY_RUN" != 1 ]; then
  LOCALD=/etc/rspamd/local.d
  urlhaus_rspamd_changed=0
  touch "$LOCALD/groups.conf"
  if ! grep -q '"URLHAUS_MALWARE"' "$LOCALD/groups.conf"; then
    urlhaus_rspamd_changed=1
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "urlhaus" {
  symbols {
    "URLHAUS_MALWARE" {
      weight = 4.0;
      description = "URL host on abuse.ch URLhaus malware-distribution list";
    }
  }
}
EOF
    log_info "appended urlhaus weight to $LOCALD/groups.conf"
  fi
  if [ "$urlhaus_rspamd_changed" = 1 ] && systemctl is-active --quiet rspamd; then
    rspamadm configtest >/dev/null 2>&1 && systemctl reload rspamd \
      && log_info "rspamd reloaded to pick up the new urlhaus weight" \
      || log_warn "urlhaus rspamd config did not pass configtest — NOT reloaded, check $LOCALD/groups.conf"
  fi
elif [ "$DRY_RUN" = 1 ] && [ -n "${ABUSECH_API_KEY:-}" ]; then
  log_info "[dry-run] would append urlhaus weight to groups.conf"
fi

# Keyless sources: nothing to withhold, so on by default.
# blocklist.de is deliberately NOT a feed here at all -- not installed, not
# enabled, not scheduled. rspamd already ships a stock bl.blocklist.de DNSBL in
# modules.d/rbl.conf which checks both `from` and `received`, so it sees the
# relay chain that a type=ip multimap never can, and it is live rather than a
# 24h-old snapshot. Downloading the same list as a local map would score one
# upstream source twice (RBL_BLOCKLISTDE 4.0 + RECEIVED_BLOCKLISTDE 3.0 +
# a map symbol) against a reject threshold of 15. Every install still gets
# blocklist.de coverage -- from the DNSBL, automatically, with no updater,
# no cron and no map to go stale. The DNSBL is not a strict superset of the
# downloadable all.txt (measured ~18% short, and why that 18% is the part you
# do not want): see the long note in templates/rspamd/multimap.conf.tmpl.
# EVERY keyless source is enabled at install, by operator decision: if it needs
# no API key there is nothing to withhold, and an admin can switch any of them
# off in the console afterwards. Enabling is the reversible direction; shipping
# a source silently disabled is not, because nobody goes looking for a feature
# they were never told exists.
#
# Two of these were previously left off and are worth calling out:
#
#   yara_forge   -- costs roughly 100MB resident in clamd, and clamd holds TWO
#                   database copies during a reload, so the transient peak is
#                   what must fit, not the steady state. It is now on by
#                   default anyway; on a genuinely memory-tight host, turn it
#                   off in the console's feed-sources panel.
#   rspamd_rules -- the community rule set. Its updater SELF-GATES on
#                   `qa-feeds-config.sh is-enabled rspamd_rules` and exits
#                   "disabled, nothing to do", so leaving the source disabled
#                   meant the daily cron ran and synced nothing, forever. A
#                   fresh install therefore had 0 rule files while the
#                   reference host had 108 -- measured 2026-08-18.
for s in spamhaus firehol et dshield geoblock yara_forge rspamd_rules; do

  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] would enable keyless feed '$s'"; continue; fi
  /usr/local/sbin/qa-feeds-config.sh enable "$s" >/dev/null && log_info "feed '$s' enabled" \
    || log_warn "could not enable feed '$s'"
done

# ---- schedule ---------------------------------------------------------------
# Every entry is guarded by is-enabled at run time rather than by writing a
# different crontab per configuration. That way enabling a source from the Admin
# tab takes effect on the next tick with no cron rewrite and no reinstall.
write_file /etc/cron.d/ilexa-feeds 0644 root:root <<'EOF'
# ilexa reputation feeds. Each line runs only while its source is enabled in
# /etc/ilexa/feeds.conf (see qa-feeds-config.sh); disabled sources cost one
# is-enabled check and exit.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would bypass
# the console's notification setting entirely. All alerting goes through
# cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays silent until an
# address is configured in the Admin tab.
MAILTO=""
10 */6 * * * root qa-feeds-config.sh is-enabled urlhaus   && /usr/local/sbin/load-urlhaus.sh          >/dev/null 2>&1
20 3 * * *   root qa-feeds-config.sh is-enabled spamhaus  && /usr/bin/update-spamhaus-drop.sh >/dev/null 2>&1
40 3 * * *   root qa-feeds-config.sh is-enabled c2        && /usr/bin/update-abuse-c2.sh    >/dev/null 2>&1
17 3 * * *   root qa-feeds-config.sh is-enabled firehol   && /usr/local/sbin/update-firehol.sh   >/dev/null 2>&1
32 3 * * *   root qa-feeds-config.sh is-enabled abuseipdb && /usr/local/sbin/update-abuseipdb.sh >/dev/null 2>&1
47 3 * * *   root qa-feeds-config.sh is-enabled et        && /usr/local/sbin/update-et.sh        >/dev/null 2>&1
27 3 * * *   root qa-feeds-config.sh is-enabled dshield   && /usr/local/sbin/update-dshield.sh   >/dev/null 2>&1
0 3 * * 1    root qa-feeds-config.sh is-enabled geoblock  && /usr/bin/update-geoip.sh       >/dev/null 2>&1
25 4 * * *   root qa-feeds-config.sh is-enabled yara_forge && /usr/local/sbin/update-yara-forge.sh >/dev/null 2>&1
EOF

mark_done 72-feeds
log_info "72-feeds done — all updaters installed; see 'qa-feeds-config.sh list' for what is enabled"
