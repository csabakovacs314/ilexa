#!/usr/bin/env bash
# Repo-wide syntax + static-analysis gate: bash -n over every module/lib/asset
# script, plus shellcheck -x (which follows sourced files across modules/lib).
#
# Historically every check like this was manual, per-file, during whatever
# session touched that file -- nothing ran
# it across the whole tree, and nothing stopped a broken module from being
# executed mid-deploy. This script is the gate: deploy.sh runs it first and
# aborts before touching a live host if it fails.
#
# Exit 0 requires a CLEAN sweep. Exit 1: any bash -n syntax error, a missing
# path, or any finding at error OR warning severity.
#
# Warnings used to be tolerated ("today's baseline is 7, all reviewed as
# benign"), which is how a baseline dies: nobody re-reviews it, it drifts
# upward, and by 2026-08-26 it was 13 -- including an array/string name
# collision and a dead assignment nobody had looked at in months. Every one was
# then fixable in a single sitting. The intentional exemption, SC1090 on the
# dynamic `source "$MD_ROOT/lib/common.sh"` every module needs, is declared
# once in .shellcheckrc with its reasoning, so the gate can hold at zero
# instead of carrying a number that only ever grows.
#
#   tools/lint-all.sh            run the full sweep
#   tools/lint-all.sh --quiet    only print failures (for use from deploy.sh)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

# *.sh.tmpl too: these are shell scripts rendered to /usr/local/sbin, and they
# were invisible to this sweep purely because of the extension -- a syntax
# error in one would only surface when the rendered copy ran on a real host.
# @@KEY@@ placeholders parse as ordinary words, so bash -n/shellcheck handle
# them unrendered (verified against all four templates).
# tools/ is included deliberately. It was omitted for a long time, so ~900
# lines -- release.sh, export-public.sh, check-answers.sh and this script
# itself -- were never linted by the gate that claims to lint everything. Two
# real findings were sitting there undetected (a dead assignment, and a cd
# without || exit) and only surfaced when shellcheck was run by hand across
# git ls-files on 2026-08-26.
mapfile -t files < <(find modules lib assets templates tools -type f \( -name '*.sh' -o -name '*.sh.tmpl' \) 2>/dev/null | sort; find . -maxdepth 1 -type f -name '*.sh' | sort)

fail=0
syntax_fail=0
sc_errors=0
sc_warnings=0

for f in "${files[@]}"; do
  out="$(bash -n "$f" 2>&1)"
  if [ -n "$out" ]; then
    echo "SYNTAX ERROR: $f"
    echo "$out"
    syntax_fail=$((syntax_fail + 1))
    fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${files[@]}"; do
    res="$(shellcheck -x -S style -f gcc "$f" 2>&1)"
    [ -z "$res" ] && continue
    e="$(grep -c ' error:' <<<"$res")"
    w="$(grep -c ' warning:' <<<"$res")"
    sc_errors=$((sc_errors + e))
    sc_warnings=$((sc_warnings + w))
    if [ "$e" -gt 0 ]; then
      echo "SHELLCHECK ERROR: $f"
      grep ' error:' <<<"$res"
      fail=1
    elif [ "$quiet" != 1 ] && [ "$w" -gt 0 ]; then
      echo "shellcheck warning: $f"
      grep ' warning:' <<<"$res"
    fi
  done
else
  echo "lint-all: shellcheck not installed -- skipping static-analysis pass, bash -n only" >&2
fi

# ---- referenced templates and assets must exist ----------------------------
# A module that renders a template which is not there fails at RUN time, on a
# real host, halfway through an install -- and nothing else in this gate looks
# at paths. That is not hypothetical: commit 0071ad6 deleted a template and
# kept the reference, shipping an installer that could not run at all, and it
# was found only by a live run minutes later.
#
# $SRC is the extracted app bundle, so those references are checked against the
# app repo (the path bundle-ilexa.sh was last given, or the conventional one).
APP_SRC="${APP_SRC:-/root/quarantine-admin}"
path_fail=0
while read -r ref; do
  [ -n "$ref" ] || continue
  real="${ref/\$MD_TEMPLATES/templates}"
  real="${real/\$MD_ASSETS/assets}"
  if [ ! -e "$real" ]; then
    echo "MISSING TEMPLATE/ASSET: $ref  (looked for $real)"
    path_fail=$((path_fail + 1)); fail=1
  fi
done < <(grep -rhoE '\$(MD_TEMPLATES|MD_ASSETS)/[a-zA-Z0-9/._-]+' modules/ lib/ deploy.sh 2>/dev/null | sort -u)

if [ -d "$APP_SRC" ]; then
  while read -r ref; do
    [ -n "$ref" ] || continue
    real="${ref/\$SRC/$APP_SRC}"
    if [ ! -e "$real" ]; then
      echo "MISSING FROM APP REPO: $ref  (looked for $real)"
      path_fail=$((path_fail + 1)); fail=1
    fi
  done < <(grep -rhoE '\$SRC/install/[a-zA-Z0-9/._-]+' modules/ 2>/dev/null | sort -u)
elif [ "$quiet" != 1 ]; then
  echo "note: app repo not at $APP_SRC — skipped \$SRC/install path checks (set APP_SRC=)"
fi

echo
# Answer-key wiring: a key in answers.example.conf that a module reads but
# deploy.sh never exports is silently ignored -- the module sees the
# unexported default and the operator's setting does nothing. Caught
# ENABLE_UNOFFICIAL_SIGS on this gate's first run: it had been unexported
# (and therefore un-settable, from both the answers file and the wizard)
# for as long as it had existed.
ans_out="$("$HERE/tools/check-answers.sh" 2>&1)"; ans_rc=$?
if [ "$ans_rc" != 0 ]; then
  echo "$ans_out"
  fail=1
elif [ "$quiet" != 1 ]; then
  echo "$ans_out" | tail -1
fi

# Bash constructs that shellcheck accepts but that have bitten this project.
fg_out="$("$HERE/tools/check-footguns.sh" 2>&1)"; fg_rc=$?
if [ "$fg_rc" != 0 ]; then
  echo "$fg_out"
  fail=1
elif [ "$quiet" != 1 ]; then
  echo "$fg_out" | tail -1
fi

# The spam/ham report handler's sender gate decides who may train the Bayes
# classifier every user depends on. It was domain-level once, which let a
# forged local sender poison the filter; these cases pin the decision table and
# the two fail-closed paths.
rs_out="$("$HERE/tools/check-report-sender.sh" 2>&1)"; rs_rc=$?
if [ "$rs_rc" != 0 ]; then
  echo "$rs_out"
  fail=1
elif [ "$quiet" != 1 ]; then
  echo "$rs_out" | tail -1
fi

echo "lint-all: ${#files[@]} scripts checked -- $syntax_fail syntax errors, $sc_errors shellcheck errors, $sc_warnings shellcheck warnings, $path_fail missing paths"

[ "$fail" = 1 ] && exit 1
# A surviving warning is a failure. Anything genuinely acceptable belongs in
# .shellcheckrc with a written reason, not in an unwritten tolerance here.
[ "$sc_warnings" -gt 0 ] && { echo "lint-all: $sc_warnings shellcheck warning(s) -- fix them, or justify an exemption in .shellcheckrc" >&2; exit 1; }
exit 0
