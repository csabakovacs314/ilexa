#!/usr/bin/env bash
# Verifies that every answer-file key is actually wired all the way through.
#
# THE BUG CLASS THIS EXISTS FOR. deploy.sh hands answers to each module by
# way of a hand-maintained export list, not `set -a`. A new key therefore
# has to be added in THREE places to work:
#
#   1. answers.example.conf   so an operator knows it exists
#   2. apply_defaults()       so it has a value when the answers file omits it
#   3. export_config()        so the module subshell can actually see it
#
# Miss (3) and the key is silently ignored: the module reads the unexported
# default and behaves as if the operator never set anything. Nothing warns,
# nothing fails, and the feature simply does not happen. That is exactly what
# ENABLE_HU_CLASSIFY did on 2026-08-18 -- the module ran, said "disabled",
# and the answers file plainly said yes.
#
# Only (3) is reported. Missing (2) has two legitimate shapes -- a module
# that self-defaults, and an optional key whose unset state is correctly
# empty -- and an empty value fails loudly anyway, whereas a missing export
# fails silently. See the note at the check itself.
#
# Deliberately checks only KEYS THE MODULES CONSUME. A key that exists purely
# for deploy.sh's own use never reaches a subshell and does not need
# exporting, so those are listed as exempt below rather than reported forever.
#
# Usage: tools/check-answers.sh [--quiet]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
quiet=0; [ "${1:-}" = --quiet ] && quiet=1
fail=0

ANSWERS="$HERE/answers.example.conf"
DEPLOY="$HERE/deploy.sh"

# Keys deploy.sh consumes itself and never passes to a module subshell.
# Each is exempt for a stated reason, so the list cannot quietly become a
# dumping ground for "the check complained".
exempt_key() {
  case "$1" in
    # Read by load_answers/validate in deploy.sh's own process.
    MAIL_HOSTNAME|PRIMARY_DOMAIN|ADMIN_EMAIL|MAIL_FQDN) return 0 ;;
    # Consumed by lib/*.sh helpers sourced INTO each module, not exported.
    APT_LOCK_WAIT|CI_BOX) return 0 ;;
    *) return 1 ;;
  esac
}

[ -r "$ANSWERS" ] || { echo "check-answers: cannot read $ANSWERS" >&2; exit 2; }
[ -r "$DEPLOY" ]  || { echo "check-answers: cannot read $DEPLOY" >&2; exit 2; }

# The export_config() body, as flat text.
#
# apply_defaults() is deliberately NOT extracted: the check that would have
# consumed it was dropped on purpose (see the note in the loop below on why a
# missing default is not reportable), leaving an assignment nothing read -- a
# sed over deploy.sh executed on every lint for no result.
exports="$(sed -n '/^export_config()/,/^}/p' "$DEPLOY")"

n_checked=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  exempt_key "$key" && continue
  n_checked=$((n_checked + 1))

  # Is it consumed by any module at all? A key nothing reads is a
  # documentation-only entry and needs no wiring.
  if ! grep -rqE "\\\$\{?${key}[:\}-]|\\\$${key}\b" "$HERE/modules" 2>/dev/null; then
    continue
  fi

  if ! grep -qE "(^|[^A-Z_])${key}([^A-Z_]|$)" <<<"$exports"; then
    echo "  ANSWERS KEY NOT EXPORTED: $key is read by a module but missing from export_config() -- the module will silently see the default, not the operator's value"
    fail=1
  fi
  # A missing apply_defaults() entry is deliberately NOT reported. Two
  # legitimate patterns produce one: a module that supplies its own
  # `: "${KEY:=...}"` (70-otx does this for ENABLE_OTX_URI), and an
  # optional value whose correct unset state IS empty (TLS_CUSTOM_CERT
  # when TLS_MODE is not "custom"). Flagging those trains the operator to
  # ignore this gate, which costs more than the case it would catch --
  # an empty value surfaces loudly, whereas a missing EXPORT is silent.
done < <(grep -oE '^[A-Z][A-Z0-9_]*=' "$ANSWERS" | sed 's/=$//' | sort -u)

if [ "$fail" != 0 ]; then
  echo "check-answers: $n_checked keys checked, FAILED"
  exit 1
fi
[ "$quiet" = 1 ] || echo "check-answers: $n_checked answer keys, all module-consumed keys exported, clean"
exit 0
