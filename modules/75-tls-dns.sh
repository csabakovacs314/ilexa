#!/usr/bin/env bash
# 75-tls-dns — TLS certs (Let's Encrypt or self-signed) + unbound local resolver
# (127.0.0.1 first so postscreen can resolve the otx.rbl DNSBL zone).
source "$MD_ROOT/lib/common.sh"
step_guard 75-tls-dns || exit 0

pkg_install unbound

# --- unbound as local recursive resolver (PERSISTENTLY) ---
# A bare edit to /etc/resolv.conf is regenerated on reboot/DHCP-renew by
# NetworkManager, silently dropping the local resolver (postscreen then can't
# resolve otx.rbl). So when NM is present, tell it to stop managing resolv.conf
# (dns=none) and own the file ourselves; otherwise fall back to a direct edit.
svc_enable unbound
if [ "$DRY_RUN" != 1 ] && ! dig +short +time=2 +tries=1 dns.google @127.0.0.1 >/dev/null 2>&1; then
  log_warn "unbound not answering on 127.0.0.1 yet — leaving /etc/resolv.conf unchanged (postscreen otx.rbl needs it; fix unbound then re-run --only 75)"
elif [ "$DRY_RUN" != 1 ]; then
  write_resolv() {
    backup /etc/resolv.conf
    # Replace the symlink, never write THROUGH it. On Ubuntu /etc/resolv.conf
    # is a symlink to /run/systemd/resolve/stub-resolv.conf, and a plain
    # redirect corrupts that generated file instead of replacing the link --
    # which then breaks DNS for the whole host the moment unbound is removed
    # or stops, because resolved's own stub file no longer points at
    # 127.0.0.53. Observed for real while tearing a test host down
    # (2026-08-15): every name lookup failed and `systemctl restart
    # systemd-resolved` was needed to regenerate the clobbered file.
    rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf
    log_info "set 127.0.0.1 as the resolver in /etc/resolv.conf"
  }
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    write_file /etc/NetworkManager/conf.d/90-mail-dns.conf 644 <<'EOF'
# mail-deploy: NM must not manage /etc/resolv.conf — unbound (127.0.0.1) owns it.
[main]
dns=none
EOF
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
    write_resolv
  elif ! grep -qE '^\s*nameserver\s+127\.0\.0\.1\b' /etc/resolv.conf 2>/dev/null; then
    write_resolv
  fi
fi

# --- TLS ---
# SAN list: base FQDN + service subdomains (mta-sts./autoconfig./autodiscover.)
# so one cert covers the policy/autoconfig hosts. Each name must resolve for the
# ACME challenge; if the SAN issuance fails we retry FQDN-only so deploy proceeds.
# Resolve a name to its A/AAAA set. dig comes from bind9-dnsutils/bind-utils,
# installed by 05-base; getent is the fallback so this can never be the thing
# that breaks issuance.
_addrs_of() { # name
  local a
  a="$(dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+\.' | sort -u)"
  a="$a $(dig +short AAAA "$1" 2>/dev/null | grep -E ':' | sort -u)"
  a="$(printf '%s' "$a" | tr -s ' \n' '\n' | sed '/^$/d' | sort -u)"
  [ -n "$a" ] || a="$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)"
  printf '%s' "$a"
}

# Ask certbot ONLY for names that already point at this host.
#
# mta-sts, autoconfig and autodiscover are extra SANs, and on a first install
# their DNS records do not exist yet -- the installer prints the records to
# create at the END of the run, so on the very install that requests them the
# admin has not had the chance to add them. Let's Encrypt then fails the whole
# multi-name order ("Certbot failed to authenticate some domains"), and the
# FQDN-only retry is what actually issues. Observed on a fresh Ubuntu 24.04
# host 2026-08-17: every install logged an authentication failure that looked
# alarming and was in fact routine.
#
# Worse than the noise: a name that has since been pointed elsewhere would keep
# failing the order on every renewal, and renewals are unattended.
#
# So each optional name must resolve to an address MAIL_FQDN also resolves to
# before it is requested. Names that do not are skipped with an explicit line
# telling the operator what to create and that re-running picks it up -- rather
# than being silently dropped, which would leave Thunderbird and Outlook
# autoconfig failing on a certificate mismatch with nothing to explain why.
# Resolve a name against its zone's AUTHORITATIVE nameservers, bypassing the
# local resolver cache. Needed by the re-check prompt below: a name that was
# just looked up and did not exist is negatively cached (SOA minimum, often
# minutes), so an operator who adds the record and immediately re-checks would
# otherwise be told it still does not exist.
_addrs_authoritative() { # name
  local n="$1" zone ns a=""
  zone="${n#*.}"
  ns="$(dig +short NS "$zone" 2>/dev/null | head -1)"
  [ -n "$ns" ] || { _addrs_of "$n"; return; }
  a="$(dig +short A "$n" "@${ns%.}" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u)"
  a="$a $(dig +short AAAA "$n" "@${ns%.}" 2>/dev/null | grep -E ':' | sort -u)"
  printf '%s' "$(printf '%s' "$a" | tr -s ' \n' '\n' | sed '/^$/d' | sort -u)"
}

