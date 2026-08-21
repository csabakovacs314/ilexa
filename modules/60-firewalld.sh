#!/usr/bin/env bash
# 60-firewalld — public zone, geoblock + otx_block ipsets, drop rich-rules.
# Port 25 (smtp) is DELIBERATELY never geo/otx-dropped (inbound mail from
# anywhere must reach postscreen); admin/web/mail-TLS ports are dropped.
source "$MD_ROOT/lib/common.sh"
# Webmin is not installed by this toolkit; only punch its port if it exists already.
if [ "${HARDEN_WEBMIN:-no}" = yes ] && [ -f /etc/webmin/miniserv.conf ]; then
  WEBMIN_OPEN=1
else
  WEBMIN_OPEN=""
fi
step_guard 60-firewalld || exit 0

pkg_install firewalld ipset
svc_enable firewalld

IPSET_DIR=/etc/firewalld/ipsets

# --- ipset headers (loaders populate the <entry> list) ---
# Only written when absent. These files hold the live <entry> list once a
# loader has run, so rendering them whole on a re-run resets them to empty:
# geoblock self-heals (load-countries.sh runs at the end of this module), but
# otx_block is only repopulated by load-otx.sh's cron, so a re-run would
# silently drop every currently-blocked OTX IP until that next scheduled run.
# Same rule as /etc/ilexa/geoblock.conf below -- re-running this module must
# never clobber state something else owns.
if [ ! -s "$IPSET_DIR/geoblock.xml" ]; then
  write_file "$IPSET_DIR/geoblock.xml" 644 <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<ipset type="hash:net">
  <short>Geo-blocked networks</short>
  <description>ipdeny.com country zones, rebuilt by /usr/local/sbin/load-countries.sh</description>
  <option name="hashsize" value="65536"/>
  <option name="maxelem" value="100000"/>
</ipset>
EOF
else
  log_info "geoblock ipset already exists, keeping its current entries"
fi

if [ "$ENABLE_OTX" = yes ]; then
  if [ ! -s "$IPSET_DIR/otx_block.xml" ]; then
    write_file "$IPSET_DIR/otx_block.xml" 644 <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<ipset type="hash:net">
  <short>OTX malicious IPs</short>
  <description>AlienVault OTX IOC IPs, rebuilt from subscribed pulses by /usr/local/sbin/load-otx.sh</description>
  <option name="hashsize" value="4096"/>
  <option name="maxelem" value="131072"/>
</ipset>
EOF
  else
    log_info "otx_block ipset already exists, keeping its current entries"
  fi
fi

# --- public zone: services, ports, and our own drop rich-rules ---
# INCREMENTAL, deliberately not a whole-file render. This module used to
# generate all of public.xml from scratch, which silently deleted every
# rich-rule it does not itself produce. On the reference host that meant a
# re-run would have destroyed 15 live rules -- the spamhaus_drop,
# abuse_c2_block and community_N feed blocks written by 72-feeds.sh and the
# ilexa console, plus an operator's hand-added address block -- with no error
# and nothing to notice until traffic started getting through. Same bug class
# as the rbl.conf incident: a script assuming it exclusively owns a file that
# several other things legitimately write to.
#
# So: add what we need, remove only rules referencing OUR OWN ipsets
# (geoblock, otx_block) that are no longer wanted, and never touch anything
# else. One consequence, stated plainly because it is a real behaviour
# change: the zone is now "firewalld's defaults plus our additions" rather
# than a fully-declared file, so the stock ssh/dhcpv6-client services stay
# enabled instead of being stripped. That is deliberate -- asserting the
# whole zone is precisely what caused the bug.
fw_perm() { firewall-cmd --permanent --zone=public "$@" >/dev/null; }

# The managed drop-rules we want to exist, in firewall-cmd's own canonical
# formatting (must match --list-rich-rules output exactly for the add/remove
# comparisons below to work).
desired_rules() {
  local set t
  for set in geoblock ${otx_on:+otx_block}; do
    for t in http https imaps smtps smtp-submission pop3s; do
      printf 'rule family="ipv4" source ipset="%s" service name="%s" drop\n' "$set" "$t"
    done
    for t in "$SSH_PORT" ${WEBMIN_OPEN:+$WEBMIN_PORT}; do
      printf 'rule family="ipv4" source ipset="%s" port port="%s" protocol="tcp" drop\n' "$set" "$t"
    done
  done
}

