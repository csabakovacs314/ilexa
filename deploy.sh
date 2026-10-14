#!/usr/bin/env bash
# deploy.sh — mail-deploy entrypoint (AlmaLinux/Rocky 9/10 + Ubuntu 22.04/24.04/26.04 LTS mail-server deployer).
# Flow: preflight -> collect answers (wizard or --answers) -> confirm -> run modules.
#
# Usage:
#   ./deploy.sh                      interactive whiptail wizard
#   ./deploy.sh --answers FILE       unattended, values from FILE
#   ./deploy.sh --dry-run [...]      log intended actions, change nothing
#   ./deploy.sh --only 20-postfix    run a single module (repeatable)
#   ./deploy.sh --help
set -o pipefail

MD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MD_ROOT
# shellcheck source=lib/common.sh
source "$MD_ROOT/lib/common.sh"
# shellcheck source=lib/tui.sh
source "$MD_ROOT/lib/tui.sh"
# shellcheck source=lib/progress.sh
source "$MD_ROOT/lib/progress.sh"
# shellcheck source=lib/db.sh
source "$MD_ROOT/lib/db.sh"

ANSWERS=""
declare -a ONLY=()

# Shown on the interactive start screen (see tui_welcome). No specific OS
# named here on purpose -- tui_welcome's own title line already shows the
# real detected OS (main()'s early os_detect call sets MD_OS_LABEL), so
# naming one here too would risk contradicting it.
MD_PURPOSE="  Stands up a complete, hardened mail server on a FRESH host
  from parameterized templates (no live secrets are copied):

    * Postfix + Dovecot IMAP/POP3, rspamd + ClamAV
    * OpenDKIM / DMARC / SPF, postscreen DNSBLs
    * PostfixAdmin, Roundcube webmail, the ilexa console
    * Fail2Ban, firewalld geoblock, SSH key-only hardening

  Questions first, then a review screen; only THEN are changes
  made, and existing files are backed up first.

  WARNING: fresh hosts only -- overwrites /etc/postfix,
  /etc/dovecot and databases with templated defaults."

# Prints the comment header above, stopping at the first line that is not a
# comment. The old form was a fixed `sed -n '2,12p'`, which ran two lines past
# the header and printed "set -o pipefail" as if it were help text; a fixed
# range also silently rots whenever the header grows or shrinks.
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --answers) ANSWERS="${2:?--answers needs a file}"; shift 2 ;;
      --dry-run) export DRY_RUN=1; shift ;;
      --only)    ONLY+=("${2:?--only needs a module}"); shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

# ---- required-answer keys + defaults --------------------------------------
REQUIRED_KEYS=(MAIL_FQDN PRIMARY_DOMAIN ADMIN_EMAIL MAIL_STORE TLS_MODE)

load_answers() {
  [ -r "$ANSWERS" ] || die "answers file not readable: $ANSWERS"
  # shellcheck disable=SC1090
  source "$ANSWERS"
  log_info "loaded answers from $ANSWERS"
  # MAIL_FQDN left at the shipped example placeholder almost always means the
  # operator copied answers.example.conf and never edited it -- silently
  # proceeding produces a non-resolving FQDN whose consequences (failed
  # Let's Encrypt issuance, broken TLS) only surface much later in the run.
  # Ask for the real value now instead, same as the interactive wizard would.
  # PRIMARY_DOMAIN gets the same treatment as MAIL_FQDN below, and for a
  # sharper reason than cosmetics: it is what ARCHIVE_USER is derived from, and
  # ARCHIVE_USER is baked into BOTH config.php and the root-owned qa-doveadm.sh
  # gateway. Leaving it at "example.com" renders a gateway that refuses every
  # archive fetch ("INBOX allowed only for the archive account") because the
  # account it compares against does not exist -- the console then cannot
  # display ANY message content, with no error pointing at the cause. Observed
  # on the 24.04 host on 2026-08-17 after a module was run with the example
  # answers file unedited.
  if [ "${PRIMARY_DOMAIN:-}" = "example.com" ]; then
    if [ -t 0 ]; then
      log_warn "PRIMARY_DOMAIN is still the example placeholder (example.com)"
      read -rp "Enter the real primary mail domain: " PRIMARY_DOMAIN
      [ -n "$PRIMARY_DOMAIN" ] || die "no domain entered — aborting"
    else
      die "PRIMARY_DOMAIN is still the example placeholder 'example.com' in $ANSWERS -- edit it to your real domain (it decides the archive account baked into config.php AND the doveadm gateway; a placeholder here silently breaks message viewing)"
    fi
  fi

  if [ "${MAIL_FQDN:-}" = "mail.example.com" ]; then
    if [ -t 0 ]; then
      log_warn "MAIL_FQDN is still the example placeholder (mail.example.com)"
      read -rp "Enter the real mail server FQDN (MX target / TLS CN): " MAIL_FQDN
      [ -n "$MAIL_FQDN" ] || die "no FQDN entered — aborting"
    else
      die "MAIL_FQDN is still the example placeholder 'mail.example.com' in $ANSWERS -- edit it to your real FQDN (no TTY attached, so it can't be asked interactively here)"
    fi
  fi
}

# whiptail is a PREREQUISITE of the wizard, not just of the stack it builds.
# 05-base.sh installs it, but that module runs inside run_modules() -- long
# AFTER collect_interactive() has to draw its first dialog. On a fresh host
# the wizard could therefore never start: it died telling the operator to go
# install a package by hand, which is the installer's own job. Bootstrap it
# here instead. (EL ships whiptail inside "newt"; Debian's package is named
# for the binary.)
ensure_tui() {
  command -v whiptail >/dev/null 2>&1 && return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    [ "$PKG_MGR" = apt ] && hint="apt-get install -y whiptail" || hint="dnf install -y newt"
    die "whiptail is missing and --dry-run must not install packages — run '$hint' first, or use --answers"
  fi
  # The apt package lists are only refreshed by 05-base.sh, which runs much
  # later; on a fresh image they can be absent or stale enough that this
  # install fails. preflight_host already does the dnf equivalent, so only
  # the apt side needs one here.
  # Lock timeout: see pkg_try() in lib/common.sh -- a fresh Ubuntu box has
  # unattended-upgrades holding the dpkg lock on first boot.
  [ "$PKG_MGR" = apt ] && apt-get -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" update -qq
  [ "$PKG_MGR" = apt ] && tui_pkg=whiptail || tui_pkg=newt
  log_info "whiptail missing — installing $tui_pkg so the wizard can run"
  pkg_install "$tui_pkg"
  command -v whiptail >/dev/null 2>&1 \
    || die "installed $tui_pkg but whiptail is still not on PATH — use --answers instead"
}

