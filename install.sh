#!/usr/bin/env bash
# install.sh — one-command interactive bootstrap for the ilexa mail stack.
#
#   curl -fsSL https://raw.githubusercontent.com/csabakovacs314/ilexa/main/install.sh | bash
#
# With no --fqdn and a terminal available, that runs the interactive WIZARD:
# deploy.sh asks for the FQDN and everything else, shows a review screen, and
# writes nothing until it is approved. Force it with --wizard.
#
# For an unattended install, name the host and every other value is derived
# from it:
#
#   curl -fsSL .../install.sh | bash -s -- --fqdn mail.example.org
#
# Three phases, in order, and nothing is changed until the third:
#
#   1. CHECK    read-only report on this host: OS, resources, DNS, ports,
#               leftovers from a previous install. Nothing is modified.
#   2. PLAN     what will be installed, the values derived from --fqdn, and
#               which steps are slow, so a long quiet phase is not mistaken
#               for a hang.
#   3. INSTALL  hand over to deploy.sh, which keeps its own preflight,
#               backups and verification.
#
# Run "install.sh --check --fqdn <name>" to stop after phase 1.
# --wizard and --fqdn are mutually exclusive: the wizard asks for the name.
#
# WARNING: run only on a FRESH host. deploy.sh overwrites /etc/postfix,
# /etc/dovecot, web-server config and databases with templated defaults.
set -euo pipefail

# NOT /opt/ilexa-src -- modules/55-ilexa.sh hardcodes SRC=/opt/ilexa-src as the
# location it unpacks the ILEXA APP bundle into. Cloning the installer there
# merges the two trees, overwrites the installer's own deploy.sh with the app's
# one of the same name, and chowns the whole checkout to the web user (which
# then breaks git with "dubious ownership"). Observed for real on 2026-08-26.
SRC_DIR="${ILEXA_SRC_DIR:-/opt/ilexa-installer}"
REPO="${ILEXA_REPO:-https://github.com/csabakovacs314/ilexa}"
REF="main"
ANSWERS_OUT="${ILEXA_ANSWERS:-/root/answers.conf}"
FQDN="" DOMAIN="" EMAIL="" TLS="auto"
MODE="deploy"          # deploy | acceptance
DRY_RUN=0 ASSUME_YES=0 CHECK_ONLY=0 FORCE=0 VERBOSE=0
WIZARD=0               # 1 = hand the terminal to deploy.sh's interactive wizard

FAILS=0 WARNS=0

# ── Presentation ──────────────────────────────────────────────────────────────
# Colour only when stdout is a terminal: piping the installer into a file or a
# pager must not embed escape codes. Box glyphs only when the locale can render
# them -- a UTF-8 box on a latin1 console is worse than plain ASCII.
if [ -t 1 ]; then
    C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
    # Erase to end of line. The "running…" line is longer than the line that
    # replaces it, so a bare \r would leave the tail of the old text visible.
    C_EL=$'\033[K'
else
    C_DIM=""; C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""; C_EL=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*)
        G_OK="✓"; G_NO="✗"; G_WARN="⚠"; G_RUN="•"
        B_TL="┌"; B_TR="┐"; B_BL="└"; B_BR="┘"; B_H="─"; B_V="│" ;;
    *)
        G_OK="OK"; G_NO="XX"; G_WARN="!!"; G_RUN=">"
        B_TL="+"; B_TR="+"; B_BL="+"; B_BR="+"; B_H="-"; B_V="|" ;;
esac

