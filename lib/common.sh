#!/usr/bin/env bash
# lib/common.sh — shared helpers for the mail-deploy toolkit.
# Sourced by deploy.sh and every module. No side effects on source.

# ---- paths / globals -------------------------------------------------------
: "${MD_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${MD_STATE_DIR:=/var/lib/ilexa-install/state}"
: "${MD_LOG:=/var/log/ilexa-install.log}"
: "${MD_CRED_FILE:=/root/ilexa-install-credentials.txt}"
: "${MD_TEMPLATES:=$MD_ROOT/templates}"
: "${MD_ASSETS:=$MD_ROOT/assets}"
: "${MD_BACKUP_SUFFIX:=mdbak}"
: "${DRY_RUN:=0}"        # 1 = describe actions, change nothing

# Per-distribution names (WEB_USER, WEB_SVC, sockets, service names). Modules read
# these instead of hard-coding EL9 paths, so a second OS is a new profile rather
# than an edit to every module.
# shellcheck source=os.sh
. "$(dirname "${BASH_SOURCE[0]}")/os.sh"

# ---- logging ---------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { # level msg...
  local lvl="$1"; shift
  local line
  line="[$(_ts)] [$lvl] $*"
  printf '%s\n' "$line"
  # best-effort file log (may not be writable during --check)
  { printf '%s\n' "$line" >>"$MD_LOG"; } 2>/dev/null || true
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@" >&2; }
log_error() { _log ERROR "$@" >&2; }
die()       { log_error "$@"; exit 1; }

# ---- requirement guards ----------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# clean user-initiated exit (Exit button / Esc / Ctrl+X) — no error, no changes
md_abort() { clear 2>/dev/null || true; log_info "cancelled by user — no changes were made"; exit 0; }

require_cmd() { # cmd...
  local missing=()
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required command(s): ${missing[*]}"
}

# Kept as a thin alias: os_detect (lib/os.sh) does the real work and also
# populates the per-distribution names every module reads. Named for what it
# checks, not for a single version -- os_detect itself now accepts EL9 or
# EL10 (see lib/os.sh).
require_supported_os() { os_detect; }

# Host-only prerequisite checks -- everything that needs nothing from the
# answers (interactive wizard or --answers file). Hard-fails on root/OS (die),
# warns on everything else (RAM, ports, repo reachability).
# Called twice by design: once from deploy.sh's main() — after load_answers on
# the --answers path, or after tui_welcome (but before collect_interactive) on
# the interactive path, so a refused host dies before the wizard's ~20 prompts
# rather than after — and again from modules/00-preflight.sh's normal position
# in the module sequence (idempotent — same checks, same output, harmless to
# repeat; `--only 00-preflight` on an already-deployed host stays a complete,
# useful standalone diagnostic on its own, not half a check split across two
# files).
preflight_host() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log_info "[dry-run] preflight host checks are informational only"
    return 0
  fi
  require_root
  require_supported_os

  local mem_kb
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  log_info "RAM=$((mem_kb/1024))MB"
  [ "$mem_kb" -lt 2000000 ] && log_warn "under 2GB RAM — rspamd/ClamAV/fts_xapian will be tight"

  local p
  for p in 25 80 443 465 587 143 993 110 995; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"; then
      log_warn "port $p already in use — an existing service may conflict"
    fi
  done

  # Every module's pkg_install/pkg_try eventually hits dnf; failing that deep
  # into the run (after the wizard and every earlier module) is the same
  # lateness this function exists to fix. Warn-only: a stale local mirror or
  # a host that gets connectivity later are both legitimate.
  if command -v dnf >/dev/null 2>&1; then
    if dnf -q makecache --refresh >/dev/null 2>&1; then
      log_info "package repositories reachable"
    else
      log_warn "dnf repo metadata refresh failed — check network/repo config before continuing"
    fi
  fi
}