# One screenful of host facts, shown BEFORE anything is asked or installed:
# the operator confirms they are on the box they think they are on (fresh
# cloud images all look alike, and this tool overwrites /etc/postfix and the
# databases -- running it on the wrong host is the worst mistake it enables).
# Interactive: a msgbox (OK-focused). --answers mode: the same block as log
# lines, so unattended runs record what the host looked like at t=0.
show_sysinfo() {
  local virt mem swap disk cpu ip host
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  cpu=$(nproc 2>/dev/null || echo '?')
  mem=$(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)
  swap=$(awk '/SwapTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)
  disk=$(df -h / 2>/dev/null | awk 'NR==2{print $4 " free of " $2 " on /"}')
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
  host=$(hostname -f 2>/dev/null || hostname)
  local info
  info="OS:        ${MD_OS_LABEL:-unknown}
Kernel:    $(uname -r)  ($(uname -m))
Virt:      ${virt}
CPU:       ${cpu} vCPU
Memory:    ${mem:-?}   Swap: ${swap:-?}
Disk:      ${disk:-?}
Hostname:  ${host}
IPv4:      ${ip:-none}

This tool will OVERWRITE /etc/postfix, /etc/dovecot, firewalld zones and
the MariaDB databases on THIS host. Continue only if this is the fresh
box you intend to turn into a mail server."
  if [ -n "$ANSWERS" ] || ! _tui_ok; then
    log_info "host at start of run:"
    while IFS= read -r _l; do log_info "  $_l"; done <<<"$info"
  else
    tui_msg "HOST CHECK — is this the right machine?" "$info"
  fi
}

# ---- the interactive wizard ---------------------------------------------------
# collect_interactive() decides which steps this host gets and hands them to
# tui_wizard (lib/tui.sh), which walks them -- Exit on step 1, Back on every
# step after it, Esc quits anywhere -- and ends on the review screen, where
# Change... re-runs one step and returns to the review. Nothing is written
# before Apply.
#
# Each wz_* step function:
#   - prefills from the answer it got the last time it ran (_wz_default), so
#     Back and Change... show what was entered rather than the first default;
#   - assigns its variables only once ALL of its dialogs are answered, so
#     backing out half-way through a step leaves the earlier answer intact;
#   - runs its own validation every time it runs, so a changed answer is
#     checked exactly like a first one;
#   - returns its dialog's status: 0 = answered, 1 = Back/Exit, other = quit.
collect_interactive() {
  ensure_tui
  wz_init
  # Probed BEFORE the first question rather than where its question sits:
  # whether that step exists decides N in "Step n of N", and N must not change
  # half-way through. Throwaway rpm database, nothing imported -- see the
  # function. The answer cannot change during the run, so it is asked once.
  # Said out loud: the fetch can take up to 20 s, and nothing else is on the
  # screen while it runs. (A whiptail infobox would vanish at once on any
  # terminal with an alternate screen, so a plain line it is.)
  local rspamd_step=0
  log_info "checking whether this system accepts rspamd's package signing key (can take up to 20 s)..."
  rspamd_key_importable || rspamd_step=1
  MD_WZ_STEPS=(
    "wz_fqdn|Mail server FQDN"
    "wz_domain|Primary mail domain"
    "wz_extra_domains|Extra mail domains"
    "wz_admin_email|Admin email"
    "wz_alert_email|Alert email"
    "wz_admin_password|Admin password"
    "wz_mail_store|Mail store"
    "wz_timezone|Timezone"
    "wz_tls|TLS certificate"
    "wz_spam_reject|Spam reject threshold"
    "wz_geoblock|Geoblock"
    "wz_ssh_port|SSH port"
    "wz_otx|AlienVault OTX"
    "wz_dqs|Spamhaus DQS"
    "wz_feeds|Reputation feeds"
  )
  [ "$rspamd_step" = 1 ] && MD_WZ_STEPS+=("wz_rspamd_unsigned|rspamd signature")
  MD_WZ_STEPS+=(
    "wz_archive|Mail archive"
    "wz_greylisting|Greylisting"
    "wz_language|Interface language"
    "wz_pwexpiry|Password expiry"
    "wz_extras|Optional extras"
    "wz_hardening|Hardening"
  )
  local rc=0
  tui_wizard review_text wz_value wz_rederive || rc=$?
  # The answer memory holds every password and API key typed, in plain text,
  # including ones later replaced. The answers themselves live on in their own
  # variables; the memory has no use after the review.
  unset _WZ_MEM _WZ_OFFERED _WZ_ORIG _WZ_VAL _WZ_DEF
  [ "$rc" = 0 ] || md_abort
  if [ "$rspamd_step" = 1 ] && [ "${RSPAMD_ALLOW_UNSIGNED:-no}" = yes ]; then
    log_warn "operator accepted UNVERIFIED rspamd packages (RSPAMD_ALLOW_UNSIGNED=yes)"
  fi
  return 0
}

# After a Change... from the review: an answer that was simply the default
# derived from another one follows that one. Change the primary domain, and an
# admin address that was postmaster@<old domain> only because that was offered
# becomes postmaster@<new domain> -- as a straight run with the new domain would
# have offered. An answer the operator typed differently is left alone. In
# order, because each default is derived from the one before.
wz_rederive() {
  _wz_follow PRIMARY_DOMAIN "${MAIL_FQDN#*.}"
  _wz_follow ADMIN_EMAIL "postmaster@$PRIMARY_DOMAIN"
  _wz_follow ALERT_EMAIL "$ADMIN_EMAIL"
  return 0
}
_wz_follow() { # KEY new_default
  if [ -n "${_WZ_MEM[$1]+x}" ] && [ "${_WZ_MEM[$1]}" = "${_WZ_OFFERED[$1]-}" ]; then
    _wz_set "$1" "$2" "$2"
  fi
  return 0
}

wz_init() {
  declare -gA _WZ_MEM=() _WZ_OFFERED=() _WZ_ORIG=()
  _WZ_DEF=""; _WZ_VAL=""
  # Keys that only some answers ask for. If a later Back/Change... takes the
  # other branch, they go back to what they were before the wizard -- the same
  # end state as a straight run that never asked them.
  _wz_snapshot TLS_CUSTOM_CERT TLS_CUSTOM_KEY OTX_API_KEY \
    ABUSECH_API_KEY ABUSEIPDB_API_KEY ARCHIVE_RETENTION_DAYS
  # tag|VARIABLE|label|default. ONE table per checklist, read by the checklist,
  # by the review and by the Change... menu, so the review can never describe
  # an option with different words than the screen that offered it.
  WZ_EXTRAS=(
    "last_login|ENABLE_LAST_LOGIN|Dovecot last-login tracking|yes"
    "fts_xapian|ENABLE_FTS_XAPIAN|Full-text search (compiled; RAM-heavy)|yes"
    "unattended|ENABLE_UNATTENDED|Unattended security updates|yes"
    "mx_check|ENABLE_MX_CHECK|rspamd: sender MX validation (needs outbound :25)|yes"
    "known_senders|ENABLE_KNOWN_SENDERS|rspamd: per-sender freemail reputation|yes"
  )
  # clamav-unofficial-sigs is packaged in EPEL but has NO Debian/Ubuntu
  # package at all (checked: apt only offers "fangfrisch", a different tool
  # with an incompatible config format). Offering the choice on apt would be
  # offering something we cannot deliver, so the item only appears where it
  # can actually be installed; 35-clamav logs the reason on apt.
  if [ "${PKG_MGR:-dnf}" != apt ]; then
    WZ_EXTRAS+=("unofficial_sigs|ENABLE_UNOFFICIAL_SIGS|Third-party ClamAV signature sources + YARA|yes")
  fi
  WZ_HARDENING=(
    "ssh|HARDEN_SSH_KEYONLY|SSH key-only + sudo admin user|yes"
    "webmin|HARDEN_WEBMIN|Webmin source-IP allowlist|yes"
    "reboot|HARDEN_KERNEL_AUTOREBOOT|Kernel auto-reboot maintenance window|yes"
    "smtp|HARDEN_SMTP_TUNING|SMTP tuning (50M limit, delay_reject)|yes"
  )
  # SELinux is EL-only -- 85-hardening.sh already no-ops HARDEN_SELINUX=yes on
  # Debian/Ubuntu with a warning ("SELinux is EL-only"), because the
  # answers-file path can set it for any OS and that path must still fail
  # safely. But the WIZARD offering it as a selectable item on every OS,
  # including where it can only ever do nothing, is its own bug: reported live
  # as "selinux is selectable on ubuntu 24, however it exists only on CentOS".
  # Only add it to the list where it can actually do something.
  if [ "${PKG_MGR:-}" = dnf ]; then
    WZ_HARDENING+=("selinux|HARDEN_SELINUX|SELinux enforcing (advanced)|no")
  fi
  return 0
}

# _wz_default KEY default -> _WZ_DEF, the value to prefill.
# The answer from the last time this step ran -- unless that answer simply WAS
# the default on offer then, in which case today's default is offered. That
# matters for derived defaults: accept "example.org" as the mail domain (taken
# from the FQDN), go Back, fix a typo in the FQDN, and the domain offered next
# follows the corrected FQDN instead of keeping the typo.
_wz_default() {
  if [ -n "${_WZ_MEM[$1]+x}" ] && [ "${_WZ_MEM[$1]}" != "${_WZ_OFFERED[$1]-}" ]; then
    _WZ_DEF=${_WZ_MEM[$1]}
  else
    _WZ_DEF=$2
  fi
  return 0
}
_wz_set() { # KEY value default_that_was_offered
  printf -v "$1" '%s' "$2"
  _WZ_MEM[$1]=$2; _WZ_OFFERED[$1]=$3
}
_wz_snapshot() { # KEY... -> remember each key's value from before the wizard
  local k
  for k in "$@"; do
    if [ -n "${!k+x}" ]; then _WZ_ORIG[$k]=${!k}; fi
  done
  return 0
}
_wz_unasked() { # KEY... -> back to the pre-wizard value (or unset): not asked after all
  local k
  for k in "$@"; do
    if [ -n "${_WZ_ORIG[$k]+x}" ]; then printf -v "$k" '%s' "${_WZ_ORIG[$k]}"; else unset "$k"; fi
  done
  return 0
}

# _wz_input KEY prompt default [required]
# One free-text answer. "required" refuses a blank one here, in its own step,
# with the same rule validate() applies (REQUIRED_KEYS) -- otherwise the blank
# would only be caught after Apply, by a die that discards every answer.
_wz_input() {
  local v rc
  _wz_default "$1" "$3"; v=$_WZ_DEF
  while true; do
    v=$(tui_input "$2" "$v") || return $?
    if [ -n "$v" ] || [ "${4:-}" != required ] || ! _tui_ok; then break; fi
    rc=0; tui_msg "Answer required" "This one cannot be left blank -- the install needs it." || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 1 ] || return "$rc"
    v=$3
  done
  _wz_set "$1" "$v" "$3"
}

# _wz_secret prompt blank_label current -> _WZ_VAL
# A password or API key. It is never prefilled: whiptail takes an initial value
# only on its command line, where /proc/<pid>/cmdline shows it to every local
# user (see tui_password). When a value already exists, a choice comes first --
# keep it, type another, or leave it blank -- so Back does not mean re-typing.
_wz_secret() {
  local prompt="$1" blank="$2" cur="${3:-}" c v rc s=1 first
  if [ -n "$cur" ] && _tui_ok; then s=0; fi
  first=$s
  while true; do
    if [ "$s" = 0 ]; then
      c=$(tui_choice "" "$prompt

One was entered on an earlier visit. It is not shown, and never goes on a command line where other local users could read it." keep \
        keep  "Keep the one entered before" \
        new   "Type a different one" \
        blank "$blank") || return $?
      case "$c" in
        keep)  _WZ_VAL=$cur; return 0 ;;
        blank) _WZ_VAL="";   return 0 ;;
      esac
      s=1
    fi
    rc=0; v=$(tui_password "$prompt") || rc=$?
    if [ "$rc" = 1 ] && [ "$first" = 0 ]; then s=0; continue; fi
    [ "$rc" = 0 ] || return "$rc"
    _WZ_VAL=$v; return 0
  done
}

# _wz_checklist title row... (rows: see WZ_EXTRAS) -- one yes/no per row
_wz_checklist() {
  local title="$1" row tag var label def st picked v args=()
  shift
  for row in "$@"; do
    IFS='|' read -r tag var label def <<<"$row"
    _wz_default "$var" "$def"
    if [ "$_WZ_DEF" = yes ]; then st=on; else st=off; fi
    args+=("$tag" "$label" "$st")
  done
  picked=$(tui_checklist "$title" "${args[@]}") || return $?
  for row in "$@"; do
    IFS='|' read -r tag var label def <<<"$row"
    case " $picked " in *" $tag "*) v=yes ;; *) v=no ;; esac
    _wz_set "$var" "$v" "$def"
  done
}

_wz_tls_label() { # mode -> the words the TLS step uses for it
  case "$1" in
    letsencrypt) printf '%s' "Let's Encrypt" ;;
    custom)      printf '%s' "My own certificate (PEM files on this host)" ;;
    selfsigned)  printf '%s' "Self-signed lab cert (browsers WILL warn)" ;;
    *)           printf '%s' "$1" ;;
  esac
}
_wz_lang_label() { # code -> the words the language step uses for it
  case "$1" in
    en) printf 'English' ;;
    hu) printf 'Magyar (Hungarian)' ;;
    *)  printf '%s' "$1" ;;
  esac
}

