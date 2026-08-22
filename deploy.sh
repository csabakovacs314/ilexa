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
# shellcheck source=lib/db.sh
source "$MD_ROOT/lib/db.sh"

ANSWERS=""
declare -a ONLY=()

# Shown on the interactive start screen (see tui_welcome). No specific OS
# named here on purpose -- tui_welcome's own title line already shows the
# real detected OS (main()'s early os_detect call sets MD_OS_LABEL), so
# naming one here too would risk contradicting it.
MD_PURPOSE="  This tool stands up a complete, hardened mail server on a FRESH,
  supported host — reproducing a production-grade reference
  stack from parameterized templates (no live secrets are copied):

    • Postfix (virtual domains via MySQL) + postscreen DNSBLs
    • Dovecot IMAP/POP3 (SQL auth, Maildir, optional full-text search)
    • rspamd + ClamAV, OpenDKIM / DMARC / SPF
    • PostfixAdmin, Roundcube webmail, and the ilexa console
    • Fail2Ban, firewalld geoblock, and the AlienVault OTX suite
    • Secure-by-default hardening (SSH key-only, backups, auto-reboot)

  It asks a short series of questions, shows a review screen, and only
  THEN changes anything. Existing files are backed up before overwrite.

  WARNING: run this on a fresh host — modules overwrite /etc/postfix,
  /etc/dovecot, databases, etc. with templated defaults."

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
  local info="OS:        ${MD_OS_LABEL:-unknown}
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

