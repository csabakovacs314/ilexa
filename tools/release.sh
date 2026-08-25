#!/usr/bin/env bash
# release.sh -- cut and publish one ilexa release.
#
# The one command a human (or an approved, deliberate automation run) uses
# to ship a new version: bundle the console app, compute its checksum and
# per-store migration high-water-marks, prepend an entry to RELEASES.json,
# sign the manifest, run the existing export-public.sh secrets gate, and
# rsync the result over the local /root/ilexa-public clone -- stopping
# short of commit/tag/push, which stay a deliberate, reviewed, separate
# step (this script prints the exact commands).
#
# Reads VERSION/CODENAME from the app repo as-is -- it does NOT bump them.
# Bump those two files by hand (or with a future --bump helper) before
# running this, so the version this cuts is always the one someone
# consciously wrote down.
#
# Usage:
#   tools/release.sh [--severity=feature|fix|security] [--requires-installer]
#                     [--min-upgrade-from=X.Y.Z] [--notes-hu=TEXT] [--notes-en=TEXT]
#
# Env overrides for testing: QA_RELEASE_APP_SRC, QA_RELEASE_KEY,
# QA_RELEASE_PUBLIC_DIR, QA_RELEASE_MANIFEST.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

APP_SRC="${QA_RELEASE_APP_SRC:-/root/quarantine-admin}"
KEY="${QA_RELEASE_KEY:-/root/.ilexa-release-keys/release-ed25519.pem}"
PUBLIC_DIR="${QA_RELEASE_PUBLIC_DIR:-/root/ilexa-public}"
MANIFEST="${QA_RELEASE_MANIFEST:-$HERE/RELEASES.json}"

severity="feature"; requires_installer="false"; min_upgrade_from=""
notes_hu=""; notes_en=""
for arg in "$@"; do
    case "$arg" in
        --severity=*)          severity="${arg#*=}" ;;
        --requires-installer)  requires_installer="true" ;;
        --min-upgrade-from=*)  min_upgrade_from="${arg#*=}" ;;
        --notes-hu=*)          notes_hu="${arg#*=}" ;;
        --notes-en=*)          notes_en="${arg#*=}" ;;
        *) echo "release.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
case "$severity" in feature|fix|security) ;; *) echo "release.sh: bad --severity: $severity" >&2; exit 2 ;; esac

[ -r "$KEY" ] || { echo "release.sh: signing key not readable: $KEY" >&2; exit 2; }
[ -d "$PUBLIC_DIR/.git" ] || { echo "release.sh: $PUBLIC_DIR is not a git clone" >&2; exit 2; }

if [ -n "$(git -C "$APP_SRC" status --porcelain 2>/dev/null)" ]; then
    echo "release.sh: $APP_SRC has uncommitted changes -- commit first for a reproducible release" >&2
    exit 1
fi

version="$(tr -d '[:space:]' < "$APP_SRC/VERSION")"
codename="$(tr -d '[:space:]' < "$APP_SRC/CODENAME")"
commit="$(git -C "$APP_SRC" rev-parse --short HEAD)"
[[ "$version" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4}$ ]] || { echo "release.sh: bad VERSION: $version" >&2; exit 1; }
[ -n "$codename" ] || { echo "release.sh: empty CODENAME" >&2; exit 1; }

if [ -f "$MANIFEST" ] && grep -q "\"version\": *\"$version\"" "$MANIFEST" 2>/dev/null; then
    echo "release.sh: $version is already in $MANIFEST -- bump VERSION first" >&2
    exit 1
fi

echo "release.sh: bundling $APP_SRC @ $commit ..."
bash "$HERE/tools/bundle-ilexa.sh" "$APP_SRC"

tarball="$HERE/assets/ilexa-app.tar.gz"
sha256="$(sha256sum "$tarball" | cut -d' ' -f1)"
size="$(stat -c%s "$tarball")"

echo "release.sh: computing per-store migration high-water-marks ..."
schema_json="$(php -r '
$dir = $argv[1];
$stores = ["mysql" => 0, "iocs" => 0, "logins" => 0];
foreach (glob($dir . "/[0-9][0-9][0-9][0-9]_*.sql") ?: [] as $path) {
    if (!preg_match("/^(\d{4})_/", basename($path), $m)) continue;
    $id = (int)$m[1];
    $raw = file_get_contents($path);
    if (!preg_match("/^--\s*store\s*:\s*(\w+)/mi", $raw, $sm)) continue;
    $store = $sm[1];
    if (isset($stores[$store]) && $id > $stores[$store]) $stores[$store] = $id;
}
echo json_encode($stores);
' "$APP_SRC/db/migrations")"