# No placeholder pre-filled on the first visit, on purpose: offering
# "mail.example.com" as the suggested default meant pressing Enter/OK without
# editing it silently accepted the placeholder as a real answer -- confirmed
# live, an operator did exactly this repeatedly and only noticed once TLS/DNS
# broke much later. Loop until a real, dotted, non-placeholder value is
# entered.
wz_fqdn() {
  local v
  if _tui_ok; then
    _wz_default MAIL_FQDN ""; v=$_WZ_DEF
    while true; do
      v=$(tui_input "Mail server public FQDN (MX target / TLS CN), e.g. mail.yourdomain.com:" "$v") || return $?
      case "$v" in
        ""|mail.example.com)
          tui_msg "FQDN required" "Enter your actual mail server FQDN. \"mail.example.com\" is only a placeholder from the docs — it won't resolve." || return $?
          # Come back with an EMPTY box rather than re-offering the value
          # just rejected: whiptail pre-fills the default with the cursor
          # at the end and typing APPENDS to it, so re-seeding the
          # placeholder means the next attempt silently becomes
          # "mail.example.com<whatever they type>" unless they manually
          # clear the field first.
          v="" ;;
        *.*) break ;;
        *) tui_msg "Invalid FQDN" "\"$v\" doesn't look like a FQDN (needs at least one dot, e.g. mail.yourdomain.com)." || return $?
           v="" ;;
      esac
    done
  else
    # No real TTY (whiptail present but stdin/stdout aren't interactive) --
    # nobody is present to answer prompts either way, so fall back to a
    # single non-looping call rather than spin forever waiting for a value
    # that will never change. tui_input's own non-TTY branch just echoes
    # this default straight back.
    v=$(tui_input "Mail server public FQDN (MX target / TLS CN):" "mail.example.com") || return $?
  fi
  _wz_set MAIL_FQDN "$v" ""
  MAIL_HOSTNAME="${MAIL_FQDN%%.*}"
}

wz_domain() { _wz_input PRIMARY_DOMAIN "Primary virtual mail domain:" "${MAIL_FQDN#*.}" required; }
wz_extra_domains() { _wz_input EXTRA_DOMAINS "Extra virtual domains (space-separated, or blank):" ""; }
wz_admin_email() { _wz_input ADMIN_EMAIL "Admin / PostfixAdmin superadmin email:" "postmaster@$PRIMARY_DOMAIN" required; }

# Where scheduled jobs send alerts (feed refresh failures, SIEM export
# health, neural training milestones...). Asked separately from ADMIN_EMAIL
# because they are genuinely different roles -- the PostfixAdmin superadmin
# is a mailbox identity, this is a human who reads operational mail, and on
# a real deployment that is often a monitored address elsewhere. Defaults to
# ADMIN_EMAIL so answering nothing is still correct.
#
# This is seeded into /etc/ilexa/alerts.conf by 55-ilexa. Before it was
# asked, that file simply did not exist on a fresh install, so EVERY
# cron-alert.sh notification was silently discarded until someone found the
# setting in the console's Admin tab -- which nobody does before the first
# failure they needed to hear about.
wz_alert_email() { _wz_input ALERT_EMAIL "Email for system notifications/alerts (blank = none):" "$ADMIN_EMAIL"; }

wz_admin_password() {
  _wz_default ADMIN_PASSWORD ""
  _wz_secret "PostfixAdmin superadmin password (blank = auto-generate):" \
    "Leave it blank - generate one" "$_WZ_DEF" || return $?
  _wz_set ADMIN_PASSWORD "$_WZ_VAL" ""
}

wz_mail_store() { _wz_input MAIL_STORE "Maildir store root:" "/data/mail"; }

# Asked for explicitly: it drives the system clock, mail-log timestamps, cron
# and every time the console displays, and silently defaulting to UTC left
# operators reading their own logs two hours out. Defaults to whatever the
# host is already set to, so answering nothing changes nothing.
# Timezone: a menu of common zones plus "Other...", not a bare free-text
# field -- reported from a live run as offering nothing selectable. The
# host's CURRENT zone is preselected (plain Enter keeps it) and prepended so
# it is always an option even when it is not in the common list; "Other..."
# falls back to free text for anything else.
wz_timezone() {
  local s=0 host tz other v rc
  host="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  _wz_default TIMEZONE "$host"; tz=$_WZ_DEF; other=$host
  # A zone typed under "Other..." last time is not in the list: preselect
  # "Other..." and offer the typed zone there instead.
  case " $host Europe/Budapest Europe/London Europe/Berlin America/New_York America/Los_Angeles UTC " in
    *" $tz "*) : ;;
    *) other=$tz; tz=__other__ ;;
  esac
  while true; do
    case "$s" in
      0) v=$(tui_choice "System timezone" \
           "Drives the clock, mail-log timestamps and everything the console displays. The current host setting is listed first; Enter keeps the highlighted zone." \
           "$tz" \
           "$host" "current host setting" \
           Europe/Budapest "Hungary (CET/CEST)" \
           Europe/London   "UK" \
           Europe/Berlin   "Central Europe" \
           America/New_York "US Eastern" \
           America/Los_Angeles "US Pacific" \
           UTC             "Coordinated Universal Time" \
           __other__       "Other... (type an IANA name)") || return $?
         tz=$v
         if [ "$tz" = __other__ ]; then s=1; else break; fi ;;
      1) rc=0; v=$(tui_input "IANA timezone name (e.g. Asia/Tokyo):" "$other") || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         other=$v; tz=$v; break ;;
    esac
  done
  [ -n "$tz" ] || tz=$host
  _wz_set TIMEZONE "$tz" "$host"
}

# Three real answers, not two. Self-signed is a lab fallback -- no client
# accepts it -- so an operator who already holds a certificate must be able
# to say so here rather than install, discover the browser warning, and go
# looking for where to put their own cert. One menu, where this used to be two
# chained yes/no boxes (which also could not offer Back).
#
# The certificate files are checked HERE, with the same test validate() applies
# later: a mistyped path used to be found only after the review, by a die that
# threw away every answer.
wz_tls() {
  local s=0 mode cert key v rc
  _wz_default TLS_MODE letsencrypt;  mode=$_WZ_DEF
  _wz_default TLS_CUSTOM_CERT "";    cert=$_WZ_DEF
  _wz_default TLS_CUSTOM_KEY "";     key=$_WZ_DEF
  while true; do
    case "$s" in
      0) v=$(tui_choice "" "How should this server get its TLS certificate?

Self-signed is a lab fallback: no mail client or browser trusts it." "$mode" \
           letsencrypt "$(_wz_tls_label letsencrypt)" \
           custom      "$(_wz_tls_label custom)" \
           selfsigned  "$(_wz_tls_label selfsigned)") || return $?
         mode=$v
         if [ "$mode" = custom ]; then s=1; else break; fi ;;
      1) rc=0; v=$(tui_input "Path to your certificate (PEM; server cert first, then intermediates):" "$cert") || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         cert=$v
         if [ -s "$cert" ] || ! _tui_ok; then s=2; continue; fi
         rc=0; tui_msg "Certificate not found" "\"$cert\" does not exist or is empty. Enter the path of the PEM file on THIS host." || rc=$?
         [ "$rc" = 0 ] || [ "$rc" = 1 ] || return "$rc" ;;
      2) rc=0; v=$(tui_input "Path to its private key (PEM, not passphrase-protected):" "$key") || rc=$?
         if [ "$rc" = 1 ]; then s=1; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         key=$v
         if [ -s "$key" ] || ! _tui_ok; then break; fi
         rc=0; tui_msg "Private key not found" "\"$key\" does not exist or is empty. Enter the path of the PEM key file on THIS host." || rc=$?
         [ "$rc" = 0 ] || [ "$rc" = 1 ] || return "$rc" ;;
    esac
  done
  _wz_set TLS_MODE "$mode" letsencrypt
  if [ "$mode" = custom ]; then
    _wz_set TLS_CUSTOM_CERT "$cert" ""; _wz_set TLS_CUSTOM_KEY "$key" ""
  else
    _wz_unasked TLS_CUSTOM_CERT TLS_CUSTOM_KEY
  fi
}

wz_spam_reject() { _wz_input SPAM_REJECT "rspamd reject threshold (safety net; tag threshold is 4):" "15"; }
wz_geoblock() { _wz_input GEOBLOCK_COUNTRIES "Geoblock country codes:" "ru cn br kr"; }
wz_ssh_port() { _wz_input SSH_PORT "SSH port to open in firewalld:" "22"; }

wz_otx() {
  local s=0 on key v rc
  _wz_default ENABLE_OTX yes;  on=$_WZ_DEF
  _wz_default OTX_API_KEY "";  key=$_WZ_DEF
  while true; do
    case "$s" in
      0) v=$(tui_choice "" "Enable the AlienVault OTX threat-intel suite?" "$on" \
           yes "Yes - enable the OTX suite" \
           no  "No") || return $?
         on=$v
         if [ "$on" = yes ]; then s=1; else break; fi ;;
      1) rc=0; _wz_secret "OTX API key (blank = configure later):" \
           "No key now - configure it later" "$key" || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         key=$_WZ_VAL; break ;;
    esac
  done
  _wz_set ENABLE_OTX "$on" yes
  if [ "$on" = yes ]; then _wz_set OTX_API_KEY "$key" ""; else _wz_unasked OTX_API_KEY; fi
}

wz_dqs() {
  _wz_default SPAMHAUS_DQS_KEY ""
  _wz_secret "Spamhaus DQS account key (blank = skip, use rspamd's default public zones):" \
    "No key - use rspamd's default public zones" "$_WZ_DEF" || return $?
  _wz_set SPAMHAUS_DQS_KEY "$_WZ_VAL" ""
}