collect_interactive() {
  ensure_tui
  # Choosing "Exit"/Esc on any prompt aborts cleanly (md_abort), no changes.
  # No placeholder pre-filled here on purpose: offering "mail.example.com" as
  # the suggested default meant pressing Enter/OK without editing it silently
  # accepted the placeholder as a real answer — confirmed live, an operator
  # did exactly this repeatedly and only noticed once TLS/DNS broke much
  # later. Loop until a real, dotted, non-placeholder value is entered.
  if _tui_ok; then
    MAIL_FQDN=""
    while true; do
      MAIL_FQDN=$(tui_input "Mail server public FQDN (MX target / TLS CN), e.g. mail.yourdomain.com:" "$MAIL_FQDN") || md_abort
      case "$MAIL_FQDN" in
        ""|mail.example.com)
          tui_msg "FQDN required" "Enter your actual mail server FQDN. \"mail.example.com\" is only a placeholder from the docs — it won't resolve."
          # Come back with an EMPTY box rather than re-offering the value
          # just rejected: whiptail pre-fills the default with the cursor
          # at the end and typing APPENDS to it, so re-seeding the
          # placeholder means the next attempt silently becomes
          # "mail.example.com<whatever they type>" unless they manually
          # clear the field first.
          MAIL_FQDN="" ;;
        *.*) break ;;
        *) tui_msg "Invalid FQDN" "\"$MAIL_FQDN\" doesn't look like a FQDN (needs at least one dot, e.g. mail.yourdomain.com)."
           MAIL_FQDN="" ;;
      esac
    done
  else
    # No real TTY (whiptail present but stdin/stdout aren't interactive) --
    # nobody is present to answer prompts either way, so fall back to a
    # single non-looping call rather than spin forever waiting for a value
    # that will never change. tui_input's own non-TTY branch just echoes
    # this default straight back.
    MAIL_FQDN=$(tui_input "Mail server public FQDN (MX target / TLS CN):" "mail.example.com") || md_abort
  fi
  MAIL_HOSTNAME="${MAIL_FQDN%%.*}"
  PRIMARY_DOMAIN=$(tui_input "Primary virtual mail domain:" "${MAIL_FQDN#*.}") || md_abort
  EXTRA_DOMAINS=$(tui_input "Extra virtual domains (space-separated, or blank):" "") || md_abort
  ADMIN_EMAIL=$(tui_input "Admin / PostfixAdmin superadmin email:" "postmaster@$PRIMARY_DOMAIN") || md_abort
  ADMIN_PASSWORD=$(tui_password "PostfixAdmin superadmin password (blank = auto-generate):") || md_abort
  MAIL_STORE=$(tui_input "Maildir store root:" "/data/mail") || md_abort
  # Asked for explicitly: it drives the system clock, mail-log timestamps, cron
  # and every time the console displays, and silently defaulting to UTC left
  # operators reading their own logs two hours out. Defaults to whatever the
  # host is already set to, so answering nothing changes nothing.
  TIMEZONE=$(tui_input "System timezone (IANA name, e.g. Europe/Budapest):" \
                       "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)") || md_abort
  # Three real answers, not two. Self-signed is a lab fallback -- no client
  # accepts it -- so an operator who already holds a certificate must be able
  # to say so here rather than install, discover the browser warning, and go
  # looking for where to put their own cert.
  if tui_yesno "Use Let's Encrypt for TLS? (No = supply your own certificate, or a self-signed lab cert)"; then
    TLS_MODE=letsencrypt
  elif tui_yesno "Do you have your own certificate to install? (No = self-signed lab cert, browsers WILL warn)"; then
    TLS_MODE=custom
    TLS_CUSTOM_CERT=$(tui_input "Path to your certificate (PEM; server cert first, then intermediates):" "") || md_abort
    TLS_CUSTOM_KEY=$(tui_input "Path to its private key (PEM, not passphrase-protected):" "") || md_abort
  else
    TLS_MODE=selfsigned
  fi
  SPAM_REJECT=$(tui_input "rspamd reject threshold (safety net; tag threshold is 4):" "15") || md_abort
  GEOBLOCK_COUNTRIES=$(tui_input "Geoblock country codes:" "ru cn br kr") || md_abort
  SSH_PORT=$(tui_input "SSH port to open in firewalld:" "22") || md_abort
  if tui_yesno "Enable the AlienVault OTX threat-intel suite?"; then
    ENABLE_OTX=yes
    OTX_API_KEY=$(tui_password "OTX API key (blank = configure later):") || md_abort
  else ENABLE_OTX=no; fi
  SPAMHAUS_DQS_KEY=$(tui_password \
    "Spamhaus DQS account key (blank = skip, use rspamd's default public zones):") || md_abort

  # Reputation feeds. Every updater is installed either way; a blank key simply
  # leaves that source disabled, and it can be filled in later from the ilexa
  # Admin tab without touching the installer again.
  if tui_yesno "Enable the reputation feeds (Spamhaus, FireHOL, URLhaus, AbuseIPDB, ...)?"; then
    ENABLE_FEEDS=yes
    ABUSECH_API_KEY=$(tui_password \
      "abuse.ch API key — URLhaus + ThreatFox/Feodo (blank = install disabled, set later in ilexa):") || md_abort
    ABUSEIPDB_API_KEY=$(tui_password \
      "AbuseIPDB API key (blank = install disabled, set later in ilexa):") || md_abort
  else ENABLE_FEEDS=no; fi

  # Opt-in, and the operator sees what it means first. This copies the content
  # of everyone's mail into one admin-readable mailbox.
  #
  # Explainer and choice are SEPARATE dialogs on purpose: as one ~34-line
  # yesno this overflowed tui_yesno's fixed 10x74 box, whiptail rendered it
  # as a scrolled region, and the initially focused control was the scroll
  # area rather than a button -- reported from a live install as "the
  # selector should be on OK by default". A msgbox has only an OK button
  # (focused by definition), and the yesno that follows is short enough
  # that its Yes/No buttons render normally.
  tui_msg "DEPLOYMENT TYPE: the central mail archive" \
"WITH ARCHIVE (Postfix always_bcc copies every message to one mailbox)
WITHOUT ARCHIVE (filtering only; nothing is retained centrally)

WHY THE ARCHIVE EXISTS -- it is not 'keep everything just in case':

 * POP3 clients DELETE mail from the server after download. Once a user has
   collected their mail there is no server-side copy left, so a message that
   was mis-filed can never be examined, recovered or learned from. IMAP users
   who empty folders create the same hole.
 * Users do not reliably report spam. The spam@ / ham@ addresses only work for
   people who bother to forward things, so without an archive the filter's
   training corpus is whatever a handful of users happened to send.
 * This system has NO quarantine. Suspect mail is tagged and DELIVERED (that
   is deliberate -- see the spam model), so the archive is the only place a
   false positive can be retrieved from. The same applies to messages held
   back by attachment or virus scoring.
 * It is what the Archive tab, the search, the spam/ham training buttons and
   the weekly digest all read from. Without it those features have no data.

