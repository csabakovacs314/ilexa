#!/usr/bin/env bash
# 35-clamav — ClamAV engine + auto-updating definitions (called by rspamd).
source "$MD_ROOT/lib/common.sh"
step_guard 35-clamav || exit 0

# Package names genuinely split on Debian: "clamav-update" (an EL virtual-
# provide alias for clamav-freshclam, not a real package there) and "clamd"
# (an EL-only name; the daemon is clamav-daemon on Debian, tracked separately
# below via $CLAMD_SVC). clamav-freshclam is the actual package+service name
# on BOTH platforms -- confirmed, not a guess -- so that one needs no branch.
if [ "$PKG_MGR" = apt ]; then
  pkg_install clamav-freshclam clamav-daemon
  fc_conf=/etc/clamav/freshclam.conf
  clamd_conf=/etc/clamav/clamd.conf
else
  pkg_install clamav clamav-update clamd
  fc_conf=/etc/freshclam.conf
  clamd_conf=/etc/clamd.d/scan.conf
fi

# enable freshclam (definition auto-update) — reference box had this DISABLED
# with 79-day-stale defs, so make it explicit.
if [ "$DRY_RUN" != 1 ]; then
  # ensure freshclam is not fully disabled in its config
  sed -i 's/^Example/#Example/' "$fc_conf" 2>/dev/null || true
  # On Debian the clamav-freshclam DAEMON is already running (the package
  # starts it), and it holds an exclusive lock on the log file -- a manual
  # `freshclam` there fails with "Failed to lock the log file ... Resource
  # temporarily unavailable" and downloads nothing. So only run it by hand
  # where nothing else owns the job; otherwise let the daemon do it and wait
  # for the result below.
  if systemctl is-active --quiet clamav-freshclam 2>/dev/null; then
    log_info "clamav-freshclam already running — it owns the initial download"
  else
    log_info "pulling initial virus definitions (freshclam)"
    freshclam --quiet || log_warn "initial freshclam run failed (will retry via timer)"
  fi
fi
svc_enable clamav-freshclam

# clamd socket service (rspamd's antivirus module talks to this socket)
if [ "$DRY_RUN" != 1 ]; then
  sed -i 's/^Example/#Example/' "$clamd_conf" 2>/dev/null || true
  grep -q '^LocalSocket ' "$clamd_conf" 2>/dev/null || \
    echo "LocalSocket ${CLAMD_SOCKET:-/run/clamd.scan/clamd.sock}" >> "$clamd_conf"
fi
# Debian's clamav-daemon.service carries
#   ConditionPathExistsGlob=/var/lib/clamav/daily.{c[vl]d,inc}
# so it REFUSES to start until the signature database exists, and systemd
# reports that as a skip, not a failure. On a fresh host the initial download
# is ~25MB and takes minutes, so the daemon was skipped and nothing ever
# retried -- clamd stayed dead indefinitely and rspamd reported
# CLAM_VIRUS_FAIL on every message. Observed on a real Ubuntu 24.04 install.
#
# So wait for the definitions to land before trying to start it. Bounded, and
# a timeout is a warning rather than a hard failure: mail must still flow,
# and the freshclam timer will finish the download afterwards.
if [ "$DRY_RUN" != 1 ]; then
  clamav_db_wait=${CLAMAV_DB_WAIT:-300}
  if ! ls /var/lib/clamav/daily.c[vl]d /var/lib/clamav/daily.cld >/dev/null 2>&1; then
    log_info "waiting up to ${clamav_db_wait}s for the initial virus definitions (~25MB)"
    waited=0
    while [ "$waited" -lt "$clamav_db_wait" ]; do
      ls /var/lib/clamav/daily.c[vl]d >/dev/null 2>&1 && break
      sleep 10; waited=$((waited + 10))
    done
    if ls /var/lib/clamav/daily.c[vl]d >/dev/null 2>&1; then
      log_info "virus definitions present after ${waited}s"
    else
      log_warn "virus definitions still absent after ${clamav_db_wait}s — ${CLAMD_SVC:-clamd@scan} cannot start yet"
      log_warn "the freshclam timer will keep trying; re-run '--only 35-clamav' once /var/lib/clamav/daily.cvd exists"
    fi
  fi