# A framed banner. Width is fixed at 62 so it does not reflow on resize.
banner() { # title line...
    local w=62 t="$1" rule i; shift
    # Built with a loop, NOT "printf %62s | tr ' ' '─'": tr maps BYTES, and the
    # box-drawing characters are 3 bytes each in UTF-8, so tr emitted a broken
    # first byte 62 times and the rule rendered as replacement characters.
    rule=""; for ((i=0; i<w; i++)); do rule="${rule}${B_H}"; done
    printf '\n%s%s%s%s%s\n' "$C_B" "$B_TL" "$rule" "$B_TR" "$C_0"
    printf '%s%s%s %-*s %s%s%s\n' "$C_B" "$B_V" "$C_0" "$((w-2))" "$t" "$C_B" "$B_V" "$C_0"
    local l
    for l in "$@"; do
        printf '%s%s%s %s%-*s%s %s%s%s\n' "$C_B" "$B_V" "$C_0" "$C_DIM" "$((w-2))" "$l" "$C_0" "$C_B" "$B_V" "$C_0"
    done
    printf '%s%s%s%s%s\n\n' "$C_B" "$B_BL" "$rule" "$B_BR" "$C_0"
}


say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# check <label> <ok|warn|fail> <detail> [remedy]
check() {
    local label="$1" state="$2" detail="${3:-}" remedy="${4:-}"
    case "$state" in
        ok)   printf '  [ OK ] %-26s %s\n' "$label" "$detail" ;;
        warn) printf '  [WARN] %-26s %s\n' "$label" "$detail"; WARNS=$((WARNS+1))
              [ -n "$remedy" ] && printf '         %-26s -> %s\n' "" "$remedy" ;;
        fail) printf '  [FAIL] %-26s %s\n' "$label" "$detail"; FAILS=$((FAILS+1))
              [ -n "$remedy" ] && printf '         %-26s -> %s\n' "" "$remedy" ;;
    esac
}

usage() {
    cat <<'USAGE'
ilexa installer

  install.sh --fqdn mail.example.org [options]

Required:
  --fqdn FQDN         public hostname of this mail server (MX target, TLS CN)

Optional:
  --domain DOMAIN     primary mail domain      (default: FQDN minus first label)
  --email ADDRESS     admin/postmaster address (default: postmaster@DOMAIN)
  --tls MODE          letsencrypt | selfsigned | auto   (default: auto)
  --ref REF           git branch or tag to install      (default: main)
  --check             run the environment report only, change nothing
  --acceptance        deploy + verify + idempotency re-run
  --dry-run           rehearse every module, change nothing
  --force             continue even if a check FAILED
  -v, --verbose       show every line the installer prints (default: a progress
                      summary only; the full log is always written to
                      /var/log/ilexa-install.log either way)
  --yes               skip the confirmation prompt
  --help              this text
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fqdn)   FQDN="${2:-}"; shift 2 ;;
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --email)  EMAIL="${2:-}"; shift 2 ;;
        --tls)    TLS="${2:-}"; shift 2 ;;
        --ref)    REF="${2:-}"; shift 2 ;;
        --wizard)     WIZARD=1; shift ;;
        --check)      CHECK_ONLY=1; shift ;;
        --acceptance) MODE="acceptance"; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --force)      FORCE=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"

case "$SRC_DIR" in
    /opt/ilexa-src|/opt/ilexa-src/)
        die "ILEXA_SRC_DIR must not be /opt/ilexa-src -- that path belongs to the
       ilexa APP bundle (modules/55-ilexa.sh unpacks it there) and the two
       trees would overwrite each other. Use /opt/ilexa-installer." ;;
esac

# Refuse to run while a deploy is already in flight. This script re-checks out
# $SRC_DIR, which is the very directory a running deploy.sh executes from --
# swapping files under a live run corrupts it in ways that are hard to diagnose.
#
# NOT "pgrep -f deploy.sh": -f matches any process whose command line merely
# CONTAINS the string, including this script's own shell when install.sh is
# invoked from a one-liner that mentions it. That false positive would block
# legitimate installs, which is worse than the race it guards against. Walk
# /proc instead, treat only a real argv token as a match, and skip this
# process's own ancestry.
_ancestors() {
    local p="$$" ppid
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        printf '%s ' "$p"
        ppid=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || break
        p="$ppid"
    done
}
_deploy_running() {
    local skip cmdline tok d
    skip=" $(_ancestors) "
    for d in /proc/[0-9]*; do
        case "$skip" in *" ${d#/proc/} "*) continue ;; esac
        cmdline=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null) || continue
        while IFS= read -r tok; do
            case "$tok" in
                deploy.sh|*/deploy.sh|run-acceptance.sh|*/run-acceptance.sh) return 0 ;;
            esac
        done <<<"$cmdline"
    done
    return 1
}
if _deploy_running; then
    die "an ilexa deploy is already running on this host.
       Wait for it to finish, then re-run.  Progress:  tail -f /var/log/ilexa-install.log"