WITHOUT the archive, filtering still works exactly the same. What you lose is
recovery, retrospective search, and most of the training signal.

GDPR / privacy: this copies the CONTENT of everyone's mail -- inbound and
outbound, personal and business -- into one mailbox administrators can read.
In most jurisdictions that is personal-data processing which needs a lawful
basis, a retention period and users informed in advance. Retention is asked
for next and enforced automatically. The console additionally has a
content-viewing policy (Rendszer -> adatvedelem) which can restrict or forbid
reading message bodies even for administrators; it defaults to DENY."
  if tui_yesno "Enable the central mail archive?

(The previous screen explains what this means, including the GDPR side.)"; then
    ENABLE_ARCHIVE=yes
    ARCHIVE_RETENTION_DAYS=$(tui_input "Keep archived mail for how many days?" "30") || md_abort
  else ENABLE_ARCHIVE=no; fi
  # Console UI language. English default; Yes is whiptail's default button,
  # so plain Enter accepts English. Changeable any time from the console
  # (Admin -> language), which owns the state file after the install.
  if tui_yesno "ilexa console language: use ENGLISH as the interface language?

(No = Hungarian / magyar. Changeable later in the console: Admin -> language.)"; then
    ILEXA_LANG=en
  else ILEXA_LANG=hu; fi
  local extras extra_args=()
  extra_args=(last_login "Dovecot last-login tracking" on \
              fts_xapian "Full-text search (compiled; RAM-heavy)" on \
              unattended "Unattended security updates" on \
              mx_check "rspamd: sender MX validation (needs outbound :25)" on \
              known_senders "rspamd: per-sender freemail reputation" on)
  # clamav-unofficial-sigs is packaged in EPEL but has NO Debian/Ubuntu
  # package at all (checked: apt only offers "fangfrisch", a different tool
  # with an incompatible config format). Offering the choice on apt would be
  # offering something we cannot deliver, so the item only appears where it
  # can actually be installed; 35-clamav logs the reason on apt.
  if [ "${PKG_MGR:-dnf}" != apt ]; then
    extra_args+=(unofficial_sigs "Third-party ClamAV signature sources + YARA" on)
  fi
  extras=$(tui_checklist "Optional extras" "${extra_args[@]}")
  case " $extras " in *" last_login "*) ENABLE_LAST_LOGIN=yes;; *) ENABLE_LAST_LOGIN=no;; esac
  case " $extras " in *" fts_xapian "*) ENABLE_FTS_XAPIAN=yes;; *) ENABLE_FTS_XAPIAN=no;; esac
  case " $extras " in *" unattended "*) ENABLE_UNATTENDED=yes;; *) ENABLE_UNATTENDED=no;; esac
  case " $extras " in *" unofficial_sigs "*) ENABLE_UNOFFICIAL_SIGS=yes;; *) ENABLE_UNOFFICIAL_SIGS=no;; esac
  case " $extras " in *" mx_check "*) ENABLE_MX_CHECK=yes;; *) ENABLE_MX_CHECK=no;; esac
  case " $extras " in *" known_senders "*) ENABLE_KNOWN_SENDERS=yes;; *) ENABLE_KNOWN_SENDERS=no;; esac
  local hard
  hard=$(tui_checklist "Hardening options (secure-by-default)" \
    ssh    "SSH key-only + sudo admin user" on \
    webmin "Webmin source-IP allowlist" on \
    reboot "Kernel auto-reboot maintenance window" on \
    smtp   "SMTP tuning (50M limit, delay_reject)" on \
    selinux "SELinux enforcing (advanced)" off)
  case " $hard " in *" ssh "*) HARDEN_SSH_KEYONLY=yes;; *) HARDEN_SSH_KEYONLY=no;; esac
  case " $hard " in *" webmin "*) HARDEN_WEBMIN=yes;; *) HARDEN_WEBMIN=no;; esac
  case " $hard " in *" reboot "*) HARDEN_KERNEL_AUTOREBOOT=yes;; *) HARDEN_KERNEL_AUTOREBOOT=no;; esac
  case " $hard " in *" smtp "*) HARDEN_SMTP_TUNING=yes;; *) HARDEN_SMTP_TUNING=no;; esac
  case " $hard " in *" selinux "*) HARDEN_SELINUX=yes;; *) HARDEN_SELINUX=no;; esac
}

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
  : "${SPAM_SUBJECT_TAG:={Spam?}}"
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
  : "${ENABLE_BREACH_CHECK:=no}"
  : "${ENABLE_FTS_OPTIMIZE:=yes}"
  : "${ENABLE_ARCHIVE:=no}"
  : "${ARCHIVE_RETENTION_DAYS:=30}"
  : "${ILEXA_URL_PREFIX:=/ilexa/}"
  : "${ILEXA_LANG:=en}"
  : "${ILEXA_ADMIN_USER:=admin}"
  : "${ILEXA_ADMIN_PASSWORD:=}"        # blank = generated and recorded
  : "${QUARANTINE_FOLDERS:=Junk Quarantine Spam}"
  : "${ARCHIVE_USER:=archive@$PRIMARY_DOMAIN}"
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
  export MAIL_FQDN MAIL_HOSTNAME PRIMARY_DOMAIN EXTRA_DOMAINS ADMIN_EMAIL ADMIN_PASSWORD PFA_ADMIN_PASSWORD \
    MAIL_STORE TLS_MODE CERTBOT_METHOD TLS_CUSTOM_CERT TLS_CUSTOM_KEY GEOBLOCK_COUNTRIES \
    ENABLE_OTX OTX_API_KEY OTX_TRUSTED_CIDRS SPAMHAUS_DQS_KEY ABUSIX_API_KEY ENABLE_LAST_LOGIN ENABLE_FTS_XAPIAN ENABLE_UNATTENDED \
    ENABLE_MX_CHECK ENABLE_KNOWN_SENDERS ENABLE_HU_BRAND_GUARD \
    ENABLE_MTA_STS MTA_STS_MODE TLSRPT_RUA ENABLE_IPV6 INET_PROTOCOLS MYNETWORKS ENABLE_SIEVE \
    ENABLE_QUOTA QUOTA_FIELD QUOTA_POLICY ENABLE_METRICS METRICS_SCRAPE_CIDR ENABLE_AUTOCONFIG ENABLE_FTS_OPTIMIZE \
    HARDEN_SSH_KEYONLY ADMIN_SSH_PUBKEY HARDEN_SELINUX HARDEN_WEBMIN WEBMIN_ALLOW_IPS \
    HARDEN_KERNEL_AUTOREBOOT HARDEN_SMTP_TUNING MESSAGE_SIZE_LIMIT BACKUP_TARGET BACKUP_PASSPHRASE \
    SMTPD_DELAY_REJECT SENDER_LOGIN_GUARD POSTSCREEN_DNSBL_SITES TLS_DIR TLS_CERT TLS_KEY TLS_CAFILE SSH_PORT WEBMIN_PORT \
    SCANNER SPAM_ADD_HEADER SPAM_REWRITE_SUBJECT SPAM_REJECT SPAM_SUBJECT_TAG \
    RSPAMD_CTRL RSPAMD_MILTER CLAMD_SOCKET MTA_GROUP \
    ENABLE_ILEXA ILEXA_LIST_DIR ENABLE_HU_CLASSIFY HU_CLASSIFY_REPORT_EMAIL ENABLE_UNOFFICIAL_SIGS \
    ENABLE_FEEDS ABUSECH_API_KEY ABUSEIPDB_API_KEY ENABLE_OTX_URI \
    ENABLE_BREACH_CHECK ILEXA_URL_PREFIX ILEXA_ADMIN_USER ILEXA_ADMIN_PASSWORD ILEXA_LANG \
    QUARANTINE_FOLDERS ARCHIVE_USER TIMEZONE SITE_TITLE PHP_FPM_SOCK MYSQL_SOCK \
    WEB_USER WEB_GROUP ENABLE_ARCHIVE ARCHIVE_RETENTION_DAYS ENABLE_SIEM_EXPORT ENABLE_REPORT_ADDRESSES
}