echo "release.sh: updating $MANIFEST ..."
php -r '
$manifestPath = $argv[1]; $version = $argv[2]; $codename = $argv[3]; $commit = $argv[4];
$sha256 = $argv[5]; $size = (int)$argv[6]; $severity = $argv[7];
$requiresInstaller = $argv[8] === "true"; $minUpgradeFrom = $argv[9];
$notesHu = $argv[10]; $notesEn = $argv[11]; $schemaJson = $argv[12];

$m = is_file($manifestPath)
    ? json_decode(file_get_contents($manifestPath), true)
    : ["schema" => 1, "serial" => 0, "channel" => "stable", "releases" => []];
if (!is_array($m)) { fwrite(STDERR, "release.sh: existing manifest does not parse\n"); exit(1); }

$entry = [
    "version" => $version, "codename" => $codename, "tag" => "v$version",
    "released_at" => gmdate("Y-m-d"), "commit" => $commit, "severity" => $severity,
    "requires_installer" => $requiresInstaller,
    "min_upgrade_from" => $minUpgradeFrom !== "" ? $minUpgradeFrom : "0.0.0",
    "schema_version" => json_decode($schemaJson, true),
    "app_tarball" => ["path" => "assets/ilexa-app.tar.gz", "sha256" => $sha256, "size" => $size],
    "notes_hu" => $notesHu, "notes_en" => $notesEn,
];
array_unshift($m["releases"], $entry);
$m["serial"] = (int)($m["serial"] ?? 0) + 1;
$m["latest"] = $version;
$m["generated_at"] = gmdate("Y-m-d\TH:i:s\Z");
$m["channel"] = $m["channel"] ?? "stable";
$m["schema"] = $m["schema"] ?? 1;

file_put_contents($manifestPath, json_encode($m, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
echo "release.sh: manifest serial now " . $m["serial"] . ", latest=$version\n";
' "$MANIFEST" "$version" "$codename" "$commit" "$sha256" "$size" "$severity" \
  "$requires_installer" "$min_upgrade_from" "$notes_hu" "$notes_en" "$schema_json"

echo "release.sh: signing manifest ..."
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$MANIFEST" -out "$MANIFEST.sig"
openssl pkeyutl -verify -pubin -inkey <(openssl pkey -in "$KEY" -pubout) \
    -rawin -in "$MANIFEST" -sigfile "$MANIFEST.sig" >/dev/null \
    || { echo "release.sh: FATAL -- signature failed to self-verify" >&2; exit 1; }

# export-public.sh exports `git ls-files` (tracked content only) from THIS
# repo -- an on-disk-but-uncommitted RELEASES.json/.sig would silently not
# reach the public tree at all. Committing here also gives the private repo
# its own full history of every release cut, for free.
if [ "$MANIFEST" = "$HERE/RELEASES.json" ]; then
    git -C "$HERE" add RELEASES.json RELEASES.json.sig assets/ilexa-app.tar.gz assets/ilexa-app.commit
    git -C "$HERE" commit -q -m "Cut release $version ($codename)"
    echo "release.sh: committed to $(basename "$HERE") @ $(git -C "$HERE" rev-parse --short HEAD)"
else
    echo "release.sh: MANIFEST override in use ($MANIFEST) -- skipping the ilexa-installer commit step (test mode)"
fi

echo "release.sh: exporting public tree ..."
export_tmp="$(mktemp -d)"; rmdir "$export_tmp"
bash "$HERE/tools/export-public.sh" "$export_tmp"

echo "release.sh: syncing export into $PUBLIC_DIR (no --delete; review before committing) ..."
rsync -a "$export_tmp/" "$PUBLIC_DIR/"
rm -rf "$export_tmp"

echo
echo "release.sh: done. $version ($codename) staged in $PUBLIC_DIR, not yet committed/pushed."
echo "Review, then:"
echo "  cd $PUBLIC_DIR"
echo "  git status"
echo "  git add -A"
echo "  git commit -m 'Release $version ($codename)'"
echo "  git tag v$version"
echo "  git push && git push --tags"