fi

# ── Identity ──────────────────────────────────────────────────────────────────
# Prompt only when there is a real terminal. Under "curl | bash" stdin is the
# script itself, so read from /dev/tty explicitly or not at all.
# No --fqdn and a terminal to talk to: run the WIZARD. deploy.sh already asks
# for the FQDN and everything else this entry point would otherwise derive
# from it, with validation, a review screen and an Abort that changes nothing.
# Asking for one value here and defaulting the other twenty silently was the
# worse half of both worlds.
if [ -z "$FQDN" ] && [ "$WIZARD" = 0 ] && { true >/dev/tty; } 2>/dev/null; then
    WIZARD=1
fi
if [ "$WIZARD" = 1 ]; then
    [ -z "$FQDN" ] || die "--wizard and --fqdn are mutually exclusive: the wizard asks for the FQDN itself"
    [ "$MODE" = deploy ] || die "--acceptance runs unattended; it cannot be combined with the wizard"
    { true >/dev/tty; } 2>/dev/null \
        || die "the wizard needs a terminal. Non-interactive? pass --fqdn <name> to install unattended."
else
    [ -n "$FQDN" ] || die "--fqdn is required (no terminal available to prompt)"

    case "$FQDN" in *.*) : ;; *) die "--fqdn must be fully qualified, e.g. mail.example.org" ;; esac
    printf '%s' "$FQDN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
        || die "--fqdn contains characters that are not valid in a hostname: $FQDN"
    [ "$FQDN" != "mail.example.com" ] || die "mail.example.com is the placeholder the installer refuses; use the real name"

    [ -n "$DOMAIN" ] || DOMAIN="${FQDN#*.}"
    [ -n "$EMAIL" ]  || EMAIL="postmaster@${DOMAIN}"
fi

# Resolve a name via DNS, deliberately NOT via getent: getent reads /etc/hosts
# first, and this stack's own base module writes "127.0.0.1 <fqdn>" there, so a
# re-run would see loopback and mis-detect everything downstream.
_dns_a() {
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$1" 2>/dev/null | grep -E '^[0-9.]+$' || true
    elif command -v host >/dev/null 2>&1; then
        host -t A "$1" 2>/dev/null | awk '/has address/{print $NF}' || true
    else
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | grep -v '^127\.' || true
    fi
}

# ── Phase 1: CHECK ────────────────────────────────────────────────────────────
step "1/3  Checking this host  (nothing is modified)"

# -- identity and platform
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${VERSION_ID:-}" in
        ubuntu22.04|ubuntu24.04|ubuntu26.04|debian12|debian13) check "operating system" ok "${PRETTY_NAME:-$ID $VERSION_ID}" ;;
        rhel9*|rhel10*|rocky9*|rocky10*|almalinux9*|almalinux10*) check "operating system" ok "${PRETTY_NAME:-$ID $VERSION_ID}" ;;
        *) check "operating system" warn "${PRETTY_NAME:-unknown} (not a tested combination)" \
                 "tested: Ubuntu 22.04/24.04/26.04, Rocky/Alma/RHEL 9/10" ;;
    esac
else
    check "operating system" fail "/etc/os-release missing" "unsupported or non-standard image"
fi

case "$(uname -m)" in
    x86_64|aarch64) check "architecture" ok "$(uname -m)" ;;
    *) check "architecture" fail "$(uname -m)" "only x86_64 and aarch64 are supported" ;;