# Ownership test for the removal pass. Both ipsets are listed unconditionally,
# regardless of ENABLE_OTX: turning OTX off must still clean up the otx_block
# rules this module previously added. Anything else -- another feature's
# ipset, an operator's hand-added rule -- is not ours and is left alone.
rule_is_managed() {
  local r="$1" s
  for s in geoblock otx_block; do
    case "$r" in *"ipset=\"$s\""*) return 0 ;; esac
  done
  return 1
}

otx_on=""
[ "$ENABLE_OTX" = yes ] && otx_on=1

if [ "$DRY_RUN" != 1 ]; then
  for _s in smtp smtps smtp-submission pop3s imaps http https; do
    fw_perm --add-service="$_s"
  done
  fw_perm --add-port="$SSH_PORT/tcp"
  # Only open Webmin's port if Webmin is actually present -- this toolkit never
  # installs it, and an open 10000 on a fresh box is an unnecessary target.
  [ -n "${WEBMIN_OPEN:-}" ] && fw_perm --add-port="$WEBMIN_PORT/tcp"
  [ "$ENABLE_SIEVE" = yes ] && fw_perm --add-port=4190/tcp

  _existing="$(firewall-cmd --permanent --zone=public --list-rich-rules 2>/dev/null)"
  _want="$(desired_rules)"

  while IFS= read -r _r; do
    [ -z "$_r" ] && continue
    grep -Fxq "$_r" <<<"$_existing" || { fw_perm --add-rich-rule="$_r" && log_info "firewalld: added $_r"; }
  done <<<"$_want"

  while IFS= read -r _r; do
    [ -z "$_r" ] && continue
    rule_is_managed "$_r" || continue          # not ours -> never remove
    grep -Fxq "$_r" <<<"$_want" || { fw_perm --remove-rich-rule="$_r" && log_info "firewalld: removed stale $_r"; }
  done <<<"$_existing"
else
  log_info "[dry-run] would ensure public-zone services/ports and $(desired_rules | wc -l) managed drop rules"
fi

# --- geoblock loader + weekly geoip refresh ---
# Country list lives in /etc/ilexa/geoblock.conf (admin-editable via the
# ilexa console's qa-geoblock-config.sh), seeded once here from
# GEOBLOCK_COUNTRIES. Re-running this module must never clobber a later
# admin edit, so only write if the file doesn't already exist.
if [ "$DRY_RUN" != 1 ] && [ ! -s /etc/ilexa/geoblock.conf ]; then
  mkdir -p /etc/ilexa
  {
    printf '# ilexa geoblock country list. ISO 3166-1 alpha-2, space-separated. Managed by qa-geoblock-config.sh.\n'
    printf '%s\n' "$GEOBLOCK_COUNTRIES"
  } > /etc/ilexa/geoblock.conf
  chmod 644 /etc/ilexa/geoblock.conf
elif [ "$DRY_RUN" != 1 ]; then
  log_info "geoblock: /etc/ilexa/geoblock.conf already exists, keeping current list (GEOBLOCK_COUNTRIES answer ignored)"
fi
render "$MD_TEMPLATES/firewalld/load-countries.sh.tmpl" /usr/local/sbin/load-countries.sh
[ "$DRY_RUN" != 1 ] && chmod 755 /usr/local/sbin/load-countries.sh
[ "$DRY_RUN" != 1 ] && install -m 755 "$MD_ASSETS/otx/update-geoip.sh" /usr/bin/update-geoip.sh

if [ "$DRY_RUN" != 1 ]; then
  firewall-cmd --reload >/dev/null 2>&1 || log_warn "firewall-cmd reload failed (check zone/ipset XML)"
  log_info "populating geoblock ipset (first run may take a moment)"
  /usr/local/sbin/load-countries.sh || log_warn "geoblock initial load failed (retry later)"
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

mark_done 60-firewalld
log_info "firewalld configured (otx_block=$ENABLE_OTX, port 25 open to all)"