# The optional SAN names this configuration wants, one per line.
_wanted_optional_names() {
  local d
  [ "${ENABLE_MTA_STS:-no}" = yes ] && for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do echo "mta-sts.$d"; done
  [ "${ENABLE_AUTOCONFIG:-no}" = yes ] && for d in $PRIMARY_DOMAIN $EXTRA_DOMAINS; do echo "autoconfig.$d"; echo "autodiscover.$d"; done
  true
}

# Print the exact records the operator has to create, so the fix is in front of
# them at the moment they are asked about it -- not only in a notes file written
# at the end of the run, which is what made this a two-pass problem before.
_print_dns_fix() { # names...
  local n
  echo
  echo "  These names are not pointing at this host yet:"
  for n in "$@"; do echo "      $n"; done
  echo
  echo "  Create one CNAME per name, all pointing at the mail host."
  echo "  Most DNS panels want just the LABEL in the name field:"
  printf '      %-14s %-30s %s\n' "TYPE" "NAME (label)" "TARGET"
  for n in "$@"; do printf '      %-14s %-30s %s\n' "CNAME" "${n%%.*}" "$MAIL_FQDN"; done
  echo "      (full names: $*)"
  echo
  echo "  In Cloudflare set them to DNS-only (grey cloud); a proxied record"
  echo "  answers with Cloudflare's addresses and the check below will fail."
  echo
}

# Ask certbot ONLY for names that already point at this host.
#
# mta-sts, autoconfig and autodiscover are extra SANs whose DNS records rarely
# exist on a first install. Let's Encrypt fails the WHOLE multi-name order if
# any one of them cannot be authenticated ("Certbot failed to authenticate some
# domains"), and the FQDN-only retry is what actually issues -- so every fresh
# install logged an alarming-looking failure that was in fact routine (observed
# on Ubuntu 24.04, 2026-08-17).
#
# Worse than the noise: a name pointed elsewhere keeps failing the order on
# every renewal, and renewals are unattended.
#
# So each optional name must resolve to an address MAIL_FQDN also resolves to
# before it is requested. When some do not and a terminal is available, show
# the records to create and offer to re-check -- the certificate is issued once
# per run, and getting the names in on THIS pass avoids a second one.
build_cert_names() {
  local n host_addrs cand_addrs missing ans
  while :; do
    CERT_NAMES=(-d "$MAIL_FQDN")
    missing=()
    host_addrs="$(_addrs_of "$MAIL_FQDN")"
    for n in $(_wanted_optional_names); do
      cand_addrs="$(_addrs_of "$n")"
      if [ -z "$cand_addrs" ]; then
        missing+=("$n")
      elif [ -z "$(comm -12 <(printf '%s\n' $host_addrs | sort -u) <(printf '%s\n' $cand_addrs | sort -u))" ]; then
        log_warn "skipping $n in the certificate: it resolves elsewhere ($(printf '%s' "$cand_addrs" | tr '\n' ' ')) and not to this host ($(printf '%s' "$host_addrs" | tr '\n' ' ')). Requesting it would fail the whole order, including at renewal."
      else
        CERT_NAMES+=(-d "$n")
      fi
    done

    [ "${#missing[@]}" -gt 0 ] || return 0

    # No terminal (unattended run, cron, piped installer): keep the previous
    # behaviour exactly -- warn per name and carry on with an FQDN-only cert.
    #
    # The test must OPEN /dev/tty, not stat it: -r/-w only check permissions on
    # the device node, which pass even when the process has no controlling
    # terminal. Getting this wrong made an unattended run fall into the prompt,
    # fail the read, and log the wrong reason ("at the operator's request") for
    # a skip nobody was asked about.
    if ! { true >/dev/tty; } 2>/dev/null || [ "${MD_ASSUME_YES:-0}" = 1 ]; then
      for n in "${missing[@]}"; do
        log_warn "skipping $n in the certificate: it does not resolve yet. Create the DNS record shown at the end of this run (CNAME -> $MAIL_FQDN), then re-run --only 75-tls-dns to add it."
      done
      return 0
    fi

    _print_dns_fix "${missing[@]}" > /dev/tty
    printf '  [R] re-check DNS   [S] skip these names and continue  > ' > /dev/tty
    read -r ans < /dev/tty || ans=S
    case "$ans" in
      r|R|'')
        # Ask the authoritative servers, not the local cache, so a record added
        # seconds ago is actually seen.
        for n in "${missing[@]}"; do
          printf '      %-32s %s\n' "$n" "$(_addrs_authoritative "$n" | tr '\n' ' ' | sed 's/ $//' || true)" > /dev/tty
        done
        printf '\n' > /dev/tty
        continue ;;
      *)
        for n in "${missing[@]}"; do
          log_warn "skipping $n in the certificate at the operator's request. Create the CNAME later, then: ./deploy.sh --only 75-tls-dns --answers <answers file>"
        done
        return 0 ;;
    esac
  done
}
[ "$DRY_RUN" = 1 ] || install -d -m 755 "${TLS_DIR:-/etc/ssl/ilexa}"