esac

[ -d /run/systemd/system ] && check "systemd" ok "present" \
    || check "systemd" fail "not running" "this stack manages services through systemd"

_ram=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if   [ "$_ram" -ge 3500 ]; then check "memory" ok   "${_ram} MB"
elif [ "$_ram" -ge 1800 ]; then check "memory" warn "${_ram} MB" "ClamAV + rspamd + MariaDB are tight below ~4 GB"
else                            check "memory" fail "${_ram} MB" "at least 2 GB is required; 4 GB recommended"
fi

_disk=$(df -Pm / | awk 'NR==2{print $4}')
if   [ "$_disk" -ge 15000 ]; then check "disk space" ok   "$((_disk/1024)) GB free on /"
elif [ "$_disk" -ge 8000 ];  then check "disk space" warn "$((_disk/1024)) GB free on /" "ClamAV signatures alone are ~1 GB and grow"
else                              check "disk space" fail "$((_disk/1024)) GB free on /" "at least 8 GB free is required"
fi

command -v apt-get >/dev/null 2>&1 && check "package manager" ok "apt" \
  || { command -v dnf >/dev/null 2>&1 && check "package manager" ok "dnf" \
       || check "package manager" fail "neither apt-get nor dnf found" "unsupported platform"; }

# -- leftovers that have actually broken installs before
_prev=""
for d in /etc/postfix /etc/dovecot /etc/rspamd /var/lib/mysql /data/mail; do
    [ -e "$d" ] && _prev="$_prev $d"
done
[ -z "$_prev" ] && check "previous install" ok "none detected" \
    || check "previous install" warn "existing:$_prev" "deploy.sh backs up before overwriting, but a wipe is cleaner"