# Reputation feeds. Every updater is installed either way; a blank key simply
# leaves that source disabled, and it can be filled in later from the ilexa
# Admin tab without touching the installer again.
wz_feeds() {
  local s=0 on k1 k2 v rc
  _wz_default ENABLE_FEEDS yes;       on=$_WZ_DEF
  _wz_default ABUSECH_API_KEY "";     k1=$_WZ_DEF
  _wz_default ABUSEIPDB_API_KEY "";   k2=$_WZ_DEF
  while true; do
    case "$s" in
      0) v=$(tui_choice "" "Enable the reputation feeds?

Spamhaus, Abusix and others, queried live per message." "$on" \
           yes "Yes - enable the reputation feeds" \
           no  "No") || return $?
         on=$v
         if [ "$on" = yes ]; then s=1; else break; fi ;;
      1) rc=0; _wz_secret "abuse.ch API key — URLhaus + ThreatFox/Feodo (blank = install disabled, set later in ilexa):" \
           "No key - install it disabled, set it later in ilexa" "$k1" || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         k1=$_WZ_VAL; s=2 ;;
      2) rc=0; _wz_secret "AbuseIPDB API key (blank = install disabled, set later in ilexa):" \
           "No key - install it disabled, set it later in ilexa" "$k2" || rc=$?
         if [ "$rc" = 1 ]; then s=1; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         k2=$_WZ_VAL; break ;;
    esac
  done
  _wz_set ENABLE_FEEDS "$on" yes
  if [ "$on" = yes ]; then
    _wz_set ABUSECH_API_KEY "$k1" ""; _wz_set ABUSEIPDB_API_KEY "$k2" ""
  else
    _wz_unasked ABUSECH_API_KEY ABUSEIPDB_API_KEY
  fi
}

# rspamd's signing key cannot be imported on some platforms (EL10). Ask
# rather than dying 12 minutes later inside 40-rspamd: the wizard is the
# default path now, and RSPAMD_ALLOW_UNSIGNED was otherwise reachable only
# from an answers file, which a one-liner user does not have. Only in the step
# list when the probe in collect_interactive() failed.
wz_rspamd_unsigned() {
  local s=0 v rc
  while true; do
    case "$s" in
      0) tui_msg "rspamd package signature" \
"This system REFUSES rspamd's package signing key.

rspamd.com signs with a key whose self-signature uses SHA-1. This
platform's rpm rejects that outright, and offers no way to re-enable
it. rspamd is not in EPEL either, so this repository is the only
source -- there is no signed alternative to fall back to.

Continuing means installing rspamd WITHOUT verifying its signature.
It is still fetched over HTTPS from rspamd.com, but its authenticity
is not checked. Nothing else in the install is affected.

Declining stops here, with nothing changed." || return $?
         s=1 ;;
      1) _wz_default RSPAMD_ALLOW_UNSIGNED yes
         rc=0; v=$(tui_choice "" "Install rspamd without verifying its signature?" "$_WZ_DEF" \
           yes "Yes - install rspamd unverified" \
           no  "No - stop now and change nothing") || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         [ "$v" = yes ] || return 255     # declining stops the installer, as before
         break ;;
    esac
  done
  _wz_set RSPAMD_ALLOW_UNSIGNED yes yes
}

# Opt-in, and the operator sees what it means first. This copies the content
# of everyone's mail into one admin-readable mailbox.
#
# Explainer and choice are SEPARATE dialogs on purpose: as one ~34-line
# yesno this overflowed tui_yesno's fixed 10x74 box, whiptail rendered it
# as a scrolled region, and the initially focused control was the scroll
# area rather than a button -- reported from a live install as "the
# selector should be on OK by default". The explainer has its buttons in
# view, and the choice that follows is short enough to need no scrolling.
wz_archive() {
  local s=0 on days v rc
  _wz_default ENABLE_ARCHIVE yes;          on=$_WZ_DEF
  _wz_default ARCHIVE_RETENTION_DAYS 30;   days=$_WZ_DEF
  while true; do
    case "$s" in
      0) tui_msg "DEPLOYMENT TYPE: the central mail archive" \
"WITH ARCHIVE     every message is copied to one mailbox.
WITHOUT ARCHIVE  filtering only; nothing retained centrally.

There is NO quarantine: suspect mail is tagged and DELIVERED,
and POP3 clients delete mail from the server -- so the archive
is the only place a false positive can be recovered from. The
Archive tab, its search, the spam/ham training buttons and the
weekly digest all read from it.

Without it, filtering is unchanged; you lose recovery, search
and most of the training signal.

GDPR: it copies the CONTENT of everyone's mail into one mailbox
admins can read. That needs a lawful basis, a retention period
(asked next) and users told in advance." || return $?
         s=1 ;;
      1) rc=0; v=$(tui_choice "" "Enable the central mail archive?

The previous screen explains what this means, including the GDPR side." "$on" \
           yes "Yes - copy every message to the archive mailbox" \
           no  "No - filtering only, nothing retained") || rc=$?
         if [ "$rc" = 1 ]; then s=0; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         on=$v
         if [ "$on" = yes ]; then s=2; else break; fi ;;
      2) rc=0; v=$(tui_input "Keep archived mail for how many days?" "$days") || rc=$?
         if [ "$rc" = 1 ]; then s=1; continue; fi
         [ "$rc" = 0 ] || return "$rc"
         days=$v; break ;;
    esac
  done
  _wz_set ENABLE_ARCHIVE "$on" yes
  if [ "$on" = yes ]; then _wz_set ARCHIVE_RETENTION_DAYS "$days" 30; else _wz_unasked ARCHIVE_RETENTION_DAYS; fi
}

# Greylisting: a wizard QUESTION, not just an apply_defaults default. It is
# the one filtering layer with a user-visible cost -- an unknown sender's
# first message is delayed ~5 minutes -- so an operator serving people who
# expect instant password-reset and 2FA mail must be able to decline it here
# without editing an answers file they are not using. Yes is the preselected
# answer, matching apply_defaults' ENABLE_GREYLISTING:=yes.
wz_greylisting() {
  local v
  _wz_default ENABLE_GREYLISTING yes
  v=$(tui_choice "" "Enable greylisting (postgrey)?

Defers an UNKNOWN sender's first message by ~5 minutes. Real servers retry and get through; much throwaway spam never comes back.

The cost is a one-time delay on the FIRST mail from each new correspondent -- felt most on password resets and 2FA codes from senders you have not heard from before.

Yes suits most sites. Choose No if any delay is unacceptable. Switchable later only by re-running the installer." "$_WZ_DEF" \
    yes "Yes - greylist unknown senders" \
    no  "No - accept their first message at once") || return $?
  _wz_set ENABLE_GREYLISTING "$v" yes
}

# Default system language -- Roundcube, ilexa AND PostfixAdmin all follow it.
# English is preselected, so plain Enter accepts English. Changeable any time
# from the console (Admin -> language), which owns the state file afterwards;
# all three apps read that file at runtime, so changing it there moves them
# together.
wz_language() {
  local v
  _wz_default SYSTEM_LANG en
  v=$(tui_choice "Interface language" \
    "Default language for webmail (Roundcube), the ilexa console and PostfixAdmin. Changeable later (Admin -> language); users can still pick their own in Roundcube." \
    "$_WZ_DEF" \
    en "$(_wz_lang_label en)" \
    hu "$(_wz_lang_label hu)") || return $?
  [ -n "$v" ] || v=en
  _wz_set SYSTEM_LANG "$v" en
  ILEXA_LANG=$SYSTEM_LANG
}

# Password expiry: one global interval for every mailbox (PostfixAdmin's own
# per-domain override stays superadmin-only, unchanged, in its own UI).
# Radiolist default is 90 -- matches this installer's own recommended value
# elsewhere (see docs/GUIDE.md) and PostfixAdmin's own upstream
# documentation (DOCUMENTS/Password_Expiration.md) suggested example.
# "Never" maps to password_expiration=NO, PostfixAdmin's existing off
# switch -- not a new code path.
wz_pwexpiry() {
  local v o st args=()
  _wz_default PASSWORD_EXPIRY_DAYS 90
  for o in 30 60 90 never; do
    if [ "$o" = "$_WZ_DEF" ]; then st=on; else st=off; fi
    if [ "$o" = never ]; then args+=(never "Never expire passwords" "$st")
    else args+=("$o" "Expire passwords after $o days" "$st"); fi
  done
  v=$(tui_radiolist "Password expiry" "${args[@]}") || return $?
  _wz_set PASSWORD_EXPIRY_DAYS "$v" 90
}

wz_extras() {
  _wz_checklist "Optional extras" "${WZ_EXTRAS[@]}" || return $?
  # Not offered on apt (see wz_init), so nothing to opt into there.
  [ "${PKG_MGR:-dnf}" != apt ] || ENABLE_UNOFFICIAL_SIGS=no
  return 0
}

wz_hardening() {
  _wz_checklist "Hardening options (secure-by-default)" "${WZ_HARDENING[@]}" || return $?
  # Not offered off EL (see wz_init), so nothing to opt into there.
  [ "${PKG_MGR:-}" = dnf ] || HARDEN_SELINUX=no
  return 0
}

# What the review and the Change... menu display is what will be APPLIED, not
# the raw answer: the review runs before apply_defaults(), and a blank answer
# there means that function's default (a blank geoblock is "ru cn br kr", a
# blank mail store "/data/mail"). So both screens are rendered from a copy of
# the answers that apply_defaults() itself has filled in -- one source, which
# cannot drift from what is installed the way a second list of fallbacks would.
#
# Only ever inside a subshell (wz_value and review_text are subshell
# functions): apply_defaults assigns the real variables, and generates a
# password when none was given -- hence _WZ_PW_GIVEN is noted first.
_wz_effective() {
  _WZ_PW_GIVEN=${ADMIN_PASSWORD:+yes}
  MD_LOG=/dev/null
  apply_defaults >/dev/null 2>&1
}

# One step's answer as it will be applied, briefly -- for the Change... menu.
wz_value() ( # step function
  _wz_effective
  _wz_show "$1"
)
_wz_show() { # step function -- the display itself; needs _wz_effective first
  local row tag var label def n=0 on=0 tbl=()
  case "$1" in
    wz_fqdn)           printf '%s' "${MAIL_FQDN:-}" ;;
    wz_domain)         printf '%s' "${PRIMARY_DOMAIN:-}" ;;
    wz_extra_domains)  printf '%s' "${EXTRA_DOMAINS:-(none)}" ;;
    wz_admin_email)    printf '%s' "${ADMIN_EMAIL:-}" ;;
    wz_alert_email)    printf '%s' "${ALERT_EMAIL:-(none)}" ;;
    wz_admin_password) if [ -n "${_WZ_PW_GIVEN:-}" ]; then printf '(entered)'; else printf '(generate one)'; fi ;;
    wz_mail_store)     printf '%s' "${MAIL_STORE:-}" ;;
    wz_timezone)       printf '%s' "${TIMEZONE:-}" ;;
    wz_tls)            _wz_tls_label "${TLS_MODE:-}" ;;
    wz_spam_reject)    printf '%s' "${SPAM_REJECT:-}" ;;
    wz_geoblock)       printf '%s' "${GEOBLOCK_COUNTRIES:-(none)}" ;;
    wz_ssh_port)       printf '%s' "${SSH_PORT:-}" ;;
    wz_otx)            printf '%s' "${ENABLE_OTX:-}" ;;
    wz_dqs)            if [ -n "${SPAMHAUS_DQS_KEY:-}" ]; then printf 'key entered'; else printf 'no key'; fi ;;
    wz_feeds)          printf '%s' "${ENABLE_FEEDS:-}" ;;
    wz_rspamd_unsigned) printf 'install unverified' ;;
    wz_archive)        if [ "${ENABLE_ARCHIVE:-}" = yes ]; then printf 'yes, %s days' "${ARCHIVE_RETENTION_DAYS:-}"; else printf 'no'; fi ;;
    wz_greylisting)    printf '%s' "${ENABLE_GREYLISTING:-}" ;;
    wz_language)       _wz_lang_label "${SYSTEM_LANG:-}" ;;
    wz_pwexpiry)       if [ "${PASSWORD_EXPIRY_DAYS:-}" = never ]; then printf 'never'; else printf '%s days' "${PASSWORD_EXPIRY_DAYS:-}"; fi ;;
    wz_extras|wz_hardening)
      if [ "$1" = wz_extras ]; then tbl=("${WZ_EXTRAS[@]}"); else tbl=("${WZ_HARDENING[@]}"); fi
      for row in "${tbl[@]}"; do
        IFS='|' read -r tag var label def <<<"$row"
        n=$((n + 1)); [ "${!var:-no}" = yes ] && on=$((on + 1))
      done
      printf '%s of %s on' "$on" "$n" ;;
  esac
  return 0
}

