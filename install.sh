#!/usr/bin/env bash
# install.sh — one-command bootstrap for the ilexa mail stack.
#
#   curl -fsSL https://raw.githubusercontent.com/csabakovacs314/ilexa/main/install.sh \
#     | bash -s -- --fqdn mail.example.org
#
# Everything else is derived or detected:
#   --domain   defaults to the FQDN minus its first label
#   --email    defaults to postmaster@<domain>
#   --tls      defaults to AUTO: letsencrypt when the FQDN already resolves to
#              this host, selfsigned otherwise (certbot cannot pass an HTTP-01
#              challenge for a name that does not point here, and a failed
#              issuance aborts the run mid-install)
#
# This is a thin bootstrapper: it installs git, fetches the repository, writes
# an answers file, and hands over to deploy.sh, which does the real work and
# has its own preflight, backups and verification. Nothing here modifies the
# system beyond installing git and writing the answers file.
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
DRY_RUN=0 ASSUME_YES=0

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

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
  --acceptance        run the full acceptance suite (deploy + verify + idempotency re-run)
  --dry-run           rehearse every module, change nothing
  --yes               skip the confirmation prompt
  --help              this text

Examples:
  install.sh --fqdn mail.example.org
  install.sh --fqdn mail.example.org --tls selfsigned --yes
  install.sh --fqdn mail.example.org --dry-run
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fqdn)   FQDN="${2:-}"; shift 2 ;;
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --email)  EMAIL="${2:-}"; shift 2 ;;
        --tls)    TLS="${2:-}"; shift 2 ;;
        --ref)    REF="${2:-}"; shift 2 ;;
        --acceptance) MODE="acceptance"; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
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
    local skip cmdline tok
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
if [ -z "$FQDN" ] && [ -r /dev/tty ]; then
    printf 'Mail server FQDN (e.g. mail.example.org): '
    read -r FQDN < /dev/tty || true
fi
[ -n "$FQDN" ] || die "--fqdn is required (no terminal available to prompt)"

case "$FQDN" in
    *.*.*|*.*) : ;;
    *) die "--fqdn must be a fully qualified name, e.g. mail.example.org" ;;
esac
printf '%s' "$FQDN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
    || die "--fqdn contains characters that are not valid in a hostname: $FQDN"
[ "$FQDN" != "mail.example.com" ] || die "mail.example.com is the placeholder the installer refuses; use the real name"

[ -n "$DOMAIN" ] || DOMAIN="${FQDN#*.}"
[ -n "$EMAIL" ]  || EMAIL="postmaster@${DOMAIN}"

case "$TLS" in
    letsencrypt|selfsigned) ;;
    auto)
        # Does the name already point at one of this host's own addresses?
        # getent uses the libc resolver, so this needs no extra package.
        _mine=" $(hostname -I 2>/dev/null || true) "
        _theirs="$(getent ahostsv4 "$FQDN" 2>/dev/null | awk '{print $1}' | sort -u)"
        TLS="selfsigned"
        for _ip in $_theirs; do
            case "$_mine" in *" $_ip "*) TLS="letsencrypt"; break ;; esac
        done
        ;;
    *) die "--tls must be letsencrypt, selfsigned or auto" ;;
esac

# ── Fetch ─────────────────────────────────────────────────────────────────────
step "Installing prerequisites"
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf -y -q install git ca-certificates >/dev/null
else
    die "no supported package manager found (need apt-get or dnf)"
fi
say "git $(git --version | awk '{print $3}')"

step "Fetching ilexa ($REF)"
# Modules chown parts of the filesystem to the web user; if that ever touches
# this checkout, git refuses to operate on it ("dubious ownership"). Declaring
# it safe up front keeps a re-run working instead of failing cryptically.
git config --global --get-all safe.directory 2>/dev/null | grep -qx "$SRC_DIR" \
    || git config --global --add safe.directory "$SRC_DIR"
if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" remote set-url origin "$REPO"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$REF"
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
    say "updated $SRC_DIR"
else
    rm -rf "$SRC_DIR"
    git clone -q --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
        || git clone -q --depth 1 "$REPO" "$SRC_DIR"
    say "cloned into $SRC_DIR"
fi
[ -f "$SRC_DIR/deploy.sh" ] || die "$SRC_DIR/deploy.sh missing — repository layout unexpected"
say "version $(sed -n 's/.*"latest": "\([^"]*\)".*/\1/p' "$SRC_DIR/RELEASES.json" 2>/dev/null || echo unknown)"

# ── Answers ───────────────────────────────────────────────────────────────────
step "Writing $ANSWERS_OUT"
BASE="$SRC_DIR/ci/answers.compat.conf"
[ -f "$BASE" ] || die "$BASE missing"
# Never silently overwrite an existing answers file.
if [ -f "$ANSWERS_OUT" ]; then
    cp -a "$ANSWERS_OUT" "${ANSWERS_OUT}.$(date +%Y%m%d-%H%M%S).bak"
    say "existing file backed up"
fi
cp "$BASE" "$ANSWERS_OUT"
_set() { # key value -- replace in place, or append when the key is absent
    local k="$1" v="$2"
    if grep -qE "^${k}=" "$ANSWERS_OUT"; then
        local esc; esc=$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')
        sed -i "s|^${k}=.*|${k}=${esc}|" "$ANSWERS_OUT"
    else
        printf '%s=%s\n' "$k" "$v" >> "$ANSWERS_OUT"
    fi
}
_set MAIL_FQDN      "$FQDN"
_set PRIMARY_DOMAIN "$DOMAIN"
_set ADMIN_EMAIL    "$EMAIL"
_set ALERT_EMAIL    "$EMAIL"
_set TLS_MODE       "$TLS"
# webroot, not standalone: 50-web has already started the web server by the
# time 75-tls-dns runs, so --standalone cannot bind :80 on a fresh install.
[ "$TLS" = letsencrypt ] && _set CERTBOT_METHOD webroot

# ── Confirm ───────────────────────────────────────────────────────────────────
cat <<SUMMARY

  FQDN            $FQDN
  Mail domain     $DOMAIN
  Admin address   $EMAIL
  TLS             $TLS
  Source          $SRC_DIR ($REF)
  Answers         $ANSWERS_OUT
  Action          $([ "$DRY_RUN" = 1 ] && echo 'DRY RUN (no changes)' || echo "$MODE")

SUMMARY
if [ "$TLS" = selfsigned ] && [ "$DRY_RUN" = 0 ]; then
    say "note: $FQDN does not resolve to this host, so a self-signed"
    say "      certificate is used. Point DNS here and re-run:"
    say "      $SRC_DIR/deploy.sh --only 75-tls-dns --answers $ANSWERS_OUT"
    echo
fi
if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -r /dev/tty ]; then
    printf 'This overwrites mail/web/database configuration. Continue? [y/N] '
    read -r _a < /dev/tty || _a=""
    case "$_a" in y|Y|yes|YES) ;; *) die "aborted by operator" ;; esac
fi

# ── Hand over ─────────────────────────────────────────────────────────────────
cd "$SRC_DIR"
if [ "$DRY_RUN" = 1 ]; then
    step "Dry run"
    exec bash deploy.sh --dry-run --answers "$ANSWERS_OUT"
elif [ "$MODE" = acceptance ]; then
    step "Deploy + verify + idempotency re-run"
    exec bash ci/run-acceptance.sh "$ANSWERS_OUT"
else
    step "Deploying"
    exec bash deploy.sh --answers "$ANSWERS_OUT"
fi