# A dangling symlink here makes 25-dovecot's bootstrap certificate fail, after
# which the next package postinst that restarts dovecot aborts the module with
# a misleading "apt install failed" error. Cost a full install on 2026-08-26.
_dangle=0
for f in /etc/ssl/ilexa/*; do
    [ -L "$f" ] && [ ! -e "$f" ] && _dangle=$((_dangle+1))
done 2>/dev/null
[ "$_dangle" -eq 0 ] && check "TLS cert paths" ok "no dangling symlinks" \
    || check "TLS cert paths" fail "$_dangle dangling symlink(s) in /etc/ssl/ilexa" \
             "rm -rf /etc/ssl/ilexa   (they point at a removed /etc/letsencrypt)"

if [ -f /var/lib/dpkg/lock-frontend ] && command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    check "package system" warn "dpkg lock is held right now" "usually unattended-upgrades; the installer waits up to 10 min"
else
    check "package system" ok "no lock held"
fi

# -- DNS, the part that decides whether TLS and mail actually work.
# Skipped in wizard mode: there is no name to look up until the operator types
# one. deploy.sh runs its own DNS check afterwards, with an Exit/Skip/Retry
# dialog, so nothing is lost -- it just happens a few screens later.
if [ "$WIZARD" = 1 ]; then
    check "DNS" warn "not checked yet" "the wizard asks for the FQDN, then deploy.sh checks it"
else
_mine=" $(hostname -I 2>/dev/null || true) "
_a="$(_dns_a "$FQDN" | tr '\n' ' ' | sed 's/ $//')"
_here=0
for _ip in $_a; do case "$_mine" in *" $_ip "*) _here=1 ;; esac; done
if   [ -z "$_a" ];    then check "DNS: $FQDN" fail "does not resolve" "create an A record pointing at this host before requesting a certificate"
elif [ "$_here" = 1 ]; then check "DNS: $FQDN" ok "$_a (this host)"
else                       check "DNS: $FQDN" fail "$_a — not this host ($(echo "$_mine" | xargs))" \
                                 "Let's Encrypt cannot validate a name that points elsewhere"
fi

_mx="$(command -v dig >/dev/null 2>&1 && dig +short MX "$DOMAIN" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ' || echo '')"
[ -n "$_mx" ] && check "DNS: MX $DOMAIN" ok "$_mx" \
    || check "DNS: MX $DOMAIN" warn "no MX record" "inbound mail needs  MX $DOMAIN -> $FQDN"

_ptr="$(command -v dig >/dev/null 2>&1 && dig +short -x "${_a%% *}" 2>/dev/null | head -1 || echo '')"
[ -n "$_ptr" ] && check "DNS: PTR" ok "${_ptr%.}" \
    || check "DNS: PTR" warn "no reverse record" "most large providers reject mail from hosts without a PTR"

fi
# -- outbound 25: silently blocked by most cloud providers, and a mail server
#    that cannot reach port 25 is useless. Worth knowing BEFORE installing.
if command -v timeout >/dev/null 2>&1 && timeout 6 bash -c 'cat < /dev/null > /dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    check "outbound port 25" ok "reachable"
else
    check "outbound port 25" warn "blocked or unreachable" \
          "most VPS providers block 25 by default — ask them to unblock, or outbound mail will not work"
fi

_t="$(command -v timedatectl >/dev/null 2>&1 && timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '')"
[ "$_t" = "yes" ] && check "clock sync" ok "NTP synchronised" \
    || check "clock sync" warn "not confirmed" "DKIM signatures and TLS are time-sensitive"

# -- TLS decision, made from the DNS facts above. The wizard asks for TLS
# itself, and there are no DNS facts to decide from before it has a name.
if [ "$WIZARD" = 1 ]; then
    check "TLS mode" ok "asked by the wizard"
else
case "$TLS" in
    letsencrypt|selfsigned) check "TLS mode" ok "$TLS (forced)" ;;
    auto)
        if [ "$_here" = 1 ]; then TLS=letsencrypt; check "TLS mode" ok "letsencrypt (name points here)"
        else TLS=selfsigned;      check "TLS mode" warn "selfsigned (name does not point here)" \
                                        "point DNS here first if you want a real certificate"
        fi ;;
    *) die "--tls must be letsencrypt, selfsigned or auto" ;;
esac
fi

printf '\n  %d check(s) failed, %d warning(s)\n' "$FAILS" "$WARNS"

if [ "$FAILS" -gt 0 ] && [ "$FORCE" != 1 ]; then
    die "$FAILS check(s) failed. Fix them, or re-run with --force to continue anyway."
fi
[ "$CHECK_ONLY" = 1 ] && { printf '\n  --check given: stopping here, nothing was modified.\n\n'; exit 0; }

# ── Phase 2: PLAN ─────────────────────────────────────────────────────────────
step "2/3  What will happen"
if [ "$WIZARD" = 1 ]; then
    banner "ilexa installer" "interactive wizard" "the questions come next; nothing is written until you approve them"
else
    banner "ilexa installer" "$FQDN" "domain $DOMAIN · admin $EMAIL · TLS $TLS"
fi
cat <<PLAN
$([ "$WIZARD" = 1 ] && printf '  FQDN            asked by the wizard\n  Mail domain     asked by the wizard\n  Admin address   asked by the wizard\n  TLS             asked by the wizard' \
                    || printf '  FQDN            %s\n  Mail domain     %s\n  Admin address   %s\n  TLS             %s' "$FQDN" "$DOMAIN" "$EMAIL" "$TLS")
  Source          $SRC_DIR ($REF)
  Answers         $([ "$WIZARD" = 1 ] && echo '(none — the wizard collects them)' || echo "$ANSWERS_OUT")
  Action          $([ "$DRY_RUN" = 1 ] && echo 'DRY RUN (no changes)' || echo "$MODE")

  Installs Postfix, Dovecot, rspamd, ClamAV, MariaDB, Apache, PostfixAdmin,
  Roundcube and the ilexa console, then hardens and verifies the result.
  Expect 10-20 minutes. Two steps are slow and look stuck but are not:

    35-clamav     up to 10 min   downloading virus signatures
    25-dovecot    1-3 min        building the full-text search index plugin

  Package prompts are pre-answered, so nothing will wait for input.
PLAN
if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ] && { true >/dev/tty; } 2>/dev/null; then
    printf '\n  This overwrites mail, web and database configuration. Continue? [y/N] '
    read -r _a < /dev/tty || _a=""
    case "$_a" in y|Y|yes|YES) ;; *) die "aborted by operator" ;; esac
fi

# ── Phase 3: INSTALL ──────────────────────────────────────────────────────────
step "3/3  Installing"

say "fetching the installer ..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    # DPkg::Lock::Timeout is not politeness, it is the difference between
    # working and not on a box that booted minutes ago. unattended-upgrades
    # runs on first boot and holds the dpkg frontend lock for minutes; apt does
    # not wait by default, it fails after ~3 seconds. lib/common.sh has carried
    # this for the module path since 2026-08-17, but these two bootstrap calls
    # were written without it and died before the repository was even cloned:
    #
    #   E: Could not get lock /var/lib/dpkg/lock-frontend.
    #      It is held by process 1170 (unattended-upgr)
    #
    # Caught on a reimaged host four minutes after boot -- the exact case the
    # preflight above had just WARNED about, and then failed on regardless.
    # A warning the code does not act on is decoration.
    _apt() { apt-get -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" "$@"; }
    say "waiting for any first-boot package activity to finish ..."
    _apt update -qq
    _apt install -y -qq git ca-certificates >/dev/null
else
    dnf -y -q install git ca-certificates >/dev/null
fi

# Modules chown parts of the filesystem to the web user; if that ever touches
# this checkout, git refuses to operate on it ("dubious ownership").
git config --global --get-all safe.directory 2>/dev/null | grep -qx "$SRC_DIR" \
    || git config --global --add safe.directory "$SRC_DIR"

if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" remote set-url origin "$REPO"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$REF"
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
else
    rm -rf "$SRC_DIR"
    git clone -q --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
        || git clone -q --depth 1 "$REPO" "$SRC_DIR"
fi
[ -f "$SRC_DIR/deploy.sh" ] || die "$SRC_DIR/deploy.sh missing — repository layout unexpected"
say "ilexa $(sed -n 's/.*"latest": "\([^"]*\)".*/\1/p' "$SRC_DIR/RELEASES.json" 2>/dev/null || echo unknown) in $SRC_DIR"