# The review screen's text. Wizard-only: summary_text below stays the log's
# format, unchanged, so an unattended run logs exactly what it always did.
# Every line fits a 78-column box (72 inside it); a long value wraps under its
# own column instead of being cut off.
_rv() { # label value   (an empty label continues the line above)
  local line first=1
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then printf '%-18s%s\n' "${1:+$1:}" "$line"; first=0
    else printf '%-18s%s\n' "" "$line"; fi
  done < <(printf '%s\n' "$2" | fold -s -w 54)
}
_rv_rows() { # label row... -- a checklist, one [x]/[ ] line per offered option
  local title="$1" row tag var label def mark
  shift
  for row in "$@"; do
    IFS='|' read -r tag var label def <<<"$row"
    if [ "${!var:-no}" = yes ]; then mark='[x]'; else mark='[ ]'; fi
    _rv "$title" "$mark $label"; title=""
  done
}
review_text() (
  local otx feeds
  _wz_effective
  _rv "Mail server FQDN" "${MAIL_FQDN:-}"
  _rv "Primary domain" "${PRIMARY_DOMAIN:-}"
  _rv "Extra domains" "${EXTRA_DOMAINS:-(none)}"
  _rv "Admin email" "${ADMIN_EMAIL:-}"
  _rv "Alert email" "${ALERT_EMAIL:-(none — scheduled-job alerts disabled)}"
  _rv "Admin password" "$(_wz_show wz_admin_password)"
  _rv "Mail store" "${MAIL_STORE:-}"
  _rv "Timezone" "${TIMEZONE:-}"
  _rv "TLS certificate" "$(_wz_tls_label "${TLS_MODE:-}")"
  if [ "${TLS_MODE:-}" = custom ]; then
    _rv "  certificate" "${TLS_CUSTOM_CERT:-}"
    _rv "  private key" "${TLS_CUSTOM_KEY:-}"
  fi
  _rv "Spam tag/reject" "${SPAM_ADD_HEADER:-} / ${SPAM_REJECT:-}"
  _rv "Geoblock" "${GEOBLOCK_COUNTRIES:-(none)}"
  _rv "SSH port" "${SSH_PORT:-}"
  if [ "${ENABLE_OTX:-}" = yes ]; then
    if [ -n "${OTX_API_KEY:-}" ]; then otx="yes (API key entered)"; else otx="yes (no API key yet - configure later)"; fi
  else otx=no; fi
  _rv "OTX suite" "$otx"
  _rv "Spamhaus DQS" "$([ -n "${SPAMHAUS_DQS_KEY:-}" ] && echo "yes (key entered)" || echo "no (rspamd's default public zones)")"
  if [ "${ENABLE_FEEDS:-}" = yes ]; then
    feeds="yes"
    [ -n "${ABUSECH_API_KEY:-}" ] && feeds="$feeds, abuse.ch key entered"
    [ -n "${ABUSEIPDB_API_KEY:-}" ] && feeds="$feeds, AbuseIPDB key entered"
  else feeds=no; fi
  _rv "Reputation feeds" "$feeds"
  if [ -n "${ABUSIX_API_KEY:-}" ]; then
    _rv "Abusix" "yes (remember to allowlist this server IP in the Abusix portal)"
  fi
  _rv "rspamd signature" "$([ "${RSPAMD_ALLOW_UNSIGNED:-no}" = yes ] && echo 'NOT VERIFIED (RSPAMD_ALLOW_UNSIGNED=yes)' || echo verified)"
  _rv "Mail archive" "$(_wz_show wz_archive)"
  _rv "Greylisting" "${ENABLE_GREYLISTING:-}"
  _rv "System language" "$(_wz_lang_label "${SYSTEM_LANG:-}") (Roundcube + ilexa + PostfixAdmin)"
  _rv "Password expiry" "$([ "${PASSWORD_EXPIRY_DAYS:-}" = never ] && echo "never (disabled)" || echo "${PASSWORD_EXPIRY_DAYS:-} days")"
  _rv "ilexa console" "${ENABLE_ILEXA:-} at ${ILEXA_URL_PREFIX:-}"
  _rv_rows "Optional extras" "${WZ_EXTRAS[@]}"
  _rv_rows "Hardening" "${WZ_HARDENING[@]}"
  if [ -n "${BACKUP_TARGET:-}" ]; then _rv "Backups target" "$BACKUP_TARGET"; fi
  if [ "${DRY_RUN:-0}" = 1 ]; then _rv "DRY RUN" "yes - modules only log what they would do"; fi
  return 0
)

apply_defaults() {
  : "${MAIL_HOSTNAME:=${MAIL_FQDN%%.*}}"
  : "${EXTRA_DOMAINS:=}"
  : "${MAIL_STORE:=/data/mail}"
  : "${TLS_MODE:=letsencrypt}"
  : "${CERTBOT_METHOD:=webroot}"
  # ---- scanner (rspamd) ----------------------------------------------------
  : "${SCANNER:=rspamd}"            # seam: only rspamd is implemented today
  : "${SPAM_ADD_HEADER:=4}"         # tag threshold
  : "${SPAM_REWRITE_SUBJECT:=6}"    # subject-tag threshold
  : "${SPAM_REJECT:=15}"            # safety-net reject; also arms the virus reject
  # NOT `: "${SPAM_SUBJECT_TAG:={Spam?}}"` -- the parameter expansion ends at
  # the FIRST closing brace, so that assigns "{Spam?" and leaves the final "}"
  # as literal text outside the expansion. Answers-file installs pass a quoted
  # value and were fine; the WIZARD path silently tagged every spam subject
  # "{Spam? " with no closing brace.
  [ -n "${SPAM_SUBJECT_TAG:-}" ] || SPAM_SUBJECT_TAG='{Spam?}'
  : "${RSPAMD_CTRL:=127.0.0.1:11334}"
  : "${RSPAMD_MILTER:=inet:127.0.0.1:11332}"
  : "${CLAMD_SOCKET:=/var/run/clamd.scan/clamd.sock}"
  : "${MTA_GROUP:=mtagroup}"
  # ---- ilexa ----------------------------------------------------------------
  : "${ENABLE_ILEXA:=yes}"
  : "${ENABLE_HU_CLASSIFY:=no}"     # experimental Hungarian classifier module, opt-in
  : "${HU_CLASSIFY_REPORT_EMAIL:=}"  # blank = console/alerts.conf decides
  # ---- reputation feeds ------------------------------------------------------
  # Every updater is installed regardless; a blank key just leaves that source
  # disabled, changeable later from ilexa -> Admin.
  : "${ENABLE_FEEDS:=no}"
  # Opt-in escape hatch for platforms where rspamd's upstream signing key
  # cannot be imported (EL10 / rpm-sequoia). Default no = fail loudly.
  : "${RSPAMD_ALLOW_UNSIGNED:=no}"
  : "${ENABLE_BREACH_CHECK:=no}"
  : "${ENABLE_FTS_OPTIMIZE:=yes}"
  : "${ENABLE_ARCHIVE:=no}"
  : "${ARCHIVE_RETENTION_DAYS:=30}"
  : "${ILEXA_URL_PREFIX:=/ilexa/}"
  # Default system language: one answer driving the interface language of
  # ALL THREE web apps (Roundcube, ilexa, PostfixAdmin). ILEXA_LANG is the
  # older name for the same thing and is still honoured, in both
  # directions, so answers files written before this existed keep working.
  : "${SYSTEM_LANG:=${ILEXA_LANG:-en}}"
  : "${ILEXA_LANG:=$SYSTEM_LANG}"
  # 30|60|90|never -- PostfixAdmin's own per-domain days column, seeded here
  # for every domain this installer creates (seed_postfixadmin()), not a
  # config.inc.php value: PostfixAdmin has no such global, only a per-domain
  # DB column (domain.password_expiry) it expects an operator to set through
  # its own UI. That column's schema default is 0 -- i.e. instant expiry --
  # so leaving it unseeded here would reproduce, on every fresh install, the
  # exact all-mailboxes-already-expired state found and fixed by hand on the
  # reference host 2026-08-23.
  : "${PASSWORD_EXPIRY_DAYS:=90}"
  : "${ILEXA_ADMIN_USER:=admin}"
  : "${ILEXA_ADMIN_PASSWORD:=}"        # blank = generated and recorded
  : "${QUARANTINE_FOLDERS:=Junk Quarantine Spam}"
  # Only when archiving is actually on. Defaulting it unconditionally left
  # config.php naming archive@<domain> on a host where module 57 never created
  # that mailbox, so 99-verify reported "archive account resolves - FAIL" on a
  # perfectly good install, pointing a red line at a feature the operator had
  # deliberately turned off. Empty is also the honest value: qa-verify-console.sh
  # already skips the check when no archive account is configured, and an empty
  # ARCHIVE_USER makes qa-doveadm.sh's INBOX guard fail CLOSED (no user can
  # match ""), which is exactly what "archiving is off" should mean.
  if [ "${ENABLE_ARCHIVE:-no}" = yes ]; then
    : "${ARCHIVE_USER:=archive@$PRIMARY_DOMAIN}"
  else
    : "${ARCHIVE_USER:=}"
  fi
  # Falls back to the host's current zone, not a blind UTC -- an unattended run
  # that says nothing about time should not silently move the clock.
  : "${TIMEZONE:=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
  : "${SITE_TITLE:=ilexa - Mail Security Operations Console}"
  : "${PHP_FPM_SOCK:=/run/php-fpm/www.sock}"
  : "${MYSQL_SOCK:=/var/lib/mysql/mysql.sock}"
  : "${WEB_USER:=apache}"
  : "${WEB_GROUP:=apache}"
  : "${ABUSECH_API_KEY:=}"          # abuse.ch: URLhaus + ThreatFox/Feodo C2
  : "${ABUSEIPDB_API_KEY:=}"
  : "${ILEXA_LIST_DIR:=/var/lib/quarantine-admin}"
  : "${GEOBLOCK_COUNTRIES:=ru cn br kr}"
  : "${SSH_PORT:=22}"; : "${WEBMIN_PORT:=10000}"
  : "${ENABLE_OTX:=yes}"; : "${OTX_API_KEY:=}"; : "${OTX_TRUSTED_CIDRS:=}"
  : "${SPAMHAUS_DQS_KEY:=}"
  : "${ABUSIX_API_KEY:=}"
  : "${ENABLE_LAST_LOGIN:=yes}"; : "${ENABLE_FTS_XAPIAN:=yes}"; : "${ENABLE_UNATTENDED:=yes}"
  : "${ENABLE_UNOFFICIAL_SIGS:=yes}"
  : "${ENABLE_MX_CHECK:=yes}"; : "${ENABLE_KNOWN_SENDERS:=yes}"
  : "${ENABLE_MTA_STS:=yes}"; : "${MTA_STS_MODE:=enforce}"; : "${TLSRPT_RUA:=$ADMIN_EMAIL}"
  # `=`, NOT `:=` -- backfill only when the key is UNSET.
  #
  # The purpose is an answers file written before ALERT_EMAIL existed. `:=`
  # also substitutes on an EMPTY value, which made the interactive prompt's
  # own "blank = none" impossible: an operator who deliberately cleared the
  # field silently got ADMIN_EMAIL, and every cron failure went to a mailbox
  # they had declined. Two pieces of unreachable code proved the intent -- the
  # summary's "(none — scheduled-job alerts disabled)" and 55-ilexa's
  # "ALERT_EMAIL empty" warning, neither of which could ever run.
  : "${ALERT_EMAIL=$ADMIN_EMAIL}"
  : "${ENABLE_IPV6:=no}"
  if [ "$ENABLE_IPV6" = yes ]; then INET_PROTOCOLS=all; MYNETWORKS="127.0.0.0/8, [::1]/128"
  else INET_PROTOCOLS=ipv4; MYNETWORKS="127.0.0.0/8"; fi
  : "${ENABLE_SIEVE:=yes}"
  : "${ENABLE_REPORT_ADDRESSES:=yes}"
  : "${ENABLE_HU_BRAND_GUARD:=yes}"
  # Quotas: enforced at SMTP time (delivery is virtual_transport=virtual, which
  # bypasses Dovecot) via a Dovecot quota-status policy Postfix queries. The
  # userdb returns a per-mailbox quota_rule from the PostfixAdmin quota column.
  : "${ENABLE_QUOTA:=yes}"
  if [ "$ENABLE_QUOTA" = yes ]; then
    # quota<=0 means "unlimited" in PostfixAdmin's schema, and Dovecot spells
    # that '*:bytes=0' -- NOT an empty string. Returning '' made the quota
    # plugin fail to initialise ("Failed to initialize quota: ... Invalid
    # rule"), and because that aborts mail access entirely, EVERY unlimited
    # mailbox became unreadable: doveadm could not even list INBOX, so the
    # console could not open a message. The installer's own archive mailbox is
    # created with quota 0, so it was always in this state.
    QUOTA_FIELD=", CASE WHEN quota<=0 THEN '*:bytes=0' ELSE CONCAT('*:bytes=', quota) END AS quota_rule"
    QUOTA_POLICY=", check_policy_service unix:private/quota-status"
  else QUOTA_FIELD=""; QUOTA_POLICY=""; fi
    # Greylisting (postgrey). default_action=DUNNO is deliberate, and is the
    # OPPOSITE of how the API-budget ledger fails: greylisting is an
    # optimisation, not a security boundary, so if postgrey is down the right
    # answer is "skip greylisting", never "defer every message". Without it a
    # dead policy daemon takes the whole MTA with it -- Postfix defers on an
    # unreachable policy service by default. Inline attribute syntax needs
    # Postfix >= 3.0.
    : "${ENABLE_GREYLISTING:=yes}"
    if [ "$ENABLE_GREYLISTING" = yes ]; then
      GREYLIST_POLICY=", check_policy_service { inet:127.0.0.1:10023, default_action=DUNNO }"
    else GREYLIST_POLICY=""; fi
    # Report-address auth gate, rendered into main.cf rather than prepended
    # afterwards -- see the note in templates/postfix/main.cf.tmpl for the
    # silent-regression this prevents. Must come FIRST in the recipient
    # restrictions, ahead of the permit_* rules that would otherwise let an
    # unauthenticated client straight through.
    : "${ENABLE_REPORT_ADDRESSES:=yes}"
    if [ "$ENABLE_REPORT_ADDRESSES" = yes ]; then
      # SINGLE LINE each -- render() is sed-based; a newline here deletes the
      # whole parameter from main.cf. Learned the hard way on the test host.
      REPORT_AUTH_CHECK=" check_recipient_access hash:/etc/postfix/report_auth,"
      RESTRICTION_CLASSES=" report_auth_only"
      REPORT_AUTH_ONLY=" permit_mynetworks, permit_sasl_authenticated, check_recipient_access hash:/etc/postfix/report_deny"
    else REPORT_AUTH_CHECK=""; RESTRICTION_CLASSES=""; REPORT_AUTH_ONLY=""; fi
  : "${ENABLE_AUTOCONFIG:=yes}"
  : "${HARDEN_SSH_KEYONLY:=yes}"; : "${ADMIN_SSH_PUBKEY:=}"
  : "${HARDEN_SELINUX:=no}"; : "${HARDEN_WEBMIN:=yes}"; : "${WEBMIN_ALLOW_IPS:=127.0.0.1}"
  : "${HARDEN_KERNEL_AUTOREBOOT:=yes}"; : "${HARDEN_SMTP_TUNING:=yes}"
  : "${MESSAGE_SIZE_LIMIT:=52428800}"; : "${BACKUP_TARGET:=}"; : "${BACKUP_PASSPHRASE:=}"
  : "${ENABLE_METRICS:=no}"; : "${METRICS_SCRAPE_CIDR:=}"
  # SECURITY: the wizard prompt says "blank = auto-generate", and the answers
  # file ships ADMIN_PASSWORD empty -- but nothing ever generated it. The empty
  # string was passed straight to password_hash() in 50-web, producing a
  # PostfixAdmin SUPERADMIN that logs in with a blank password. Confirmed on a
  # real install: password_verify("", $stored) returned true. Honour the promise
  # instead; the value is recorded to the 600 credentials file either way.
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD="$(gen_pw 24)"
    log_info "no ADMIN_PASSWORD given — generated one (see $MD_CRED_FILE)"
  fi
  # Blank => 50-web generates one for postfixadmin@<MAIL_FQDN> on first install.
  : "${PFA_ADMIN_PASSWORD:=}"
  # derived
  # smtpd_delay_reject is NOT a tuning knob and is no longer tied to
  # HARDEN_SMTP_TUNING. With "no", client/helo/sender restrictions are
  # evaluated at their own SMTP stage, which makes permit_sasl_authenticated
  # in smtpd_client_restrictions a silent no-op -- no AUTH has happened at
  # CONNECT time -- so the chain does not behave the way the file reads. "yes"
  # is Postfix's own default and the only correct value here; the reference
  # host was found shipping "no" during the 2026-08-17 postfix audit.
  SMTPD_DELAY_REJECT=yes
  # Sender-identity guard. Defaults to "warn" deliberately: enforcing on a host
  # with real delegation patterns (one person sending for several role
  # addresses, MFPs using a shared From) bounces that mail on day one, and the
  # operator has no list of what would break until it already has. warn logs
  # every violation and refuses nothing. See the long comment in
  # templates/postfix/main.cf.tmpl for how to review and then switch over.
  case "${SENDER_LOGIN_POLICY:-warn}" in
    enforce) SENDER_LOGIN_GUARD="reject_authenticated_sender_login_mismatch, " ;;
    warn)    SENDER_LOGIN_GUARD="warn_if_reject reject_authenticated_sender_login_mismatch, " ;;
    off)     SENDER_LOGIN_GUARD="" ;;
    *) die "SENDER_LOGIN_POLICY must be warn, enforce or off (got: ${SENDER_LOGIN_POLICY})" ;;
  esac
  [ "$ENABLE_OTX" = yes ] && OTX_DNSBL="otx.rbl*2" || OTX_DNSBL=""
  # NOTE: dnsbl.sorbs.net was retired mid-2024 (dead zone) — intentionally omitted.
  #
  # bl.hrbl.hu and z.mailspike.net are keyless public zones that the reference
  # host has run since 2026-08-12/13, and both were verified answering their
  # 2.0.0.127 test point when this default was written. They were added to
  # production and never to the installer, so every installed host ran with a
  # weaker postscreen than the host it was modelled on -- the same gap that
  # left greylisting on, the milters unreachable and clamav mailing root hourly.
  #
  # WEIGHTS MATTER HERE: postscreen_dnsbl_threshold is 3, so z.mailspike.net*3
  # reaches it ALONE -- a single Mailspike listing blocks the client before any
  # content is seen. That is exactly how the reference host runs it, which is
  # the argument for keeping it; lower it to *2 if you would rather require
  # corroboration from a second list.
  POSTSCREEN_DNSBL_SITES="zen.spamhaus.org*3 b.barracudacentral.org*2 bl.spamcop.net*2 bl.hrbl.hu*2 z.mailspike.net*3${OTX_DNSBL:+ $OTX_DNSBL}"
  # TLS cert/key live at ONE stable, mode-independent path that every service
  # config points at, regardless of how the cert was obtained.
  #
  # 75-tls-dns.sh makes these SYMLINKS into /etc/letsencrypt/live/<fqdn>/ when
  # certbot issues, and real self-signed files otherwise. Two reasons not to
  # point services straight at the letsencrypt tree the way this used to:
  #  1. A failed issuance wrote the self-signed fallback INTO
  #     /etc/letsencrypt/live/<fqdn>/, which is certbot's own lineage
  #     directory. certbot then refuses that name on the next attempt and
  #     issues <fqdn>-0001 instead, so every service keeps serving the stale
  #     self-signed file forever -- a silent, permanent failure.
  #  2. Renewal rewrites the lineage symlinks; because ours point at the
  #     lineage rather than at the archive files, a renewed cert is picked up
  #     with nothing more than a service reload. No config ever changes.
  TLS_DIR=/etc/ssl/ilexa
  TLS_CERT="$TLS_DIR/${MAIL_FQDN}.crt"
  TLS_KEY="$TLS_DIR/${MAIL_FQDN}.key"
  TLS_CAFILE="$TLS_CERT"
}