# ---- idempotency markers ---------------------------------------------------
_marker() { echo "$MD_STATE_DIR/$1.done"; }
# A dry run must leave no trace. Writing markers here would make a later REAL run
# skip every module and report success having installed nothing.
mark_done()   { if [ "${DRY_RUN:-0}" = 1 ]; then log_info "[dry-run] would mark $1 done"; return 0; fi
                mkdir -p "$MD_STATE_DIR"; : >"$(_marker "$1")"; }
is_done()     { [ -e "$(_marker "$1")" ]; }
# guard NAME  -> returns 0 (skip) if already done, else marks in-progress intent
step_guard() { # name
  if is_done "$1"; then log_info "step '$1' already done — skipping"; return 1; fi
  return 0
}

# ---- the extracted ilexa app bundle ----------------------------------------
# 55-ilexa unpacks the app here and installs its helpers from it. Later modules
# (72-feeds, 95-sources) need those same helpers, so the path is defined once
# rather than repeated as a literal.
: "${ILEXA_SRC:=/opt/ilexa-src}"

# ---- backup before overwrite ----------------------------------------------
# Backups land in one directory, NOT beside the original. Writing
# "<file>.mdbak-<ts>" in place drops stray files into directories that are read
# wholesale: /etc/cron.d had 120 of them on the test host after a day of module
# re-runs. Cron ignores names containing dots so they never executed, but they
# are indistinguishable from live config at a glance -- they even produced a
# false positive in this project's own "is every cron path executable" check.
#
# The flattened name keeps the full original path, so a backup is traceable
# back to where it came from without a manifest.
backup() { # path
  local p="$1"
  [ -e "$p" ] || return 0
  local flat dst
  flat="${p#/}"; flat="${flat//\//_}"
  dst="${ILEXA_BACKUPS}/${flat}.${MD_BACKUP_SUFFIX}-$(date +%Y%m%d-%H%M%S)"
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] would back up $p -> $dst"; return 0; fi
  mkdir -p "$ILEXA_BACKUPS"
  # -a preserves symlinks: /etc/resolv.conf is one on Debian, and copying its
  # target instead would quietly turn a managed symlink into a stale file.
  cp -a -- "$p" "$dst" && log_info "backed up $p -> $dst"
}

# ---- canonical filesystem locations ----------------------------------------
# Everything the installer drops on a host goes to one of these. They exist so
# the paths are declared once rather than spelled out across two dozen files --
# which is exactly how /root came to hold executable loaders, downloaded zone
# data and API keys in the first place.
#
#   ILEXA_SBIN    executables an admin (or cron) runs; alongside every other
#                 helper this installer ships
#   ILEXA_STATE   variable data the loaders build and read back -- NOT /var/cache,
#                 because firewall-report.sh genuinely depends on the geoip zone
#                 files being there, so they are not safely deletable
#   ILEXA_SECRETS API keys. A dedicated directory at 0700 root:root rather than
#                 loose 0600 files in /etc/ilexa, whose own mode is 0755 with
#                 world-readable config in it: this makes "the web user can
#                 never read a key" a property of the directory instead of
#                 something each file has to get right.
#
# /root keeps only operator-facing output: the credentials dump and the
# generated DNS records, both of which are for the human, not the software.
: "${ILEXA_SBIN:=/usr/local/sbin}"
: "${ILEXA_STATE:=/var/lib/ilexa}"
: "${ILEXA_SECRETS:=/etc/ilexa/secrets}"
: "${ILEXA_GEOIP:=$ILEXA_STATE/geoip}"
: "${ILEXA_BACKUPS:=/var/lib/ilexa-install/backups}"