# In wizard mode nothing is written here at all. deploy.sh collects every
# answer interactively and records the effective set to
# /var/lib/ilexa-install/answers.effective afterwards. Copying the CI base
# profile over /root/answers.conf regardless left a file full of
# example.com placeholders that nothing ever corrected -- and a later
# `deploy.sh --only <module> --answers /root/answers.conf` would then
# happily deploy the placeholder domain. It also made the plan screen's
# "Answers  (none -- the wizard collects them)" a lie.
if [ "$WIZARD" = 0 ]; then
say "writing $ANSWERS_OUT ..."
BASE="$SRC_DIR/ci/answers.compat.conf"
[ -f "$BASE" ] || die "$BASE missing"
[ -f "$ANSWERS_OUT" ] && cp -a "$ANSWERS_OUT" "${ANSWERS_OUT}.$(date +%Y%m%d-%H%M%S).bak"
cp "$BASE" "$ANSWERS_OUT"
_set() { # key value
    local k="$1" v="$2" esc
    esc=$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')
    if grep -qE "^${k}=" "$ANSWERS_OUT"; then sed -i "s|^${k}=.*|${k}=${esc}|" "$ANSWERS_OUT"
    else printf '%s=%s\n' "$k" "$v" >> "$ANSWERS_OUT"; fi
}
_set MAIL_FQDN "$FQDN"; _set PRIMARY_DOMAIN "$DOMAIN"
_set ADMIN_EMAIL "$EMAIL"; _set ALERT_EMAIL "$EMAIL"
_set TLS_MODE "$TLS"
# The base file is the CI profile, and CI pins TIMEZONE=UTC for determinism.
# A real host must NOT inherit that: blanking it here lets deploy.sh fill in
# whatever the box is already set to, so the one-liner never silently moves
# the clock. (The same bug was already fixed in answers.example.conf; this
# entry point takes its answers from the CI file instead and kept it alive.)
_set TIMEZONE ""
# webroot, not standalone: 50-web has already started the web server by the time
# 75-tls-dns runs, so --standalone cannot bind :80 on a fresh install.
[ "$TLS" = letsencrypt ] && _set CERTBOT_METHOD webroot
fi