fi
svc_try "${CLAMD_SVC:-clamd@scan}" 2>/dev/null \
  || log_warn "${CLAMD_SVC:-clamd@scan} not enabled yet — rspamd will report CLAM_VIRUS_FAIL until it is"

# ---- clamav-unofficial-sigs -------------------------------------------------
# Third-party signature sources (Sanesecurity, SecuriteInfo, URLhaus, ...) plus
# the YARA rule sets. The ilexa console's ClamAV panel drives this: its
# signature-source and YARA toggles do nothing but edit
# /etc/clamav-unofficial-sigs/user.conf, so without this package the panel is
# inert (clamav-sig-toggle.sh now fails honestly rather than claiming success).
#
# EL only, and deliberately so: it is a real EPEL package there (verified
# clamav-unofficial-sigs-8.0.0-1.el9 on the reference host). Debian and Ubuntu
# have no usable equivalent -- and note the earlier claim here that they do not
# package it "at ANY version" was wrong, so spell out the real reason:
#   * Ubuntu 24.04 (noble) and 26.04, and Debian trixie onward, dropped it
#     entirely -- there is nothing to install.
#   * Ubuntu 22.04 (jammy) and Debian bookworm still carry version 3.7.2, but
#     that is a DIFFERENT upstream from the eXtremeSHOK 8.x on EL: it is
#     configured through /etc/clamav-unofficial-sigs.conf plus a conf.d
#     directory, and never creates the master.conf/user.conf pair the console's
#     toggles edit. Installing it would not make the panel work.
# So on apt the files come from upstream directly. That was declined once as a
# supply-chain risk and the decision was reversed deliberately, so the risk is
# managed rather than accepted wholesale: the 8.0.0 release is VENDORED into
# assets/clamav-unofficial-sigs/ with a SHA256SUMS manifest that this module
# verifies before installing anything, instead of upstream's documented
# `wget .../master/clamav-unofficial-sigs.sh` which pulls the tip of a moving
# branch onto the host mid-install. Nothing is fetched from GitHub at install
# time; see assets/clamav-unofficial-sigs/PROVENANCE.
#
# Either way the console follows the host: clamav-status.sh reports
# unofficial_installed from the presence of master.conf/user.conf, so the
# signature/YARA panel appears exactly where the tool really is, and stays
# hidden (rather than inventing nine "active" sources from the built-in
# defaults) where it is not — for instance when ENABLE_UNOFFICIAL_SIGS=no.
if [ "${ENABLE_UNOFFICIAL_SIGS:-yes}" = yes ] && [ "$PKG_MGR" != apt ]; then
  if pkg_try clamav-unofficial-sigs; then
    # The package ships BOTH /etc/cron.d/clamav-unofficial-sigs (hourly, at a
    # random minute, enabled on install) and a clamav-unofficial-sigs.timer
    # that it leaves disabled. Enabling the timer as well would run the
    # updater twice an hour against the same databases, so leave it alone --
    # the cron file is already the live scheduler.
    if [ "$DRY_RUN" != 1 ] && [ ! -f /etc/clamav-unofficial-sigs/user.conf ]; then
      log_warn "clamav-unofficial-sigs installed but user.conf is missing — the console's signature panel will not work"
    else
      log_info "clamav-unofficial-sigs installed (hourly via its own /etc/cron.d)"
    fi
  else
    log_warn "clamav-unofficial-sigs unavailable (EPEL enabled?) — the console's ClamAV signature/YARA panel will be inert"
  fi