# Point TLS_CERT/TLS_KEY at a certbot lineage via symlink. Renewal rewrites
# the lineage's own symlinks, so ours keep resolving to the current cert and
# nothing but a service reload is ever needed.
link_le_lineage() { # lineage_dir
  local live="$1"
  [ -s "$live/fullchain.pem" ] && [ -s "$live/privkey.pem" ] || return 1
  ln -sfn "$live/fullchain.pem" "$TLS_CERT"
  ln -sfn "$live/privkey.pem"   "$TLS_KEY"
  log_info "TLS: $TLS_CERT -> $live/fullchain.pem"
}

# ---- custom: the operator supplies their own certificate ------------------
# For anyone who already has a certificate -- a commercial one, a wildcard
# shared with other hosts, or one issued by an internal CA. Self-signed is a
# fallback, not a choice: no client accepts it.
#
# This validates hard and DIES rather than falling back. Quietly installing a
# self-signed cert over the operator's own would reproduce the exact failure
# this module was just fixed for: a green install that serves a certificate
# nobody accepts.
if [ "$TLS_MODE" = custom ] && [ "$DRY_RUN" != 1 ]; then
  src_cert="${TLS_CUSTOM_CERT:-}"; src_key="${TLS_CUSTOM_KEY:-}"
  [ -n "$src_cert" ] && [ -n "$src_key" ] \
    || die "TLS_MODE=custom needs TLS_CUSTOM_CERT and TLS_CUSTOM_KEY (paths to your certificate and its private key)"
  [ -s "$src_cert" ] || die "TLS_CUSTOM_CERT not found or empty: $src_cert"
  [ -s "$src_key" ]  || die "TLS_CUSTOM_KEY not found or empty: $src_key"

  openssl x509 -in "$src_cert" -noout >/dev/null 2>&1 \
    || die "TLS_CUSTOM_CERT is not a readable PEM certificate: $src_cert"
  openssl pkey -in "$src_key" -noout >/dev/null 2>&1 \
    || die "TLS_CUSTOM_KEY is not a readable PEM private key: $src_key (if it is encrypted, decrypt it first -- services start unattended and cannot be prompted for a passphrase)"

  # The key must belong to the cert. Mismatched pairs are a common paste error
  # and every service fails to start with an error that names neither file.
  c_hash="$(openssl x509 -in "$src_cert" -noout -pubkey 2>/dev/null | openssl sha256)"
  k_hash="$(openssl pkey -in "$src_key" -pubout 2>/dev/null | openssl sha256)"
  [ -n "$c_hash" ] && [ "$c_hash" = "$k_hash" ] \
    || die "TLS_CUSTOM_CERT and TLS_CUSTOM_KEY do not match -- that key did not sign that certificate"

  openssl x509 -in "$src_cert" -noout -checkend 0 >/dev/null 2>&1 \
    || die "TLS_CUSTOM_CERT has already expired ($(openssl x509 -in "$src_cert" -noout -enddate 2>/dev/null))"
  openssl x509 -in "$src_cert" -noout -checkend 2592000 >/dev/null 2>&1 \
    || log_warn "TLS_CUSTOM_CERT expires within 30 days ($(openssl x509 -in "$src_cert" -noout -enddate 2>/dev/null)) -- renewal is YOUR responsibility in custom mode, nothing here automates it"

  # Must actually cover this host, or clients get a name-mismatch warning --
  # which looks identical to "invalid certificate" to the person reporting it.
  if openssl x509 -in "$src_cert" -noout -ext subjectAltName 2>/dev/null | grep -qiE "DNS:${MAIL_FQDN}([^A-Za-z0-9.-]|$)"; then
    :
  elif openssl x509 -in "$src_cert" -noout -ext subjectAltName 2>/dev/null | grep -qiE 'DNS:\*\.'; then
    log_info "TLS_CUSTOM_CERT is a wildcard certificate -- assuming it covers $MAIL_FQDN"
  else
    die "TLS_CUSTOM_CERT does not list $MAIL_FQDN in its subjectAltName -- clients would report a name mismatch. Names present: $(openssl x509 -in "$src_cert" -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tail -1)"
  fi

  # A cert with no issuer chain validates on some clients and fails on others,
  # which is a miserable bug to chase. Warn, do not block: an internal CA that
  # is already in the trust store is legitimate.
  [ "$(grep -c 'BEGIN CERTIFICATE' "$src_cert")" -gt 1 ] \
    || log_warn "TLS_CUSTOM_CERT contains a single certificate and no intermediates -- if your CA issues a chain, concatenate it (server cert first) or some clients will report an incomplete chain"

  install -d -m 755 "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
  # Same reason as the self-signed path: writing through a symlink would
  # corrupt a certbot lineage.
  [ -L "$TLS_CERT" ] && rm -f "$TLS_CERT"
  [ -L "$TLS_KEY" ]  && rm -f "$TLS_KEY"
  install -m 0644 "$src_cert" "$TLS_CERT"
  install -m 0600 "$src_key"  "$TLS_KEY"
  rm -f "$MD_STATE_DIR/tls-bootstrap-placeholder.flag" "$MD_STATE_DIR/tls-selfsigned.flag"
  log_info "installed custom certificate: $(openssl x509 -in "$TLS_CERT" -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//'), expires $(openssl x509 -in "$TLS_CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

  # Same reload the letsencrypt path needs, and for the same reason: dovecot
  # and the web server hold the cert open from startup.
  for svc in postfix dovecot "${WEB_SVC:-httpd}"; do
    systemctl is-active --quiet "$svc" && systemctl reload "$svc" 2>/dev/null || true
  done
  unset src_cert src_key c_hash k_hash svc