cd "$SRC_DIR"
TOTAL=$(ls modules/*.sh 2>/dev/null | wc -l)

# Build the command without running it, so verbose and quiet share one definition.
if   [ "$WIZARD" = 1 ] && [ "$DRY_RUN" = 1 ]; then CMD=(bash deploy.sh --dry-run)
elif [ "$WIZARD" = 1 ];        then CMD=(bash deploy.sh)
elif [ "$DRY_RUN" = 1 ];        then CMD=(bash deploy.sh --dry-run --answers "$ANSWERS_OUT")
elif [ "$MODE" = acceptance ]; then CMD=(bash ci/run-acceptance.sh "$ANSWERS_OUT")
else                               CMD=(bash deploy.sh --answers "$ANSWERS_OUT")
fi

# The wizard owns the terminal: whiptail needs a real tty on stdin, and under
# "curl | bash" stdin is the script. Redirect from /dev/tty and run deploy.sh
# directly -- the quiet renderer below filters output line by line, which would
# eat the dialogs whole.
if [ "$WIZARD" = 1 ]; then
    say "handing over to the wizard"
    echo
    "${CMD[@]}" < /dev/tty
    exit $?
fi

if [ "$VERBOSE" = 1 ]; then
    say "verbose: every line shown; full log also in /var/log/ilexa-install.log"
    echo
    "${CMD[@]}"
    exit $?
fi

# ── Quiet renderer ────────────────────────────────────────────────────────────
# deploy.sh is loud by design -- module logs plus raw apt/dpkg output. That is
# the right default for a log file and the wrong one for a person watching an
# install: the signal (which module, did it work) is buried. Filter to one line
# per module here rather than making deploy.sh quieter, because deploy.sh is
# also driven by ci/run-acceptance.sh and by operators re-running single
# modules, and both want the full stream.
#
# Nothing is discarded: deploy.sh writes everything to /var/log/ilexa-install.log
# regardless, and on failure the tail of that file is printed automatically --
# quiet mode must never leave someone with a bare "failed" and no context.
say "installing — full log: /var/log/ilexa-install.log"
echo
LOG=/var/log/ilexa-install.log
START=$(date +%s)
CUR="" CUR_T=0 DONE=0 MOD_WARN=0 FAILED=""

_close() { # glyph colour
    [ -n "$CUR" ] || return 0
    local el=$(( $(date +%s) - CUR_T )) extra=""
    [ "$MOD_WARN" -gt 0 ] && extra=" ${C_Y}${G_WARN}${MOD_WARN}${C_0}"
    printf '\r%s  %s[%2d/%2d]%s %-22s %s%s%s %s%3ds%s%s\n' "$C_EL" \
        "$C_DIM" "$DONE" "$TOTAL" "$C_0" "$CUR" "$2" "$1" "$C_0" "$C_DIM" "$el" "$C_0" "$extra"
    CUR="" MOD_WARN=0
}

set +e
"${CMD[@]}" 2>&1 | while IFS= read -r line; do
    case "$line" in
        # --acceptance runs deploy TWICE (install, then an idempotency re-run)
        # and interleaves seven check phases. Without these cases the module
        # counter sails past its total on the second pass and the PASS/FAIL
        # lines -- which are the entire point of an acceptance run -- are
        # filtered out as noise.
        "====="*)
            _close "$G_OK" "$C_G"
            DONE=0
            printf '\n  %s%s %s%s\n' "$C_B" "$G_RUN" \
                "$(printf '%s' "$line" | sed -E 's/^=+ *//; s/ *=+$//')" "$C_0"
            ;;
        "PASS: "*)
            printf '      %s%s%s %s\n' "$C_G" "$G_OK" "$C_0" "${line#PASS: }" ;;
        "FAIL: "*)
            printf '      %s%s %s%s\n' "$C_R" "$G_NO" "${line#FAIL: }" "$C_0" ;;
        # No counter kept here: this loop is the right-hand side of a pipe and
        # runs in a subshell, so anything it tallies is gone by the summary.
        # $RC carries the verdict, and each FAIL line is printed as it arrives.
        "ACCEPTANCE:"*) _close "$G_OK" "$C_G" ;;
        *"=== module "*)
            _close "$G_OK" "$C_G"
            CUR=$(printf '%s' "$line" | sed -n 's/.*=== module \([0-9]*-[0-9a-z-]*\) ===.*/\1/p')
            CUR=${CUR#*-}
            DONE=$((DONE+1)); CUR_T=$(date +%s)
            printf '  %s[%2d/%2d]%s %-22s %s%s running…%s' \
                "$C_DIM" "$DONE" "$TOTAL" "$C_0" "$CUR" "$C_DIM" "$G_RUN" "$C_0"
            ;;
        *"[WARN]"*)   MOD_WARN=$((MOD_WARN+1)) ;;
        *"[ERROR]"*)  FAILED="$CUR"; _close "$G_NO" "$C_R"
                      printf '  %s%s %s%s\n' "$C_R" "$G_NO" "${line#*\[ERROR\] }" "$C_0" ;;
        *"deploy complete"*)      _close "$G_OK" "$C_G" ;;
        *"verification passed"*)  : ;;
    esac