# ---- virtual-mail ownership ------------------------------------------------
# Every virtual mailbox on disk is owned by the postfix user, and three
# separate places have to agree on its numeric id: Postfix's virtual_uid_maps/
# virtual_gid_maps/virtual_minimum_uid, Dovecot's SQL userdb (which returns a
# uid per user), and the mail store's own ownership.
#
# These were hardcoded to 89 -- correct on EL, where the postfix user is
# always uid 89, and wrong everywhere else. Debian/Ubuntu allocate the postfix
# user dynamically (112 on the test host) and have no uid 89 at all, so the
# store ended up owned by a nonexistent user, Dovecot's userdb handed out a
# uid below its own first_valid_uid, and doveadm refused every mailbox with
# "Mail access for users with UID 89 not permitted".
#
# Resolve it from the installed postfix user instead of assuming. Callers must
# run after 20-postfix has installed the package that creates the user.
mail_owner_ids() { # -> sets MAIL_UID / MAIL_GID
  if MAIL_UID="$(id -u postfix 2>/dev/null)" && MAIL_GID="$(id -g postfix 2>/dev/null)" \
     && [ -n "$MAIL_UID" ] && [ -n "$MAIL_GID" ]; then
    return 0
  fi
  # --dry-run must work on a host where nothing is installed yet: it renders
  # templates without ever running pkg_install, so the postfix user does not
  # exist and every caller of this function would abort. Fall back to the EL
  # value purely so the dry run can finish and show the rendered output; a real
  # run resolves the true id above, and this branch never executes there.
  if [ "${DRY_RUN:-0}" = 1 ]; then
    MAIL_UID=89; MAIL_GID=89
    log_warn "[dry-run] postfix user absent — using placeholder uid/gid 89 for rendering"
    return 0
  fi
  die "postfix user not found — 20-postfix must install postfix before this module runs"
}

# ---- secret generation -----------------------------------------------------
gen_pw() { # [length]  -> strong alnum password (no shell-hostile chars)
  local len="${1:-24}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"; echo
}

# record a generated credential to the root-only human-readable credentials file
# record_cred <label> <user> <secret>
#
# THREE arguments, not two. Every caller has always passed three -- label,
# username, secret -- but this function used to declare only ("label value")
# and print "$1" "$2", silently DISCARDING the secret. The credentials file
# therefore listed each account's name with no password, for every generated
# credential: the ilexa console, the PostfixAdmin superadmin and the rspamd
# controller. The operator had no way to log in to anything, and nothing in
# the output hinted at it -- the file existed and looked plausible.
# Reproduced and fixed 2026-08-15.
#
# The secret is printed on its own line rather than a third column so a long
# generated password cannot be visually truncated or line-wrapped into
# something that looks like part of the next field.
record_cred() { # label user secret
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] would record credential '$1'"; return 0; fi
  { [ -e "$MD_CRED_FILE" ] || { install -m 600 /dev/null "$MD_CRED_FILE"; echo "# mail-deploy generated credentials — $(_ts)" >"$MD_CRED_FILE"; }; } 2>/dev/null
  { printf '%-32s %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '%-32s %s\n' "" "$3"
  } >>"$MD_CRED_FILE"
}

