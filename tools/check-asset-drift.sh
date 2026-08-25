#!/usr/bin/env bash
# Report drift between this repo's assets/ tree and the copies actually
# installed on THIS host.
#
# Why this exists: the modules install assets/ scripts, units and configs to
# /usr/local/sbin, /usr/bin, /etc/systemd/system and friends, then never look
# at them again. A hotfix applied to a live file never comes back here, and a
# fix committed here never reaches an already-built host -- in both directions,
# silently. The app repo's tools/check-sbin-drift.sh closes the same hole for
# quarantine-admin's install/ helpers, which are listed in helpers.list; these
# assets have no such manifest, so this walks the tree instead.
#
# The first run on the reference host found five divergences, four of them
# real and none previously visible: a systemd unit with duplicate [Unit]/
# [Service] sections from a botched append, a service still running as
# User=nobody after the repo had moved to DynamicUser (systemd-analyze flags
# the live one as unsafe), a shebang portability fix, and a cross-platform
# correctness fix for overlapping CIDR intervals that had never been applied.
#
# Matching is by BASENAME across a declared set of destination directories,
# not by parsing the modules' install lines: those use loop variables
# ("$MD_ASSETS/otx/$s") and variable destinations ($WWW, $MODELS), so static
# parsing would be fragile and would silently skip whatever it failed to
# resolve. A basename match in a known system directory is coarser but honest
# -- and it reports what it matched, so a false pairing is visible rather
# than assumed.
#
# Usage:
#   tools/check-asset-drift.sh            report drift, exit 1 if any
#   tools/check-asset-drift.sh --quiet    only print problems
#   tools/check-asset-drift.sh --verbose  also list matched-clean and unmatched
#
# Host-specific by nature, so deliberately NOT part of tools/lint-all.sh:
# that sweep is repo-internal (bash -n + shellcheck) and must stay runnable on
# any checkout, including CI, where none of these destinations exist.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || { echo "check-asset-drift: cannot cd to $HERE" >&2; exit 2; }

quiet=0 verbose=0
case "${1:-}" in
    --quiet)   quiet=1 ;;
    --verbose) verbose=1 ;;
esac

say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }

# Where the modules install things. Extend this list when a module starts
# installing an asset somewhere new -- an unlisted destination means that
# asset is silently unchecked, which is the exact failure this tool exists
# to end, so prefer adding a directory over leaving it out.
DESTS=(
    /usr/local/sbin
    /usr/bin
    /etc/systemd/system
    /etc/rspamd/lua.local.d
    /etc/rspamd/local.d
    /etc/rspamd/local.d/maps.d
    /opt/hu-classify
    /etc/sysconfig
)

# Files whose deployed copy is SUPPOSED to differ. Each entry needs a reason:
# an unexplained exception is indistinguishable from an unnoticed bug, and
# this list is the one place a real drift can hide forever.
is_expected_difference() {
    case "$1" in
        # The repo copy is genericised for distribution ("this mail server");
        # the deployed copy names the host it runs on. Keeping the host's
        # identity out of the public repo is deliberate -- see the public
        # export tooling (tools/export-public.sh) for the same concern.
        firewall-report.sh) return 0 ;;
        *) return 1 ;;
    esac
}

drift=0 clean=0 skipped=0 unmatched=0

while read -r f; do
    n="$(basename "$f")"

    if is_expected_difference "$n"; then
        skipped=$((skipped + 1))
        [ "$verbose" = 1 ] && printf '  expected-difference: %s\n' "$n"
        continue
    fi

    found=""
    for d in "${DESTS[@]}"; do
        [ -f "$d/$n" ] && { found="$d/$n"; break; }
    done

    if [ -z "$found" ]; then
        # Not installed on this host: normal (an optional feature that was
        # never enabled), so not counted as drift. --verbose lists them.
        unmatched=$((unmatched + 1))
        [ "$verbose" = 1 ] && printf '  not installed here: %s\n' "$f"
        continue
    fi

    if diff -q "$f" "$found" >/dev/null 2>&1; then
        clean=$((clean + 1))
        [ "$verbose" = 1 ] && printf '  ok: %s -> %s\n' "$n" "$found"
        continue
    fi

    # Direction changes the fix: "LIVE is newer" means a host hotfix this repo
    # never received (port it back); "REPO is newer" means a committed change
    # that never reached the host (install it). Do not guess -- say which.
    if [ "$found" -nt "$f" ]; then
        printf '  ASSET DRIFT: %s -- LIVE is newer (%s)\n' "$n" "$found"
        printf '               hotfixed on the host? port it back into %s\n' "$f"
    else
        printf '  ASSET DRIFT: %s -- REPO is newer (%s)\n' "$n" "$found"
        printf '               committed but never installed on this host\n'
    fi
    drift=1
done < <(find assets -type f \
            ! -name '*.tmpl' ! -name '*.pyc' ! -name '*.png' ! -name '*.gz' \
            ! -path '*/__pycache__/*' | sort)

if [ "$drift" = 0 ]; then
    say "check-asset-drift: $clean assets match this host ($skipped expected-difference, $unmatched not installed here) -- clean"
    exit 0
fi

echo "check-asset-drift: drift found (see above); $clean clean, $skipped expected-difference, $unmatched not installed here" >&2
exit 1