validate() {
  local k missing=()
  for k in "${REQUIRED_KEYS[@]}"; do [ -n "${!k:-}" ] || missing+=("$k"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required answers: ${missing[*]}"
  case "$TLS_MODE" in
    letsencrypt|selfsigned) : ;;
    custom)
      # Fail here, before a two-minute install, rather than in 75-tls-dns.
      [ -n "${TLS_CUSTOM_CERT:-}" ] && [ -n "${TLS_CUSTOM_KEY:-}" ] \
        || die "TLS_MODE=custom requires TLS_CUSTOM_CERT and TLS_CUSTOM_KEY (paths to your certificate and its private key)"
      [ -s "${TLS_CUSTOM_CERT}" ] || die "TLS_CUSTOM_CERT not found or empty: ${TLS_CUSTOM_CERT}"
      [ -s "${TLS_CUSTOM_KEY}" ]  || die "TLS_CUSTOM_KEY not found or empty: ${TLS_CUSTOM_KEY}"
      ;;
    *) die "TLS_MODE must be letsencrypt|custom|selfsigned" ;;
  esac
  [[ "$MAIL_FQDN" == *.* ]] || die "MAIL_FQDN must be a FQDN"
  if [ "$HARDEN_SSH_KEYONLY" = yes ] && [ -z "$ADMIN_SSH_PUBKEY" ]; then
    log_warn "HARDEN_SSH_KEYONLY=yes but ADMIN_SSH_PUBKEY empty — SSH hardening will be skipped to avoid lockout"
  fi
}