# ---- shared operator-facing DNS notes --------------------------------------
# /root/mail-deploy-dns-extra.txt is written by more than one module
# (76-mta-sts, 78-autoconfig). Both used to plain-append, so every re-run
# duplicated their blocks indefinitely -- but truncating the file instead
# would delete the other module's records, the same "assumed sole owner"
# mistake that cost a live Abusix config on 2026-08-16. So each module owns a
# marked block and replaces only its own.
#
#   dns_extra_block <owner> <<'EOF' ... EOF
DNS_EXTRA_FILE=/root/mail-deploy-dns-extra.txt
dns_extra_block() { # owner  (body on stdin)
  local owner="$1" begin end body tmp
  begin="# >>> ilexa:${owner} >>>"
  end="# <<< ilexa:${owner} <<<"
  body="$(cat)"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log_info "[dry-run] would write the '$owner' block in $DNS_EXTRA_FILE"; return 0
  fi
  [ -e "$DNS_EXTRA_FILE" ] || install -m 644 /dev/null "$DNS_EXTRA_FILE"
  tmp="$(mktemp)" || return 1
  # drop a previous block from this owner only
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$DNS_EXTRA_FILE" > "$tmp"
  # Pre-marker installs appended an unmarked copy of their block on every run;
  # those are left alone (we only delete what we marked) but are worth naming.
  if grep -qE '^# ===== (autoconfig / autodiscover|MTA-STS)' "$tmp"; then
    log_warn "$DNS_EXTRA_FILE still holds unmarked block(s) from an older installer -- harmless duplicates in an operator notes file, safe to delete by hand"
  fi
  # The blank separator goes INSIDE the markers, so removing the block removes
  # it too. With it outside, each re-run stripped the marker lines but left the
  # blank behind and added another -- the file grew by one line per owner per
  # run, which is how this helper's first version failed its own idempotency
  # test on the 24.04 box.
  { printf '%s\n' "$begin"; printf '%s\n' "$body"; printf '\n'; printf '%s\n' "$end"; } >> "$tmp"
  cat "$tmp" > "$DNS_EXTRA_FILE"
  rm -f "$tmp"
}

# ---- cross-module secrets (sourceable KEY=VALUE, 0600) ---------------------
: "${MD_SECRETS:=$MD_STATE_DIR/secrets.env}"
save_secret() { # KEY VALUE  — persist so later module subprocesses can load it
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] would save secret '$1'"; return 0; fi
  mkdir -p "$MD_STATE_DIR"
  [ -e "$MD_SECRETS" ] || install -m 600 /dev/null "$MD_SECRETS"
  # replace existing key or append
  if grep -q "^$1=" "$MD_SECRETS" 2>/dev/null; then
    sed -i "s|^$1=.*|$1='$2'|" "$MD_SECRETS"
  else
    printf "%s='%s'\n" "$1" "$2" >>"$MD_SECRETS"
  fi
}
load_secrets() { # source all saved secrets into the current shell
  # shellcheck disable=SC1090
  [ -r "$MD_SECRETS" ] && source "$MD_SECRETS" || true
}

