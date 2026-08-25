#!/usr/bin/env bash
# Bundle the ilexa application into the installer so a fresh machine needs no
# access to the (private) app repository.
#
# There is one authoring source -- the app repo -- and this produces a snapshot
# of it. The commit hash travels with the bundle, so a drifted bundle is
# visible rather than silent: 55-ilexa logs the bundled commit at install time.
#
#   tools/bundle-ilexa.sh [/path/to/quarantine-admin]
set -euo pipefail

SRC="${1:-/root/quarantine-admin}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/assets/ilexa-app.tar.gz"
STAMP="$HERE/assets/ilexa-app.commit"

[ -d "$SRC/src" ] && [ -f "$SRC/index.php" ] || {
  echo "bundle-ilexa: $SRC does not look like the ilexa app" >&2; exit 1; }

# The update-check/apply pipeline reads these two files directly out of the
# bundle -- refusing here, before anything is written, is cheaper than a
# published release the version compare/dashboard silently mishandles.
ver="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || true)"
cname="$(tr -d '[:space:]' < "$SRC/CODENAME" 2>/dev/null || true)"
[[ "$ver" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4}$ ]] || {
  echo "bundle-ilexa: $SRC/VERSION ('$ver') is not valid semver (X.Y.Z)" >&2; exit 1; }
[ -n "$cname" ] || {
  echo "bundle-ilexa: $SRC/CODENAME is empty" >&2; exit 1; }

commit="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty=""
[ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] && dirty=" (uncommitted changes present)"

# Ship what the app's own deploy.sh would deploy, plus install/ (host helpers,
# which deploy.sh deliberately excludes) and INSTALL.md for reference.
#
# install/*.tmpl MUST ship. 55-ilexa.sh renders qa-doveadm.sh,
# htpasswd-manage.sh and fts-manage.sh from the app repo's own copies inside
# this bundle, so the app is the single source for every helper it shells out
# to -- which is also what lets it be installed onto a stack this toolkit did
# not build. Keeping a second copy of the gateway here is exactly how the two
# drifted: the installer's copy lost the hdr.received fetch field and every
# host it built had an empty sender_ip.
#
# config.php IS excluded, on purpose and not by oversight: 55-ilexa.sh always
# overwrites it from install/config.php.tmpl (in this bundle) right after extracting
# this bundle, so a bundled copy is never read -- and it carries this specific
# deployment's real domain and DB password, which have no business leaving the
# host. If a future file in the app repo starts carrying live site values the
# same way, exclude it here too rather than sanitizing after the fact.
#
# .superpowers/ and docs/ are excluded because tar does not honor .gitignore:
# those directories hold this repo's SDD execution scratch (ledgers, task
# briefs, review packages) and design specs/plans, never meant to leave the
# source repo, let alone reach the live webroot via 55-ilexa.sh's rsync.
# --owner/--group=0: the bundle must not carry the BUILD host's numeric
# ownership. This repo is authored on an EL box where apache is uid 48; a
# tarball recording uid 48 restores uid 48 on extraction, and on Debian that
# is not www-data (33) -- every file landed unreadable by the web server and
# the console returned "Permission denied" for index.php itself. 55-ilexa.sh
# also extracts with --no-same-owner and chowns explicitly, so this is the
# second of two independent guards: the artifact is neutral AND the install
# sets ownership deliberately.
tar -czf "$OUT" -C "$SRC" \
  --owner=0 --group=0 --numeric-owner \
  --exclude='.git' --exclude='__pycache__' --exclude='*.bak-*' \
  --exclude='config.php' \
  --exclude='.superpowers' --exclude='docs' \
  .
printf '%s\n' "$commit" > "$STAMP"

echo "bundled $SRC @ $commit$dirty"
echo "  -> $OUT ($(du -h "$OUT" | cut -f1))"
[ -n "$dirty" ] && echo "  WARNING: bundle taken from a dirty tree; commit first for a reproducible build" >&2
exit 0