export_config() {
  # export answer vars for module subprocesses
  export RSPAMD_ALLOW_UNSIGNED
  export MAIL_FQDN MAIL_HOSTNAME PRIMARY_DOMAIN EXTRA_DOMAINS ADMIN_EMAIL ALERT_EMAIL ADMIN_PASSWORD PFA_ADMIN_PASSWORD \
    MAIL_STORE TLS_MODE CERTBOT_METHOD TLS_CUSTOM_CERT TLS_CUSTOM_KEY GEOBLOCK_COUNTRIES \
    ENABLE_OTX OTX_API_KEY OTX_TRUSTED_CIDRS SPAMHAUS_DQS_KEY ABUSIX_API_KEY ENABLE_LAST_LOGIN ENABLE_FTS_XAPIAN ENABLE_UNATTENDED \
    ENABLE_MX_CHECK ENABLE_KNOWN_SENDERS ENABLE_HU_BRAND_GUARD \
    ENABLE_MTA_STS MTA_STS_MODE TLSRPT_RUA ENABLE_IPV6 INET_PROTOCOLS MYNETWORKS ENABLE_SIEVE \
    ENABLE_QUOTA QUOTA_FIELD QUOTA_POLICY ENABLE_GREYLISTING GREYLIST_POLICY ENABLE_SRS REPORT_AUTH_CHECK RESTRICTION_CLASSES REPORT_AUTH_ONLY ENABLE_METRICS METRICS_SCRAPE_CIDR ENABLE_AUTOCONFIG ENABLE_FTS_OPTIMIZE \
    HARDEN_SSH_KEYONLY ADMIN_SSH_PUBKEY HARDEN_SELINUX HARDEN_WEBMIN WEBMIN_ALLOW_IPS \
    HARDEN_KERNEL_AUTOREBOOT HARDEN_SMTP_TUNING MESSAGE_SIZE_LIMIT BACKUP_TARGET BACKUP_PASSPHRASE \
    SMTPD_DELAY_REJECT SENDER_LOGIN_GUARD POSTSCREEN_DNSBL_SITES TLS_DIR TLS_CERT TLS_KEY TLS_CAFILE SSH_PORT WEBMIN_PORT \
    SCANNER SPAM_ADD_HEADER SPAM_REWRITE_SUBJECT SPAM_REJECT SPAM_SUBJECT_TAG \
    RSPAMD_CTRL RSPAMD_MILTER CLAMD_SOCKET MTA_GROUP \
    ENABLE_ILEXA ILEXA_LIST_DIR ENABLE_HU_CLASSIFY HU_CLASSIFY_REPORT_EMAIL ENABLE_UNOFFICIAL_SIGS \
    ENABLE_FEEDS ABUSECH_API_KEY ABUSEIPDB_API_KEY ENABLE_OTX_URI \
    ENABLE_BREACH_CHECK ILEXA_URL_PREFIX ILEXA_ADMIN_USER ILEXA_ADMIN_PASSWORD ILEXA_LANG SYSTEM_LANG \
    PASSWORD_EXPIRY_DAYS \
    QUARANTINE_FOLDERS ARCHIVE_USER TIMEZONE SITE_TITLE PHP_FPM_SOCK MYSQL_SOCK \
    WEB_USER WEB_GROUP ENABLE_ARCHIVE ARCHIVE_RETENTION_DAYS ENABLE_SIEM_EXPORT ENABLE_REPORT_ADDRESSES
}

# A WIZARD RUN LEAVES NO RECORD OF ITS ANSWERS, which makes the host
# un-maintainable: `deploy.sh --only <module>` needs an answers file, so on a
# wizard-built machine there is no supported way to re-run a single module --
# including the repair paths modules carry for exactly that purpose. Hit while
# repairing such a host: the answers had to be reconstructed by hand from the
# live configuration.
#
# Written 0600 root:root, and SECRETS ARE OMITTED -- passwords and API keys are
# deliberately not persisted, so the file is a starting point for a re-run
# rather than a credential store. Anything omitted is re-prompted or re-derived.
save_answers() {
  [ "$DRY_RUN" = 1 ] && return 0
  local out=/var/lib/ilexa-install/answers.effective k v
  mkdir -p /var/lib/ilexa-install
  { echo "# Effective answers from the run on $(date -Is)."
    echo "# Regenerated every run. Secrets are NOT stored: add them back by hand"
    echo "# if a re-run needs them. Usage: deploy.sh --answers $out --only <module>"
    for k in MAIL_FQDN PRIMARY_DOMAIN EXTRA_DOMAINS ADMIN_EMAIL ALERT_EMAIL \
             MAIL_STORE TLS_MODE CERTBOT_METHOD TIMEZONE SYSTEM_LANG \
             ENABLE_ARCHIVE ARCHIVE_RETENTION_DAYS ENABLE_GREYLISTING ENABLE_SRS \
             ENABLE_REPORT_ADDRESSES ENABLE_QUOTA ENABLE_OTX ENABLE_FEEDS \
             ENABLE_LAST_LOGIN ENABLE_FTS_XAPIAN ENABLE_UNATTENDED \
             ENABLE_MX_CHECK ENABLE_KNOWN_SENDERS ENABLE_IPV6 ENABLE_SIEVE \
             PASSWORD_EXPIRY_DAYS SPAM_SUBJECT_TAG GEOBLOCK_COUNTRIES \
             HARDEN_SSH_KEYONLY HARDEN_WEBMIN HARDEN_KERNEL_AUTOREBOOT \
             HARDEN_SMTP_TUNING HARDEN_SELINUX; do
      v="${!k-}"
      [ -n "${!k+x}" ] || continue
      # Single-quoted, with embedded quotes escaped: this file is SOURCED, so an
      # unquoted multi-word value both truncates and executes. GEOBLOCK_COUNTRIES="ru
      # cn br kr" set the variable to "ru" and ran "cn br kr" as a command --
      # geoblock silently dropped to one country on every re-run from this file.
      printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}"
    done
  } > "$out"
  chmod 0600 "$out"; chown root:root "$out"
  log_info "answers recorded in $out (no secrets) — usable with --answers for a later --only run"
}