# ---- template rendering ----------------------------------------------------
# render TEMPLATE DEST  — substitutes @@KEY@@ from exported MD_VAR_<KEY> env.
# Uses sed (NOT envsubst) so native $shell/$postfix/$dovecot vars are preserved.
render() {
  local tmpl="$1" dest="$2"
  [ -r "$tmpl" ] || die "template not found: $tmpl"
  local sedargs=() key val var
  # collect every @@KEY@@ referenced in the template
  while IFS= read -r key; do
    var="MD_VAR_${key}"
    val="${!var-}"
    if [ -z "${!var+x}" ]; then
      die "template $tmpl references @@${key}@@ but MD_VAR_${key} is unset"
    fi
    # escape sed replacement metacharacters: \ & and the / delimiter
    val=${val//\\/\\\\}; val=${val//&/\\&}; val=${val//\//\\/}
    sedargs+=(-e "s/@@${key}@@/${val}/g")
  done < <(grep -oE '@@[A-Z0-9_]+@@' "$tmpl" | sort -u | sed 's/@@//g')

  if [ "$DRY_RUN" = 1 ]; then
    log_info "[dry-run] would render $tmpl -> $dest"; return 0
  fi
  backup "$dest"
  mkdir -p "$(dirname "$dest")"
  if [ ${#sedargs[@]} -eq 0 ]; then
    cp -- "$tmpl" "$dest"
  else
    sed "${sedargs[@]}" -- "$tmpl" >"$dest"
  fi
  log_info "rendered $tmpl -> $dest"
}

# set a template variable: setvar KEY VALUE
setvar() { export "MD_VAR_$1=$2"; }

# verify_sha256 FILE EXPECTED — supply-chain guard for downloaded artifacts.
# Match => 0. Mismatch => 1 (caller should fail closed and skip). Empty EXPECTED
# => 0 with a loud warning (integrity not pinned).
verify_sha256() {
  local file="$1" expected="$2" actual
  if [ -z "$expected" ]; then
    log_warn "integrity NOT pinned for $(basename "$file") — checksum verification skipped"
    return 0
  fi
  actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
  if [ "$actual" = "$expected" ]; then
    log_info "sha256 OK $(basename "$file")"; return 0
  fi
  log_error "sha256 MISMATCH for $(basename "$file"): expected $expected, got ${actual:-<none>}"
  return 1
}

# ---- package / service / file helpers -------------------------------------
# Two variants on purpose. The plain ones abort the run, which is what the 20-odd
# unguarded call sites want -- no module uses `set -e`, so a soft failure there would
# silently produce a half-built server. The *_try ones return non-zero for the handful
# of places that genuinely have a fallback.
#
# Note `die` calls exit: an exit inside a function is NOT caught by `||` at the call
# site, so `pkg_install x || fallback` can never reach the fallback. Use pkg_try there.
pkg_try() { # pkg...  -> 0/1, never aborts
  # Dispatches on $PKG_MGR, set by os.sh's os_detect. BOTH branches are live:
  # os_profile_debian sets PKG_MGR=apt and is exercised on Ubuntu 22.04/24.04/
  # 26.04, os_profile_el sets dnf for EL9/EL10. (This comment used to say the
  # apt branch was "scaffolding ... unreachable today", which stopped being
  # true once the Debian profile landed and would mislead anyone reading it.)
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] ${PKG_MGR:-dnf} install $*"; return 0; fi
  case "$PKG_MGR" in
    dnf) dnf -y install "$@" && return 0 ;;
    # DPkg::Lock::Timeout is not optional politeness -- without it the FIRST
    # apt call on a freshly-provisioned Ubuntu box fails outright, because
    # unattended-upgrades runs on first boot and holds the dpkg frontend lock
    # for minutes. apt does not wait by default; it prints "Could not get lock
    # /var/lib/dpkg/lock-frontend" and exits non-zero after ~3 seconds, which
    # aborted 05-base and the whole install. Observed on a fresh Ubuntu 24.04
    # host 2026-08-17, three seconds into the very first install. Any user
    # installing onto a new VM hits this, so waiting is the correct default.
    apt) apt-get -y -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" install "$@" && return 0 ;;
    *)   die "pkg_try: unknown or unset PKG_MGR '$PKG_MGR' -- os_detect must run before any pkg_install/pkg_try call" ;;
  esac
  log_warn "$PKG_MGR install failed: $*"; return 1
}

pkg_install() { # pkg...  -> aborts the run on failure
  pkg_try "$@" || die "$PKG_MGR install failed: $*"
}

