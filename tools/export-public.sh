#!/usr/bin/env bash
#
# Export a clean public-release tree from this (private) repo.
#
# The private repo is the source of truth and keeps its full history; the
# public repo gets fresh history built from these exports. Reason: the
# private history contains internal operational material (PLAN.md documents
# the reference host's live hardening, including an admin source IP) that no
# amount of working-tree cleanup removes from old commits. Exporting a tree
# and committing it into a separate public repo is the only path with zero
# history-leak risk, and this script makes that repeatable instead of a
# one-off hand-copy that would drift.
#
#   tools/export-public.sh <dest-dir>
#
# The destination must be empty or not exist. After export, a secrets gate
# greps the RESULT (not the source) for the specific things audited out of
# the public tree on 2026-08-21, and deletes the whole export if any hits --
# a partial "public" tree with a known leak in it must not survive to be
# pushed by accident.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${1:?usage: export-public.sh <dest-dir>}"

if [ -e "$DST" ] && [ -n "$(ls -A "$DST" 2>/dev/null)" ]; then
    echo "export-public: $DST exists and is not empty -- refusing" >&2
    exit 1
fi
mkdir -p "$DST"

# Tracked files only (git ls-files): untracked scratch, .superpowers/ SDD
# state and editor droppings never reach the export. On top of that,
# PUBLIC_EXCLUDES lists tracked files that are deliberately private:
#   PLAN.md            historical plan for hardening the live reference host
#                      (names its admin source IP and security posture)
#   docs/superpowers/  internal design/plan documents for the same host
PUBLIC_EXCLUDES=(
    'PLAN.md'
    'docs/superpowers/*'
)

cd "$SRC"
git ls-files -z | while IFS= read -r -d '' f; do
    skip=0
    for pat in "${PUBLIC_EXCLUDES[@]}"; do
        # shellcheck disable=SC2254  # glob match against the pattern is the point
        case "$f" in $pat) skip=1; break ;; esac
    done
    [ "$skip" = 1 ] && continue
    install -D -m "$(stat -c '%a' "$f")" "$f" "$DST/$f"
done

# ── Secrets gate: audit findings must stay out of the export ─────────────────
# Patterns, not just literals: a NEW key/token pasted into a kept file since
# the last audit should also trip this. Hostname/provenance comments
# ("confirmed live on <host>") are allowed -- the reference host's identity
# is public DNS information; its admin IP and credentials are not.
fail=0
gate() { # description, then grep args
    local desc="$1"; shift
    local hits
    if hits="$(grep -rnE "$@" "$DST" 2>/dev/null | head -5)" && [ -n "$hits" ]; then
        echo "export-public: GATE FAILED -- $desc:" >&2
        printf '%s\n' "$hits" | sed 's/^/    /' >&2
        fail=1
    fi
}
gate "admin source IP from PLAN.md"        '51\.187\.243\.215'
gate "private key material"                'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
gate "GitHub token"                        'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
gate "Spamhaus DQS key shape"              '[a-z0-9]{26}\.(zen|dbl|zrd)\.'
gate "Abusix key shape"                    '[a-f0-9]{32}\.(combined|dblack|white)\.'
# The [N] keeps this pattern from matching its own exported copy (the same
# trick as `pgrep [f]oo`) while still matching the excluded file's heading.
gate "excluded file leaked through"        'harden hawking [N]OW'

if [ "$fail" = 1 ]; then
    rm -rf "$DST"
    echo "export-public: export DELETED -- fix the finding in the private repo and re-run" >&2
    exit 1
fi

count="$(find "$DST" -type f | wc -l)"
echo "export-public: $count files exported to $DST (gate clean)"
echo "Next (first publish only):"
echo "  cd $DST && git init -b main && git add -A"
echo "  git commit -m 'ilexa-installer: initial public release'"
echo "  git remote add origin <public-repo-url> && git push -u origin main"
echo "Next (subsequent releases): rsync this export over the public clone,"
echo "review 'git status', commit, push."
