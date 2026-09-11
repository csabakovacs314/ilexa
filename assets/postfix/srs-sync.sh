#!/bin/bash
# srs-sync -- keep SRS_EXCLUDE_DOMAINS in step with the hosted domains.
#
# WHY THIS EXISTS. postsrsd's exclude list is STATIC, written once at install
# time, but domains are added through PostfixAdmin for the life of the server.
# A hosted domain missing from that list gets its users' envelope sender
# rewritten on ordinary outbound mail: SPF then passes for the SRS domain but
# no longer ALIGNS with the From: header, so the sender loses SPF-based DMARC
# and their Return-Path reads as somebody else's domain. Nothing breaks loudly,
# which is exactly why it needs to be automated rather than remembered.
#
# Rewriting must apply ONLY to third-party senders we are relaying onward.
#
# Reads the domain list through Postfix's own read-only map credentials rather
# than taking a password of its own. Reloads postsrsd only when the list really
# changed, so it is safe to run from cron every day.
set -euo pipefail

CONF=/etc/default/postsrsd
MAPCF=/etc/postfix/sql/mysql_virtual_domains_maps.cf

[ -r "$CONF" ]  || { echo "srs-sync: $CONF not readable -- is postsrsd installed?" >&2; exit 0; }
[ -r "$MAPCF" ] || { echo "srs-sync: $MAPCF not readable" >&2; exit 1; }

val() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$MAPCF" | head -1; }
DB_USER=$(val user); DB_PASS=$(val password); DB_HOST=$(val hosts); DB_NAME=$(val dbname)
[ -n "$DB_USER" ] && [ -n "$DB_NAME" ] || { echo "srs-sync: could not read map credentials" >&2; exit 1; }
[ -n "$DB_HOST" ] || DB_HOST=localhost

# A defaults-file, not --password= or MYSQL_PWD: the first would expose the
# password in ps(1) to every local user, the second in /proc/<pid>/environ.
DEFAULTS=$(mktemp /tmp/.srs-sync.XXXXXX)
chmod 0600 "$DEFAULTS"
trap 'rm -f "$DEFAULTS"' EXIT
printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$DB_USER" "$DB_PASS" "$DB_HOST" >"$DEFAULTS"

# 'ALL' is PostfixAdmin's superadmin pseudo-domain, not a real one.
DOMS=$(mysql --defaults-file="$DEFAULTS" -N -B -e \
        "SELECT domain FROM \`$DB_NAME\`.domain WHERE domain <> 'ALL' ORDER BY domain;" 2>/dev/null \
      | tr '\n' ',' | sed 's/,$//')

[ -n "$DOMS" ] || { echo "srs-sync: domain query returned nothing -- leaving $CONF alone" >&2; exit 1; }

CUR=$(sed -nE 's/^SRS_EXCLUDE_DOMAINS=(.*)$/\1/p' "$CONF" | head -1)
if [ "$CUR" = "$DOMS" ]; then
    exit 0
fi

TMP=$(mktemp "${CONF}.XXXXXX"); chmod 0644 "$TMP"
if grep -qE '^SRS_EXCLUDE_DOMAINS=' "$CONF"; then
    sed -E "s|^SRS_EXCLUDE_DOMAINS=.*|SRS_EXCLUDE_DOMAINS=${DOMS}|" "$CONF" >"$TMP"
else
    cat "$CONF" >"$TMP"; printf 'SRS_EXCLUDE_DOMAINS=%s\n' "$DOMS" >>"$TMP"
fi
mv -f "$TMP" "$CONF"

echo "srs-sync: exclude list updated ($(printf '%s' "$DOMS" | tr ',' '\n' | grep -c .) domains)"
systemctl restart postsrsd >/dev/null 2>&1 \
    || echo "srs-sync: postsrsd restart failed -- new exclusions are NOT live" >&2