elif [ "${ENABLE_UNOFFICIAL_SIGS:-yes}" = yes ]; then
  # ---- Debian/Ubuntu: install the vendored upstream release -----------------
  # There is no usable package here (see above), so the files come from
  # assets/clamav-unofficial-sigs/ — the pinned 8.0.0 release, checksummed,
  # in git. Deliberately NOT upstream's documented install, which wgets the
  # tip of master onto the host at install time; see the PROVENANCE file.
  _cus_src="$MD_ASSETS/clamav-unofficial-sigs"
  _cus_etc=/etc/clamav-unofficial-sigs
  if [ ! -d "$_cus_src" ]; then
    log_warn "clamav-unofficial-sigs assets missing ($_cus_src) — the console's signature/YARA panel will stay hidden"
  elif [ "$DRY_RUN" = 1 ]; then
    log_info "[dry-run] would install vendored clamav-unofficial-sigs 8.0.0 into $_cus_etc"
  elif ! ( cd "$_cus_src" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    # Refuse rather than install unverified third-party code onto a mail server.
    log_error "clamav-unofficial-sigs assets FAILED their SHA256SUMS check — refusing to install them"
  else
    install -d -m 0755 "$_cus_etc"
    install -m 0755 "$_cus_src/clamav-unofficial-sigs.sh" /usr/local/sbin/clamav-unofficial-sigs.sh
    install -m 0644 "$_cus_src/master.conf" "$_cus_etc/master.conf"

    # os.conf differs per distro (clam user, db dir, how to restart clamd).
    # Ubuntu and Debian have separate upstream files and they are NOT
    # interchangeable: the Debian one sets logrotate_group=adm.
    case "$(. /etc/os-release 2>/dev/null; echo "${ID:-}")" in
      ubuntu) _cus_os=os.ubuntu.conf ;;
      *)      _cus_os=os.debian.conf ;;
    esac
    install -m 0644 "$_cus_src/$_cus_os" "$_cus_etc/os.conf"
    log_info "clamav-unofficial-sigs os.conf from $_cus_os"

    # user.conf is the ONE file the ilexa console writes: every signature-source
    # rating and the YARA switch live there. Overwriting it on a re-run would
    # silently reset every choice the admin made in the panel, so it is created
    # once and then left alone.
    if [ -f "$_cus_etc/user.conf" ]; then
      log_info "clamav-unofficial-sigs user.conf exists — keeping the console's settings"
    else
      install -m 0644 "$_cus_src/user.conf" "$_cus_etc/user.conf"
    fi

    # Schedule it. --install-cron is upstream's own generator, so the cadence
    # and lock handling stay whatever upstream intends. EL gets its cron from
    # the EPEL package; this is the apt-side equivalent.
    if [ ! -f /etc/cron.d/clamav-unofficial-sigs ]; then
      /usr/local/sbin/clamav-unofficial-sigs.sh --install-cron >/dev/null 2>&1 \
        && log_info "clamav-unofficial-sigs cron installed" \
        || log_warn "clamav-unofficial-sigs --install-cron failed — signatures will not auto-update"
    fi

    # First run populates /var/lib/clamav with the third-party databases. It is
    # a network fetch of tens of MB, so it is bounded and non-fatal: cron
    # retries, and mail must flow either way.
    log_info "clamav-unofficial-sigs: initial signature download (bounded ${CUS_FIRST_RUN_TIMEOUT:-600}s)"
    if timeout "${CUS_FIRST_RUN_TIMEOUT:-600}" /usr/local/sbin/clamav-unofficial-sigs.sh --force >/dev/null 2>&1; then
      log_info "clamav-unofficial-sigs installed 8.0.0 — the console's signature/YARA panel is now live"
    else
      log_warn "clamav-unofficial-sigs first run did not complete — cron will retry; panel appears once user.conf and the databases exist"
    fi
    unset _cus_src _cus_etc _cus_os
  fi
fi

# ---- stop the updater trying to restart clamd -------------------------------
# Symptom: root gets an hourly cron mail from clamav-unofficial-sigs.sh --
#
#   ERROR: Failed to reload, forcing clamd to restart
#   Failed to restart clamav-daemon.service: Interactive authentication required.
#
# Two things combine. First, `clamdscan --reload` reports "Clamd did not reload
# the database" even when the reload SUCCEEDS -- reproduced here as root, while
# clamd's own log showed "Database correctly reloaded (3849592 signatures)"
# seconds earlier. Second, the script escalates that false failure to
# `systemctl restart`, and on Debian/Ubuntu its cron entry runs as the *clamav*
# user, which cannot restart a unit. So every hour the updater declares failure
# and mails root about a database that had in fact updated correctly.
#
# The reload is not needed at all: clamd's own SelfCheck notices the modified
# databases and reloads them itself -- 7 times in the 24h before this was
# written, every one successful. Turning reload_dbs off removes the false error
# and the impossible restart in one step, and costs at most SelfCheck's
# interval (3600s here) before new signatures are live.
#
# This is also what the reference host already does. Its user.conf carries
# reload_dbs="no" and its cron runs as root, which is why the problem never
# appeared there -- the installer simply never learned the setting.
#
# user.conf belongs to the ilexa console (every signature-source rating lives
# in it), so the key is only ADDED when absent and an existing value is left
# exactly as the admin set it.
if [ "${ENABLE_UNOFFICIAL_SIGS:-yes}" = yes ] && [ "$DRY_RUN" != 1 ] \
   && [ -f /etc/clamav-unofficial-sigs/user.conf ]; then
  if grep -qE '^[[:space:]]*reload_dbs=' /etc/clamav-unofficial-sigs/user.conf; then
    log_info "clamav-unofficial-sigs: reload_dbs already set in user.conf — leaving it"
  else
    cat >> /etc/clamav-unofficial-sigs/user.conf <<'EOF'