fi

if [ "$TLS_MODE" = letsencrypt ]; then
  pkg_install certbot
  # Renewal is silent by default: certbot replaces the files but postfix,
  # dovecot and the web server keep serving the old cert until something
  # reloads them. Without this the certificate expires in production ~60 days
  # after a "successful" install.
  write_file /etc/letsencrypt/renewal-hooks/deploy/10-reload-mail.sh 0755 root:root <<HOOK
#!/bin/bash
# Installed by ilexa-installer. Reload every service that holds the TLS cert open.
for svc in postfix dovecot ${WEB_SVC:-httpd}; do
  systemctl is-active --quiet "\$svc" && systemctl reload "\$svc" 2>/dev/null || true
done
HOOK

  # Renewal must actually be ARMED. The unit name differs by platform and,
  # on EL, the package does NOT enable it (Debian's deb preset happens to,
  # but relying on that is how a cert silently expires on the other OS).
  if [ "$PKG_MGR" = apt ]; then certbot_timer=certbot.timer; else certbot_timer=certbot-renew.timer; fi
  svc_enable "$certbot_timer"

  if [ "$DRY_RUN" != 1 ]; then
    # A self-signed certificate is also "no real cert yet".
    #
    # Without this, switching TLS_MODE from selfsigned to letsencrypt and
    # re-running did NOTHING: the file exists and is not a symlink, so the
    # guard below skipped certbot outright and the host went on serving its
    # self-signed cert. Nothing reported a problem -- the module logged its
    # usual lines and exited 0. That is the exact situation after a first
    # install done before DNS pointed at the box, which is the normal order of
    # events when provisioning a new server.
    #
    # Detected by issuer == subject, which is what self-signed means; a
    # certbot lineage is a symlink and is caught by the -L test anyway.
    tls_selfsigned=0
    if [ -e "$TLS_CERT" ] && [ ! -L "$TLS_CERT" ]; then
      _iss="$(openssl x509 -in "$TLS_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=[[:space:]]*//')"
      _sub="$(openssl x509 -in "$TLS_CERT" -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//')"
      if [ -n "$_iss" ] && [ "$_iss" = "$_sub" ]; then
        tls_selfsigned=1
        log_info "existing certificate is self-signed ($_sub) — requesting a real one"
      fi
      unset _iss _sub
    fi

    # A bootstrap placeholder from 25-dovecot.sh means the file exists but
    # isn't a real cert -- treat that the same as "no cert yet" here.
    if [ ! -e "$TLS_CERT" ] || [ -L "$TLS_CERT" ] || [ "$tls_selfsigned" = 1 ] || [ -e "$MD_STATE_DIR/tls-bootstrap-placeholder.flag" ]; then
      build_cert_names

      # --standalone binds :80 itself, but 50-web already started the web
      # server on that port, so it fails with "Address already in use" on
      # EVERY fresh install -- verified live 2026-08-15. webroot is therefore
      # the default (see answers.example.conf); when standalone is asked for
      # explicitly, stop the web server around certbot and ALWAYS bring it
      # back, including on failure or Ctrl-C.
      if [ "$CERTBOT_METHOD" = webroot ]; then
        certbot_args=(--webroot -w /var/www/html)
      else
        certbot_args=(--standalone)
        if systemctl is-active --quiet "${WEB_SVC:-httpd}"; then
          log_info "stopping ${WEB_SVC:-httpd} for the standalone ACME challenge"
          trap 'systemctl start "${WEB_SVC:-httpd}" >/dev/null 2>&1 || true' EXIT INT TERM
          systemctl stop "${WEB_SVC:-httpd}"
          certbot_restart_web=1
        fi
      fi

      if certbot certonly "${certbot_args[@]}" "${CERT_NAMES[@]}" --cert-name "$MAIL_FQDN" \
        --non-interactive --agree-tos -m "$ADMIN_EMAIL" \
      || { log_warn "certbot SAN issuance failed — retrying FQDN-only"; \
           certbot certonly "${certbot_args[@]}" -d "$MAIL_FQDN" --cert-name "$MAIL_FQDN" \
             --non-interactive --agree-tos -m "$ADMIN_EMAIL"; }; then
        # certbot may land the lineage under a suffixed name if a previous
        # attempt left one behind; ask certbot where it actually put it
        # rather than assuming /etc/letsencrypt/live/$MAIL_FQDN.
        le_live="$(certbot certificates --cert-name "$MAIL_FQDN" 2>/dev/null \
                   | sed -n 's#.*Certificate Path: \(.*\)/fullchain.pem#\1#p' | head -1)"
        [ -n "$le_live" ] || le_live="/etc/letsencrypt/live/$MAIL_FQDN"
        if link_le_lineage "$le_live"; then
          rm -f "$MD_STATE_DIR/tls-bootstrap-placeholder.flag"
          # Reload everything that holds the cert open. Issuing and symlinking
          # is NOT enough on first install: dovecot and the web server read the
          # certificate at startup and keep serving whatever they loaded then,
          # so the box goes on presenting the self-signed bootstrap cert and
          # the browser still says "invalid certificate" -- after a certbot run
          # that succeeded and logged nothing wrong. Postfix hides the problem
          # further by spawning a fresh smtpd per connection, so SMTP picks the
          # new cert up on its own while HTTPS and IMAPS do not; measured
          # exactly that way on a fresh Ubuntu 24.04 box 2026-08-17 (SMTP: Let's
          # Encrypt, HTTPS + IMAPS: still self-signed).
          #
          # This is the same work the renewal deploy hook does, so run that hook
          # rather than a second copy of the list that can drift from it.
          if [ -x /etc/letsencrypt/renewal-hooks/deploy/10-reload-mail.sh ]; then
            /etc/letsencrypt/renewal-hooks/deploy/10-reload-mail.sh \
              && log_info "reloaded postfix/dovecot/${WEB_SVC:-httpd} onto the new certificate"
          fi
        else
          log_warn "certbot reported success but $le_live has no usable cert — using self-signed fallback"
        fi
      else
        log_warn "certbot failed — using self-signed fallback"
      fi

      if [ "${certbot_restart_web:-0}" = 1 ]; then
        systemctl start "${WEB_SVC:-httpd}" >/dev/null 2>&1 || log_warn "could not restart ${WEB_SVC:-httpd}"
        trap - EXIT INT TERM
      fi
    fi
  fi
