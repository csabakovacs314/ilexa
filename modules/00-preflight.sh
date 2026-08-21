#!/usr/bin/env bash
# 00-preflight — refuse to run on an unsuitable host; warn on soft issues.
#
# Host-only checks (root, OS, RAM, ports, repos) live in lib/common.sh's
# preflight_host() so deploy.sh's main() can also run them before the
# interactive wizard starts, not just here. This module additionally checks
# what preflight_host() cannot: MAIL_FQDN/MAIL_STORE are answers, unset until
# the wizard or --answers file has run, so those two checks can only ever
# happen here (or wherever deploy.sh calls this module once answers exist),
# never earlier.
#
# Deliberately NO step_guard, unlike every other module: these are cheap,
# side-effect-free diagnostics, not a mutation worth skipping on a repeat
# run. A step_guard would use the marker file created by module 00's own
# mark_done below, and since that marker outlives a single deploy.sh
# invocation, guarding would make preflight silently stop re-verifying host
# state on every later run of this tool — the opposite of what this module
# exists to do. main() calls preflight_host a second time (before this
# module runs, in the interactive/--answers paths) for the same reason: it
# is meant to run every time, not once.
source "$MD_ROOT/lib/common.sh"

preflight_host
require_cmd awk grep sed getent 2>/dev/null || true

# FQDN resolves?
if ! getent hosts "$MAIL_FQDN" >/dev/null 2>&1; then
  log_warn "MAIL_FQDN $MAIL_FQDN does not resolve yet (set DNS + PTR before going live)"
fi

# OPTIONAL PREREQUISITE, reported here because here is the only point where
# acting on it is still cheap.
#
# With ENABLE_AUTOCONFIG or ENABLE_MTA_STS on, those features are served over
# HTTPS from names other than MAIL_FQDN, so the certificate has to cover them
# too. Let's Encrypt will only issue for a name that already resolves, and one
# name that does not resolve fails the ENTIRE order -- so 75-tls-dns omits any
# that are missing. That is safe, but it means the feature is installed and
# quietly broken until the records exist and the certificate is re-issued.
#
# Creating these CNAMEs BEFORE the install turns a two-pass job into one pass.
# Not creating them is fine and never blocks: it is a prerequisite, not a
# requirement, and 99-verify repeats what is still missing at the end.
if [ "${TLS_MODE:-}" != selfsigned ]; then
  pre_want=()
  [ "${ENABLE_MTA_STS:-no}" = yes ] && for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do pre_want+=("mta-sts.$d"); done
  [ "${ENABLE_AUTOCONFIG:-no}" = yes ] && for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do pre_want+=("autoconfig.$d" "autodiscover.$d"); done
  if [ ${#pre_want[@]} -gt 0 ]; then
    pre_missing=()
    for n in "${pre_want[@]}"; do
      getent hosts "$n" >/dev/null 2>&1 || pre_missing+=("$n")
    done
    if [ ${#pre_missing[@]} -gt 0 ]; then
      log_warn "optional prerequisite not met — these names do not resolve yet:"
      for n in "${pre_missing[@]}"; do log_warn "    $n   (CNAME -> $MAIL_FQDN)"; done
      log_warn "  They are only needed by ENABLE_AUTOCONFIG / ENABLE_MTA_STS, and the install continues without them."
      log_warn "  Creating them NOW, before this run reaches TLS, gets them into the certificate in one pass."
      log_warn "  Otherwise: create them later and re-run  ./deploy.sh --only 75-tls-dns --answers <this answers file>"
    else
      log_info "optional autoconfig/MTA-STS names all resolve — the certificate can cover them in this run"
    fi
    unset pre_missing
  fi
  unset pre_want n d
fi

# swap (fts_xapian wants it; 05-base adds a swapfile if short — reported here
# so both numbers are visible together even though RAM itself is checked in
# preflight_host())
swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
log_info "swap=$((swap_kb/1024))MB"

# disk space on the mail store parent
store_parent=$(dirname "$MAIL_STORE")
avail=$(df -Pm "$store_parent" 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$avail" ] && log_info "free space on $store_parent: ${avail}MB"

mark_done 00-preflight
log_info "preflight OK"