summary_text() {
  cat <<EOF
FQDN:            $MAIL_FQDN
Primary domain:  $PRIMARY_DOMAIN
Extra domains:   ${EXTRA_DOMAINS:-(none)}
Admin email:     $ADMIN_EMAIL
Mail store:      $MAIL_STORE
TLS mode:        $TLS_MODE
Spam tag/reject:  ${SPAM_ADD_HEADER:-4} / ${SPAM_REJECT:-15}
Mail archive:    ${ENABLE_ARCHIVE:-no}${ENABLE_ARCHIVE:+ (${ARCHIVE_RETENTION_DAYS:-30} days)}
Feeds:           ${ENABLE_FEEDS:-no}
ilexa console:   ${ENABLE_ILEXA:-yes} at ${ILEXA_URL_PREFIX:-/ilexa/} (language: ${ILEXA_LANG:-en})
Geoblock:        $GEOBLOCK_COUNTRIES
OTX suite:       $ENABLE_OTX
Spamhaus DQS:    $([ -n "${SPAMHAUS_DQS_KEY:-}" ] && echo yes || echo no)
Abusix:          $([ -n "${ABUSIX_API_KEY:-}" ] && echo "yes (remember to allowlist this server IP in the Abusix portal)" || echo no)
Extras:          last_login=$ENABLE_LAST_LOGIN fts_xapian=$ENABLE_FTS_XAPIAN unattended=$ENABLE_UNATTENDED mx_check=$ENABLE_MX_CHECK known_senders=$ENABLE_KNOWN_SENDERS
Hardening:       ssh=$HARDEN_SSH_KEYONLY webmin=$HARDEN_WEBMIN reboot=$HARDEN_KERNEL_AUTOREBOOT smtp=$HARDEN_SMTP_TUNING selinux=$HARDEN_SELINUX
Backups target:  ${BACKUP_TARGET:-(none / parameterized)}
DRY_RUN:         ${DRY_RUN:-0}
EOF
}