fi

# Self-signed fallback (also the selfsigned mode) when there is still no
# usable cert, or all that's there is 25-dovecot's early bootstrap
# placeholder. -e follows symlinks, so a DANGLING symlink left by a failed
# certbot run reads as "not there" and is correctly replaced here.
rm -f "$MD_STATE_DIR/tls-selfsigned.flag" 2>/dev/null || true
if [ "$DRY_RUN" != 1 ] && { [ ! -e "$TLS_CERT" ] || [ -e "$MD_STATE_DIR/tls-bootstrap-placeholder.flag" ]; }; then
  [ "$TLS_MODE" = letsencrypt ] && log_warn "Let's Encrypt did NOT issue — falling back to a SELF-SIGNED cert (clients will see warnings)"
  log_info "generating self-signed certificate for $MAIL_FQDN"
  install -d -m 755 "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
  # Remove any symlink first: openssl would otherwise WRITE THROUGH it into
  # certbot's lineage directory, corrupting a real cert.
  [ -L "$TLS_CERT" ] && rm -f "$TLS_CERT"
  [ -L "$TLS_KEY" ]  && rm -f "$TLS_KEY"
  if openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
       -keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=$MAIL_FQDN" >/dev/null 2>&1; then
    chmod 644 "$TLS_CERT"; chmod 600 "$TLS_KEY"
    mkdir -p "$MD_STATE_DIR"; : > "$MD_STATE_DIR/tls-selfsigned.flag"   # surfaced by 99-verify
    rm -f "$MD_STATE_DIR/tls-bootstrap-placeholder.flag"
  else
    log_warn "self-signed generation failed"
  fi