# Wait for a package manager ALREADY RUNNING on the host before we touch it.
# A freshly booted cloud image starts unattended updates within minutes of
# first boot (Ubuntu: apt-daily/apt-daily-upgrade -> unattended-upgrade;
# EL: dnf-makecache, sometimes PackageKit), and a first-boot run with a
# kernel in it can hold the dpkg lock well past the 10-minute
# DPkg::Lock::Timeout every apt call here carries. That timeout also waits
# SILENTLY, so to an operator the installer simply looks hung -- which is
# exactly how this function came to exist. This wait is chatty on purpose:
# it names what holds the lock and counts the time, so "waiting for the
# distro's own updater" never looks like "wedged".
#
# Detection is deliberately process/lock based, not unit-name based alone:
# unattended-upgrade is a python script (comm shows python3), and the unit
# is often inactive while the triggered child still holds the lock.
# PKG_LOCK_WAIT_MAX (seconds, default 1800) caps the wait.
pkg_lock_wait() {
  local max="${PKG_LOCK_WAIT_MAX:-1800}" interval=15 waited=0 holders
  _pkg_lock_holders() {
    holders=""
    if command -v apt-get >/dev/null 2>&1; then
      # apt-daily/apt-daily-upgrade are oneshot: "active" genuinely means a
      # run is in progress. unattended-upgrades.service is deliberately NOT
      # in this list: on Ubuntu it is the permanently-running shutdown-hook
      # daemon (unattended-upgrade-shutdown --wait-for-signal), active for
      # the whole boot -- treating it as a holder made this wait sit out its
      # full cap on EVERY Ubuntu box while the dpkg lock was demonstrably
      # free (caught live on the 24.04 redeploy, its first day in service).
      local u
      for u in apt-daily.service apt-daily-upgrade.service; do
        systemctl is-active --quiet "$u" 2>/dev/null && holders="$holders$u "
      done
      pgrep -x 'apt|apt-get|aptd|dpkg' >/dev/null 2>&1 && holders="${holders}apt/dpkg "
      # Boundary after the name: matches the actual runner
      # (.../unattended-upgrades/unattended-upgrade, plus flags) but not the
      # -shutdown daemon, and not unrelated command lines mentioning the
      # string (the naive -f pattern even matched an ssh session inspecting
      # this very problem).
      pgrep -f '/unattended-upgrade( |$)' >/dev/null 2>&1 && holders="${holders}unattended-upgrade "
      # fuser is authoritative when present (psmisc is not guaranteed on
      # minimal images, hence the process checks above stand on their own).
      if command -v fuser >/dev/null 2>&1 && [ -e /var/lib/dpkg/lock-frontend ]; then
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && holders="${holders}dpkg-lock "
      fi
    else
      pgrep -x 'dnf|yum|packagekitd' >/dev/null 2>&1 && holders="${holders}dnf/yum "
      if command -v fuser >/dev/null 2>&1 && [ -e /var/lib/rpm/.rpm.lock ]; then
        fuser /var/lib/rpm/.rpm.lock >/dev/null 2>&1 && holders="${holders}rpm-lock "
      fi
    fi
    [ -n "$holders" ]
  }
  _pkg_lock_holders || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log_warn "package manager busy (${holders% }) — a real run would wait here (up to ${max}s)"
    return 0
  fi
  log_info "system updates in progress (${holders% }) — waiting for them to finish before installing anything (cap ${max}s, override with PKG_LOCK_WAIT_MAX=)"
  while _pkg_lock_holders; do
    if [ "$waited" -ge "$max" ]; then
      local hint="systemctl stop dnf-makecache.service; pkill -x dnf"
      command -v apt-get >/dev/null 2>&1 \
        && hint="systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service"
      die "package manager still busy after ${max}s (${holders% }) — let the distro's updater finish, or stop it ('$hint') and re-run"
    fi
    sleep "$interval"; waited=$((waited + interval))
    log_info "  still waiting on: ${holders% } (${waited}s elapsed)"
  done
  log_info "package manager free after ${waited}s — continuing"
}

svc_try() { # unit...  -> 0/1, never aborts
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] systemctl enable --now $*"; return 0; fi
  systemctl enable --now "$@" && return 0
  log_warn "failed to enable: $*"; return 1
}

svc_enable() { # unit...  -> aborts the run on failure
  svc_try "$@" || die "failed to enable: $*"
}

svc_reload() { # unit
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] systemctl reload/restart $1"; return 0; fi
  systemctl reload "$1" 2>/dev/null || systemctl restart "$1"
}

# write_file PATH MODE [OWNER]  — content on stdin; backs up existing.
write_file() {
  local path="$1" mode="$2" owner="${3:-}"
  if [ "$DRY_RUN" = 1 ]; then log_info "[dry-run] would write $path ($mode ${owner:-root})"; cat >/dev/null; return 0; fi
  backup "$path"
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  chmod "$mode" "$path"
  [ -n "$owner" ] && chown "$owner" "$path"
  log_info "wrote $path"
}