done
RC=${PIPESTATUS[0]}
set -e

# The loop above ran in a subshell (right-hand side of a pipe), so anything it
# assigned -- FAILED included -- is gone by now. Recover the failing module from
# the log rather than from a variable that cannot survive.
# "|| true" is load-bearing under set -e: on a SUCCESSFUL run there is no
# "[ERROR] module ... failed" line, grep exits 1, and the script would die here
# -- swallowing the completion banner after a perfectly good install.
FAILED=$(grep -oE '\[ERROR\] module [0-9]+-[0-9a-z-]+ failed' "$LOG" 2>/dev/null | tail -1 | sed -E 's/.*module ([0-9]+-[0-9a-z-]+) failed/\1/') || true

ELAPSED=$(( $(date +%s) - START ))
echo
if [ "$RC" -eq 0 ] && [ "$MODE" = acceptance ]; then
    banner "ACCEPTANCE PASSED  ($((ELAPSED/60))m $((ELAPSED%60))s)" \
           "deployed, verified, and re-run clean for idempotency" \
           "console   https://${FQDN}/ilexa/" \
           "log       $LOG"
elif [ "$RC" -ne 0 ] && [ "$MODE" = acceptance ]; then
    printf '%s%s ACCEPTANCE FAILED%s\n\n' "$C_R" "$G_NO" "$C_0"
    say "the FAIL lines above are the checks that did not pass"
    say "full log: $LOG    re-run with -v to watch everything"
elif [ "$RC" -eq 0 ]; then
    banner "Install complete  ($((ELAPSED/60))m $((ELAPSED%60))s)" \
           "console   https://${FQDN}/ilexa/" \
           "login     /root/ilexa-install-credentials.txt" \
           "log       $LOG"
else
    printf '%s%s install failed%s%s\n\n' "$C_R" "$G_NO" "$C_0" "${FAILED:+ in $FAILED}"
    say "last 20 log lines:"
    tail -20 "$LOG" 2>/dev/null | sed 's/^/    /'
    echo
    say "full log: $LOG    re-run with -v to watch everything"
fi
exit "$RC"