fi

# --- expiry watchdog (both modes) -------------------------------------------
# Independent of certbot: it catches a renewal that silently stopped working,
# AND a self-signed cert nearing its 825-day end, which nothing else renews.
# Alerts through cron-alert.sh so a healthy cert stays silent.
[ "$DRY_RUN" = 1 ] || install -m 755 /dev/null /usr/bin/tls-expiry-check.sh
if [ "$DRY_RUN" != 1 ]; then
  cat > /usr/bin/tls-expiry-check.sh <<EOF
#!/bin/bash
# Installed by ilexa-installer. Warn while there is still time to act.
set -uo pipefail
CERT="$TLS_CERT"
WARN_DAYS=\${WARN_DAYS:-21}
[ -e "\$CERT" ] || { echo "TLS: \$CERT is MISSING" >&2; exit 1; }
end="\$(openssl x509 -in "\$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
[ -n "\$end" ] || { echo "TLS: cannot read expiry from \$CERT" >&2; exit 1; }
left=\$(( ( \$(date -d "\$end" +%s) - \$(date +%s) ) / 86400 ))
if [ "\$left" -lt 0 ]; then
  echo "TLS: \$CERT EXPIRED \$(( -left )) days ago (\$end)" >&2; exit 1
elif [ "\$left" -lt "\$WARN_DAYS" ]; then
  echo "TLS: \$CERT expires in \$left days (\$end)" >&2; exit 1
fi
exit 0
EOF
  chmod 755 /usr/bin/tls-expiry-check.sh
  # cron-alert.sh is normally installed by 70-otx.sh, but ONLY when
  # ENABLE_OTX=yes -- with OTX off the cron line below would fail every day
  # with "command not found". It is a generic wrapper (it just happens to
  # live under assets/otx/), so install it here too; writing the identical
  # file twice is harmless and makes this module self-sufficient.
  install -m 755 "$MD_ASSETS/otx/cron-alert.sh" /usr/bin/cron-alert.sh
fi
write_file /etc/cron.d/tls-expiry-check 644 <<'EOF'
# Daily TLS expiry watchdog. Silent while the cert is healthy; mails root
# once a day only when it is inside the warning window or already expired.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Deliberately empty: cron mails a job's OUTPUT to MAILTO, which would bypass
# the console's notification setting entirely. All alerting goes through
# cron-alert.sh, which reads /etc/ilexa/alerts.conf and stays silent until an
# address is configured in the Admin tab.
MAILTO=""
17 6 * * * root /usr/bin/cron-alert.sh tls-expiry /usr/bin/tls-expiry-check.sh
EOF

mark_done 75-tls-dns
log_info "tls ($TLS_MODE) + unbound resolver ready"
