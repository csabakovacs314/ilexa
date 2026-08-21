#!/usr/bin/env bash
# 41-hu-classify — experimental language-based spam-signal module for
# rspamd, Hungarian + English: {HU,EN}_LANGUAGE (fastText lid.176 language
# ID) and {HU,EN}_NATURALNESS (Wikipedia-trigram coherent-text-vs-gibberish
# score, one reference table per language), all shadow-mode (score=0.0,
# logged not enforced -- see the option string on each symbol).
# HU_SPAM/HU_PHISHING/HU_SCAM are fixed placeholders: a real spam classifier
# could not be trained honestly from this project's own archive (77
# genuinely distinct spam messages after de-duplication, worse than the
# trivial always-ham baseline) -- see the bundled hu-classify-stub.py
# docstring for the full negative result. No English equivalent attempted.
#
# Ships installed-but-OFF even when this module runs: the console's
# Rendszer page (qa-hu-classify.sh, deployed by 55-ilexa) is the actual
# on/off switch. lua.local.d/hu_classify.lua re-reads a plain state file on
# every message and treats an ABSENT file as disabled -- so a fresh install
# never silently starts scoring mail with an experimental module nobody
# asked to turn on, and flipping it later needs no rspamd reload at all.
source "$MD_ROOT/lib/common.sh"
step_guard 41-hu-classify || exit 0

if [ "${ENABLE_HU_CLASSIFY:-no}" != yes ]; then
  log_info "Hungarian classifier module disabled (ENABLE_HU_CLASSIFY=no) — skipping"
  mark_done 41-hu-classify; exit 0
fi

[ -d /etc/rspamd/lua.local.d ] || die "41-hu-classify: /etc/rspamd/lua.local.d missing — run 40-rspamd first"

VENV=/opt/hu-classify/venv
MODELS=/opt/hu-classify/models

# fasttext 0.9.3 needs a C++ toolchain to build on hosts where PyPI has no
# matching manylinux wheel -- confirmed the hard way on EL9 (missing
# Python.h) while building the prototype this module is based on.
if [ "$PKG_MGR" = apt ]; then
  pkg_install python3-venv python3-dev build-essential
else
  pkg_install python3-devel gcc gcc-c++
fi