# Can this platform import rspamd's repo signing key at all?
#
# Probed into a THROWAWAY rpm database, so nothing is imported into the real
# one before the review screen has been approved. Returns 0 when the key is
# usable (or when this is not an rpm platform, or the probe cannot run -- an
# inconclusive probe must not invent a scary question).
#
# EL10 is where this bites: rspamd signs with a SHA-1 self-signature that
# rpm-sequoia rejects, and there is no SHA1.pmod to re-enable it.
rspamd_key_importable() {
  command -v rpm >/dev/null 2>&1 || return 0
  local d rc=0
  d=$(mktemp -d 2>/dev/null) || return 0
  if curl -sSfL --max-time 20 https://rspamd.com/rpm-stable/gpg.key -o "$d/key" 2>/dev/null; then
    rpm --dbpath "$d/db" --initdb >/dev/null 2>&1 || { rm -rf "$d"; return 0; }
    rpm --dbpath "$d/db" --import "$d/key" >/dev/null 2>&1 || rc=1
  fi
  rm -rf "$d"
  return $rc
}

summary_text() {
  cat <<EOF
FQDN:            $MAIL_FQDN
Primary domain:  $PRIMARY_DOMAIN
Extra domains:   ${EXTRA_DOMAINS:-(none)}
Admin email:     $ADMIN_EMAIL
Alert email:     ${ALERT_EMAIL:-(none — scheduled-job alerts disabled)}
Mail store:      $MAIL_STORE
TLS mode:        $TLS_MODE
Spam tag/reject:  ${SPAM_ADD_HEADER:-4} / ${SPAM_REJECT:-15}
Mail archive:    ${ENABLE_ARCHIVE:-no}${ENABLE_ARCHIVE:+ (${ARCHIVE_RETENTION_DAYS:-30} days)}
Feeds:           ${ENABLE_FEEDS:-no}
ilexa console:   ${ENABLE_ILEXA:-yes} at ${ILEXA_URL_PREFIX:-/ilexa/}
System language: ${SYSTEM_LANG:-en} (Roundcube + ilexa + PostfixAdmin)
Password expiry: $([ "${PASSWORD_EXPIRY_DAYS:-90}" = never ] && echo "never (disabled)" || echo "${PASSWORD_EXPIRY_DAYS:-90} days")
Geoblock:        $GEOBLOCK_COUNTRIES
OTX suite:       $ENABLE_OTX
Spamhaus DQS:    $([ -n "${SPAMHAUS_DQS_KEY:-}" ] && echo yes || echo no)
Abusix:          $([ -n "${ABUSIX_API_KEY:-}" ] && echo "yes (remember to allowlist this server IP in the Abusix portal)" || echo no)
rspamd signature: $([ "${RSPAMD_ALLOW_UNSIGNED:-no}" = yes ] && echo 'NOT VERIFIED (RSPAMD_ALLOW_UNSIGNED=yes)' || echo verified)
Extras:          last_login=$ENABLE_LAST_LOGIN fts_xapian=$ENABLE_FTS_XAPIAN unattended=$ENABLE_UNATTENDED mx_check=$ENABLE_MX_CHECK known_senders=$ENABLE_KNOWN_SENDERS
Hardening:       ssh=$HARDEN_SSH_KEYONLY webmin=$HARDEN_WEBMIN reboot=$HARDEN_KERNEL_AUTOREBOOT smtp=$HARDEN_SMTP_TUNING selinux=$HARDEN_SELINUX
Backups target:  ${BACKUP_TARGET:-(none / parameterized)}
DRY_RUN:         ${DRY_RUN:-0}
EOF
}

run_modules() {
  local m base run
  # Which modules will actually run, decided up front, so the gauge's total
  # matches --only exactly rather than counting modules that get skipped.
  local -a to_run=()
  for m in "$MD_ROOT"/modules/[0-9]*.sh; do
    [ -e "$m" ] || die "no modules found in $MD_ROOT/modules"
    base=$(basename "$m" .sh)
    if [ ${#ONLY[@]} -gt 0 ]; then
      run=0; local o; for o in "${ONLY[@]}"; do [[ "$base" == "$o"* ]] && run=1; done
      [ "$run" = 1 ] || continue
    fi
    to_run+=("$m")
  done
  local total=${#to_run[@]} idx=0 pct
  progress_start "Installing"
  for m in "${to_run[@]}"; do
    base=$(basename "$m" .sh)
    idx=$((idx + 1))
    pct=$(( (idx - 1) * 100 / total ))
    progress_update "$pct" "$(progress_label_for "$base")"
    log_info "=== module $base ==="
    bash "$m"; rc=$?
    if [ "$rc" = "$MD_ABORT_RC" ]; then
      # A module's own interactive prompt (e.g. 75-tls-dns's DNS retry
      # dialog) offered Exit and the operator took it -- module_abort()
      # (lib/common.sh) signals that with this exit code specifically so it
      # is not mistaken for the module having failed.
      progress_stop
      log_info "install stopped at $base by operator request"
      exit 0
    elif [ "$rc" -ne 0 ]; then
      # Every log_* call is silenced on screen while the gauge owns it (see
      # _log in lib/common.sh) -- including a log_error from INSIDE the
      # module's own subprocess, which inherits MD_PROGRESS_ACTIVE. Without
      # this, the actual reason a module died would reach only $MD_LOG, and
      # the operator would see nothing but "module X failed" on a now-blank
      # screen. Tear the gauge down FIRST so log_warn below is visible again,
      # then surface what the module itself reported before dying.
      progress_stop
      log_warn "--- last log lines before the failure ---"
      tail -n 25 "$MD_LOG" >&2 2>/dev/null
      die "module $base failed"
    fi
  done
  progress_update 100 "Done"
  progress_stop
}

main() {
  parse_args "$@"
  # Repo-wide bash -n + shellcheck gate, before any host-touching work (OS
  # detection, preflight, modules) -- a broken module must never get a chance
  # to execute partway through a real deploy. After parse_args so --help
  # stays instant. See tools/lint-all.sh's own header for what this checks
  # and why nothing enforced it before.
  "$MD_ROOT/tools/lint-all.sh" --quiet || die "lint-all.sh failed -- fix the reported errors before deploying (run tools/lint-all.sh directly for full output)"

  # Detect the OS as early as possible, before any UI is shown, purely so
  # the welcome banner and whiptail backtitle can display the REAL detected
  # OS instead of a hardcoded one -- this installer now supports several
  # (previously both were hardcoded to say "AlmaLinux/Rocky 9"/"EL9" even
  # when running on Ubuntu). Redundant with the require_supported_os call
  # further down, by the same design already documented there: this early
  # call is display-only and doesn't replace the later one, which still has
  # to run after apply_defaults/load_answers so the OS profile keeps
  # winning over any answers-file value.
  os_detect
  case "$OS_ID" in
    almalinux) os_pretty="AlmaLinux" ;;
    rocky)     os_pretty="Rocky Linux" ;;
    rhel)      os_pretty="RHEL" ;;
    ubuntu)    os_pretty="Ubuntu" ;;
    *)         os_pretty="${OS_ID^}" ;;
  esac
  MD_OS_LABEL="${os_pretty} ${OS_VERSION}"
  MD_TUI_BACKTITLE="mail-deploy - ${MD_OS_LABEL} mail-server deployer   (Esc = quit)"

  # A fresh cloud image runs its first unattended update within minutes of
  # boot; ensure_tui's whiptail install (the first package touch, inside
  # collect_interactive below) would then sit silently on the dpkg lock and
  # look hung. Drain visibly before any UI or package work. See
  # pkg_lock_wait() in lib/common.sh.
  pkg_lock_wait
  # Not enough on its own: apt-daily-upgrade.timer can fire again LATER in a
  # ~10-minute install even after this first wait drained a lock that was
  # already held -- observed live, contention recurring well after this
  # point. Masking the timers here means it cannot happen a second time; see
  # pkg_disable_auto_updates() in lib/common.sh for what it does and does not
  # touch.
  pkg_disable_auto_updates
  if [ -n "$ANSWERS" ]; then
    load_answers
    preflight_host                            # hard-fail root/OS, warn RAM/ports/repos
    show_sysinfo                              # record what the host looked like at t=0
  else
    tui_welcome "$MD_PURPOSE"                 # start screen: Begin / Exit buttons
    # preflight_host runs here, not before tui_welcome: tui_welcome clears the
    # screen on entry, which would wipe any warnings printed ahead of it. It
    # still lands before collect_interactive, so a refused host dies before
    # the wizard's ~20 prompts rather than after.
    preflight_host                            # hard-fail root/OS, warn RAM/ports/repos
    show_sysinfo                              # host-facts screen: right box? (OK to continue)
    # The questions AND the review screen (Apply / Change... / Abort). The
    # review used to come after save_answers below, so a wizard run that was
    # then aborted had already written answers.effective; now nothing past
    # this line runs until the operator has chosen Apply.
    collect_interactive
  fi
  apply_defaults
  validate
  export_config
  save_answers          # so this host can be re-run later; see the function
  log_info "configuration:"; summary_text | while IFS= read -r l; do log_info "  $l"; done
  # Redundant with preflight_host above by design: os_detect() (inside
  # require_supported_os) does unconditional plain assignments (WEB_USER,
  # PHP_FPM_SOCK, etc.) that must still run here, AFTER apply_defaults/
  # load_answers, so the OS profile keeps winning over any answers-file value
  # the same way it always has. Moving this earlier would silently flip that
  # precedence.
  [ "${DRY_RUN:-0}" = 1 ] || require_supported_os
  run_modules
  log_info "deploy complete. Credentials: $MD_CRED_FILE ; log: $MD_LOG"
}

main "$@"