# Added by ilexa-installer. `clamdscan --reload` reports a failure even when
# clamd reloads correctly, and the script then tries `systemctl restart`, which
# its cron user cannot do -- producing an hourly failure mail about a database
# that updated fine. clamd's SelfCheck reloads modified databases on its own.
reload_dbs="no"
EOF
    log_info "clamav-unofficial-sigs: reload_dbs=\"no\" set (clamd SelfCheck reloads databases; avoids hourly false-failure mail to root)"
  fi
fi

# ---- rspamd scoring for the antivirus module's two symbols -----------------
# 40-rspamd's antivirus.conf.tmpl and force_actions.conf.tmpl (rendered every
# run, unconditionally) create CLAM_VIRUS and extract CLAM_YARA from clamd's
# hits, but neither template can SCORE them -- groups.conf is never rendered
# by any module (see the otx_uri and urlhaus fixes earlier), only appended-to,
# so a symbol's weight has to be added explicitly somewhere or it defaults to
# 0 and never affects the message score.
#
# That was true here and nothing had ever added it: confirmed live on a real
# Ubuntu 24.04 install with the YARA Forge pack loaded (4204 rules active in
# clamd) -- CLAM_YARA showed weight 0.0 in rspamc counters. The whole feature
# this session started by debugging ("Ismeretlen feed" on the YARA Forge
# refresh button) was, even after that fix, downloading and clamd-loading real
# rule matches that could never move a message's score by one point. Every
# other installer-built host has had the same silent no-op since 35-clamav
# has existed.
#
# CLAM_VIRUS's absence was not exploitable the same way -- force_actions.conf
# hard-rejects on the symbol firing at all, independent of its score -- but it
# is registered here too rather than leaving it at an accidental 0, matching
# production exactly (both symbols live in the same "antivirus" group there).
#
# Unconditional, like the templates that create these symbols: CLAM_VIRUS
# fires on any clamd hit regardless of unofficial-sigs, and CLAM_YARA is
# harmless to register even before any YARA rules are loaded -- it simply
# never fires until either clamav-unofficial-sigs or the yara_forge feed
# populates /var/lib/clamav with .yar content.
if [ "$DRY_RUN" != 1 ]; then
  LOCALD=/etc/rspamd/local.d
  # rspamd itself is module 40, installed AFTER this one -- on a fresh host
  # /etc/rspamd does not exist yet at this point, and `touch` into a missing
  # directory dies outright ("No such file or directory"), taking the whole
  # module down with it. Reported live on a genuinely fresh Ubuntu install.
  install -d -m 755 "$LOCALD"
  touch "$LOCALD/groups.conf"
  if ! grep -q '"CLAM_YARA"' "$LOCALD/groups.conf"; then
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "antivirus" {
  symbols {
    "CLAM_YARA"  { weight =  6.0; description = "ClamAV YARA rule match (heuristic) — score only, not an auto-reject"; }
    "CLAM_VIRUS" { weight = 15.0; description = "ClamAV virus/signature hit (also force-rejected via force_actions)"; }
  }
}
EOF
    log_info "appended CLAM_YARA/CLAM_VIRUS weights to $LOCALD/groups.conf"
    if systemctl is-active --quiet rspamd; then
      rspamadm configtest >/dev/null 2>&1 && systemctl reload rspamd \
        && log_info "rspamd reloaded to pick up the antivirus group weights" \
        || log_warn "antivirus group config did not pass configtest — NOT reloaded, check $LOCALD/groups.conf"
    fi
  fi
fi

mark_done 35-clamav
log_info "clamav ready"