if [ "$DRY_RUN" != 1 ]; then
  install -d -m 0755 /opt/hu-classify "$MODELS"
  install -m 0644 "$MD_ASSETS/hu-classify/models/lid.176.ftz"         "$MODELS/lid.176.ftz"
  install -m 0644 "$MD_ASSETS/hu-classify/models/hu_naturalness.json" "$MODELS/hu_naturalness.json"
  install -m 0644 "$MD_ASSETS/hu-classify/models/en_naturalness.json" "$MODELS/en_naturalness.json"
  install -m 0755 "$MD_ASSETS/hu-classify/hu-classify-stub.py" /usr/local/sbin/hu-classify-stub.py
  # The measurement tools, without which the "weight 0.0 is a MEASURED
  # result, re-check it per host" claim in the console panel and in
  # GUIDE.md is unactionable -- both name these scripts by filename. Left
  # under /opt (root-only, 0700) rather than /usr/local/sbin: they read real
  # mail through the doveadm gateway and are deliberately NOT console- or
  # sudo-reachable. Shipping the docs without the tools is the same
  # half-wired shape as a console panel shelling out to a binary the
  # installer never placed.
  install -m 0700 "$MD_ASSETS/hu-classify/measure_signal_value.py" /opt/hu-classify/measure_signal_value.py
  install -m 0700 "$MD_ASSETS/hu-classify/recalibrate.py"          /opt/hu-classify/recalibrate.py

  [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
  # Pinned: fasttext 0.9.3's np.array(copy=False) call breaks under numpy 2.x
  # (ValueError: Unable to avoid copy while creating an array...) -- found
  # building the prototype on hawking (EL9, Python 3.9) 2026-08-18.
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet 'numpy<2' 'fasttext==0.9.3'

  # The systemd unit uses DynamicUser=yes (no named group to grant access
  # to), so every file the service needs to read must be world-readable.
  # Scoped to the venv and the models -- deliberately NOT `-R` over all of
  # /opt/hu-classify, which would also re-open the 0700 measurement tools
  # installed above (o+rX turned them into 0705). The service reads the
  # interpreter and the model tables; it has no business with the tools.
  chmod o+rX /opt/hu-classify
  chmod -R o+rX "$VENV" "$MODELS"

  install -m 0644 "$MD_ASSETS/hu-classify/hu-classify-stub.service" /etc/systemd/system/hu-classify-stub.service
  systemctl daemon-reload
  # NOT enabled, NOT started here -- qa-hu-classify.sh's "set on" (the
  # console toggle) is what does that, matching "installed but off".

  install -m 0644 "$MD_ASSETS/hu-classify/hu_classify.lua" /etc/rspamd/lua.local.d/hu_classify.lua
  # Fail-safe default: no state file means the Lua gate treats the module
  # as disabled. Remove any leftover from a previous run of this module so
  # a re-run can't accidentally inherit a stale "enabled" from testing.
  rm -f /etc/rspamd/local.d/hu_classify.state

  # HU_PHISH_SCAM_LOG: unconditional, NOT gated by hu_classify.state. It
  # reads only already-computed symbols from OTHER checks (DBL_PHISH, the
  # community-rules phishing/scam maps, ...) and never calls the external
  # classifier stub, so its lifecycle has no reason to depend on whether
  # HU_LANGUAGE/HU_SPAM live scoring is toggled on. No score, log-only —
  # see the module's own header for why HU_PHISHING/HU_SCAM need this at
  # all (no phishing/scam label exists anywhere in the historical archive).
  install -m 0644 "$MD_ASSETS/hu-classify/hu_phish_scam_log.lua" /etc/rspamd/lua.local.d/hu_phish_scam_log.lua

  if rspamadm configtest >/dev/null 2>&1; then
    # A plain reload is NOT enough here and svc_reload's own reload-then-
    # restart-on-failure fallback never fires, because `systemctl reload
    # rspamd` (SIGHUP) reliably reports success while still leaving a
    # worker running the OLD Lua bytecode -- confirmed live while building
    # this module (see memory rspamd_reload_testing_gotchas.md) and again
    # on a re-run of this module against an already-running rspamd, where
    # the reload "succeeded" but EN_LANGUAGE/EN_NATURALNESS silently did
    # not fire until an explicit restart. A full restart is the only
    # reliable way to make rspamd re-parse a CHANGED lua.local.d file.
    systemctl restart rspamd
  else
    log_warn "rspamd configtest failed after installing hu_classify.lua — NOT restarting (review /etc/rspamd/lua.local.d/hu_classify.lua)"
  fi
else
  log_info "[dry-run] would install the Hungarian classifier module (venv, models, systemd unit, lua.local.d/hu_classify.lua + hu_phish_scam_log.lua) — installed but OFF by default"
fi

# ---- fortnightly review job ------------------------------------------------
# Only reached when the module is ENABLED -- deliberately below the early
# exit above, so a host with ENABLE_HU_CLASSIFY=no gets no cron entry
# pointing at a venv that was never created.
#
# 1st and 15th rather than "every 14 days": cron has no fortnightly syntax,
# and fixed days-of-month survive reboots and missed runs where a rolling
# counter does not. 04:40 keeps several thousand doveadm fetches clear of
# the 04:00/04:02/04:30 feed and archive jobs.
#
# MAILTO="" because cron mailing the job's OUTPUT would bypass the console's
# own recipient setting entirely; the script addresses its own send, and
# cron-alert.sh covers the separate case of the job itself failing.
write_file /etc/cron.d/qa-hu-classify-report 0644 root:root <<EOF
# Fortnightly review of the experimental language-classifier signals.
# Recipient is set on the console's Rendszer page; with none set there it
# falls back to /etc/ilexa/alerts.conf, and with neither it sends nothing.
MAILTO=""
CRON_ALERT_STATE_DIR=/var/cache/quarantine-admin
40 4 1,15 * * root /usr/bin/cron-alert.sh hu-classify-report $VENV/bin/python3 /usr/local/sbin/qa-hu-classify-report.py >> /var/log/quarantine-admin/hu-classify-report.log 2>&1
EOF

# Seed the report recipient from the answers file, seed-once. Never
# overwrite: the console owns this setting after the first install, and a
# re-run must not silently revert an address an operator changed there.
if [ "$DRY_RUN" != 1 ] && [ -n "${HU_CLASSIFY_REPORT_EMAIL:-}" ] \
   && [ ! -s /etc/ilexa/hu-classify-report.conf ]; then
  install -d -m 0755 /etc/ilexa
  { echo "# Recipient for the ilexa language-classifier review report."
    echo "# Seeded by the installer; the console's Rendszer page owns it now."
    printf '%s\n' "$HU_CLASSIFY_REPORT_EMAIL"; } > /etc/ilexa/hu-classify-report.conf
  chmod 644 /etc/ilexa/hu-classify-report.conf
  log_info "classifier review recipient seeded: $HU_CLASSIFY_REPORT_EMAIL"
fi


mark_done 41-hu-classify
log_info "41-hu-classify done — module installed but OFF; enable it from the console's Rendszer page"