run_modules() {
  local m base run
  for m in "$MD_ROOT"/modules/[0-9]*.sh; do
    [ -e "$m" ] || die "no modules found in $MD_ROOT/modules"
    base=$(basename "$m" .sh)
    if [ ${#ONLY[@]} -gt 0 ]; then
      run=0; local o; for o in "${ONLY[@]}"; do [[ "$base" == "$o"* ]] && run=1; done
      [ "$run" = 1 ] || continue
    fi
    log_info "=== module $base ==="
    bash "$m" || die "module $base failed"
  done
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
  MD_TUI_BACKTITLE="mail-deploy — ${MD_OS_LABEL} mail-server deployer  (Exit: Ctrl+X)"

  # A fresh cloud image runs its first unattended update within minutes of
  # boot; ensure_tui's whiptail install (the first package touch, inside
  # collect_interactive below) would then sit silently on the dpkg lock and
  # look hung. Drain visibly before any UI or package work. See
  # pkg_lock_wait() in lib/common.sh.
  pkg_lock_wait
  if [ -n "$ANSWERS" ]; then
    load_answers
    preflight_host                            # hard-fail root/OS, warn RAM/ports/repos
    show_sysinfo                              # record what the host looked like at t=0
  else
    tui_welcome "$MD_PURPOSE"                 # start screen + Ctrl+X exit
    # preflight_host runs here, not before tui_welcome: tui_welcome clears the
    # screen on entry, which would wipe any warnings printed ahead of it. It
    # still lands before collect_interactive, so a refused host dies before
    # the wizard's ~20 prompts rather than after.
    preflight_host                            # hard-fail root/OS, warn RAM/ports/repos
    show_sysinfo                              # host-facts screen: right box? (OK to continue)
    collect_interactive
  fi
  apply_defaults
  validate
  export_config
  log_info "configuration:"; summary_text | while IFS= read -r l; do log_info "  $l"; done
  if [ -z "$ANSWERS" ]; then
    tui_review "$(summary_text)" || md_abort   # Abort button on review = clean exit
  fi
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
