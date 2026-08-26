#!/usr/bin/env bash
# check-footguns.sh — reject bash constructs that have caused real bugs here.
#
# None of these are flagged by shellcheck; each is valid bash that behaves
# differently from how it reads. Every rule below is a bug this project
# actually shipped or nearly shipped, dated, not a style preference. A rule
# only earns its place after something broke.
#
# A line carrying the marker "footgun-ok" is skipped entirely -- for the case a
# rule cannot express, where the author has judged it and said so in the code.
#
#   tools/check-footguns.sh          scan the repo
#   tools/check-footguns.sh <file>…  scan specific files
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [ $# -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(find modules lib assets templates tools -type f \
        \( -name '*.sh' -o -name '*.sh.tmpl' \) 2>/dev/null | sort
        find . -maxdepth 1 -type f -name '*.sh' | sort)
fi

fail=0
hit() { # file line rule explanation
    printf 'FOOTGUN %s:%s  %s\n         %s\n' "$1" "$2" "$3" "$4" >&2
    fail=1
}

# Scan CODE for one pattern -- comment bodies are stripped first.
#
# Without that, every rule fires on the comment that documents it: the very
# text warning "do not use pgrep -f" contains "pgrep -f". Caught while testing
# this script, which is the argument for testing a linter against the tree it
# is meant to police.
scan() { # file pattern rule explanation
    local f="$1" pat="$2" rule="$3" why="$4" ln
    case "$f" in *check-footguns.sh) return 0 ;; esac
    while IFS=: read -r ln _; do
        [ -n "$ln" ] && hit "$f" "$ln" "$rule" "$why"
    done < <(awk '{ if ($0 ~ /footgun-ok/) { print ""; next } sub(/[[:space:]]#.*$/, ""); sub(/^[[:space:]]*#.*$/, ""); print }' "$f" \
             | grep -nE "$pat" 2>/dev/null || true)
}

# The directive rule is separate: it inspects COMMENTS, and grep -E has no
# negative lookahead, so "is this a real directive?" cannot be expressed as one
# pattern. awk can say it plainly.
scan_directive() { # file
    local f="$1" ln
    case "$f" in *check-footguns.sh) return 0 ;; esac
    while IFS= read -r ln; do
        [ -n "$ln" ] && hit "$f" "$ln" 'comment starting with "shellcheck"' \
            'shellcheck parses it as a directive; reword so the line does not begin with that word'
    done < <(awk '
        /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]/ {
            w = $0; sub(/^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+/, "", w)
            if (w !~ /^(disable|enable|source|source-path|shell|external-sources)[=[:space:]]/) print NR
        }' "$f")
}

# tr maps BYTES. Any tr invocation carrying a non-ASCII byte is therefore
# mapping something it cannot represent -- "printf %62s | tr ' ' '─'" emitted
# one broken byte 62 times (2026-08-26). Tested byte-wise under LC_ALL=C,
# because in a UTF-8 locale the character class would match it as printable.
scan_tr() { # file
    local f="$1" ln
    case "$f" in *check-footguns.sh) return 0 ;; esac
    while IFS=: read -r ln _; do
        [ -n "$ln" ] && hit "$f" "$ln" 'tr with a multibyte argument' \
            'tr maps bytes, not characters; build repeated multibyte strings with a loop'
    # Byte test done in awk, not grep. "[\x80-\xff]" is NOT interpreted as byte
    # escapes by grep -E (it reads them literally), a printf-built range did not
    # match either, and this system's grep is ugrep, whose -P differs. awk
    # walking the line against a negated printable-ASCII class works everywhere.
    done < <(LC_ALL=C awk '
        /footgun-ok/ { next }
        /^[[:space:]]*#/ { next }
        /tr[ \t]/ {
            for (i = 1; i <= length($0); i++)
                if (substr($0, i, 1) ~ /[^ -~\t]/) { print NR ":"; break }
        }' "$f" 2>/dev/null || true)
}

for f in "${files[@]}"; do
    [ -r "$f" ] || continue

    # 2026-08-26: a comment explaining a shellcheck false alarm began with the
    # word "shellcheck" and was parsed as a directive -- SC1072/SC1073, a hard
    # error that made the file, and every module sourcing it, unparseable.
    # Cost two separate fixes in one sitting.
    scan_directive "$f"

    # 2026-08-26 (x2): pgrep -f matches any process whose command line merely
    # CONTAINS the string -- including the very shell running the check, when
    # invoked from a one-liner that names the script. Produced both a false
    # "already running" refusal and a false "still running" reading.
    # Only an UNANCHORED pattern is dangerous. A pattern containing a path
    # separator or an explicit boundary is the documented fix, not the bug:
    # lib/common.sh legitimately uses pgrep -f '/unattended-upgrade( |$)'
    # precisely because the naive bare word once matched an ssh session that
    # was investigating the problem.
    scan "$f" "pgrep[[:space:]]+-[a-z]*f[[:space:]]+['\"]?[A-Za-z0-9._|-]+['\"]?([[:space:]]|\$)" \
         'pgrep -f with an unanchored pattern' \
         'matches any cmdline containing the word, including your own; anchor with a path or boundary, or walk /proc'

    # 2026-08-26: `printf "%62s" "" | tr " " "─"` -- tr maps BYTES, and a box
    # character is 3 bytes in UTF-8, so it emitted one broken byte 62 times.
    scan_tr "$f"

    # 2026-08-26: `[ -r /dev/tty ]` passes on the device node even when the
    # process has no controlling terminal, so an unattended run fell into an
    # interactive prompt, failed the read, and logged the wrong reason.
    scan "$f" '\[[[:space:]]+-[rw][[:space:]]+/dev/tty[[:space:]]+\]' \
         'testing /dev/tty with -r/-w' \
         'that only checks permissions; use { true >/dev/tty; } 2>/dev/null to test openability'
done

if [ "$fail" = 0 ]; then
    echo "check-footguns: ${#files[@]} scripts checked -- clean"
else
    echo "check-footguns: FAILURES above" >&2
fi
exit "$fail"
