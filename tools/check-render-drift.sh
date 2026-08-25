#!/usr/bin/env bash
# Report drift between this repo's templates/ and the files render() actually
# produced on THIS host.
#
# Why this exists: tools/check-asset-drift.sh covers assets/ and explicitly
# skips *.tmpl, so the rendered half of the tree -- the half that carries
# rspamd's scoring, Postfix's main.cf and every multimap rule -- had no drift
# detection at all. That gap has already cost this project once: render()
# overwrites its destination unconditionally, so the Blocklist.de feed added
# directly to a live local.d/multimap.conf was silently destroyed by the next
# 40-rspamd run (2026-08-15). Nothing would have reported it before the mail
# stopped being filtered, and nothing reports the same shape today.
#
# Two comparisons, because "the files differ" is nearly always true and nearly
# never the point:
#
#   1. RULE-LEVEL (rspamd .conf targets only). Top-level block names present on
#      ONE side only. A block that exists only in the live file is the
#      Blocklist.de shape exactly: working today, gone at the next render. A
#      block that exists only in the template has never reached this host.
#      This is the high-signal check -- act on it first.
#   2. FUNCTIONAL LINES. Non-comment, non-blank lines that differ, reported as
#      a COUNT and a direction. Comments drift constantly and harmlessly (the
#      template accumulates the reasoning), so counting them would bury 1.
#
# This tool NEVER prints file content -- only names, counts and directions.
# That is deliberate and must stay true: the rendered set includes
# dovecot-sql.conf.ext, worker-controller.inc and the Roundcube/PostfixAdmin
# configs, which carry database passwords and a controller password hash.
# Block names and line counts leak nothing; a diff would.
#
# Usage:
#   tools/check-render-drift.sh            report drift, exit 1 if any
#   tools/check-render-drift.sh --quiet    only print problems
#   tools/check-render-drift.sh --verbose  also list matched-clean and skipped
#
# Placeholders: a template's @@KEY@@ is substituted from MD_VAR_<KEY> in the
# environment, falling back to the defaults declared below. Most carry
# host-specific values (and some are secrets), so they are usually unresolved
# here. That degrades check 2 only -- it is reported as skipped, never as
# clean -- while check 1 still runs, because a block NAME never contains a
# placeholder. Pass MD_VAR_<KEY> in the environment to compare lines too.
#
# Host-specific by nature, so deliberately NOT part of tools/lint-all.sh --
# same reasoning as check-asset-drift.sh: that sweep must stay runnable on any
# checkout, including CI, where none of these destinations exist.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || { echo "check-render-drift: cannot cd to $HERE" >&2; exit 2; }

quiet=0 verbose=0
case "${1:-}" in
    --quiet)   quiet=1 ;;
    --verbose) verbose=1 ;;
esac

say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }

# template-relative-path : rendered destination on this host.
#
# Only templates whose destination is a FIXED path are listed. The rest render
# into install-time variables ($dir per Roundcube plugin, $WWW, $WEB_CONFD) that
# cannot be resolved from a checkout; they are named in UNRESOLVABLE below so
# they are visibly out of scope rather than quietly unchecked.
#
# Extend this list when a module starts render()ing somewhere new. An unlisted
# template is an unchecked one, which is the exact failure this tool ends.
MANIFEST=(
    "rspamd/actions.conf.tmpl:/etc/rspamd/local.d/actions.conf"
    "rspamd/settings.conf.tmpl:/etc/rspamd/local.d/settings.conf"
    "rspamd/antivirus.conf.tmpl:/etc/rspamd/local.d/antivirus.conf"
    "rspamd/force_actions.conf.tmpl:/etc/rspamd/local.d/force_actions.conf"
    "rspamd/worker-controller.inc.tmpl:/etc/rspamd/local.d/worker-controller.inc"
    "rspamd/multimap.conf.tmpl:/etc/rspamd/local.d/multimap.conf"
    "auth/opendmarc.conf.tmpl:/etc/opendmarc.conf"
    "postfix/main.cf.tmpl:/etc/postfix/main.cf"
    "postfix/master.cf.tmpl:/etc/postfix/master.cf"
    "dovecot/dovecot-sql.conf.ext.tmpl:/etc/dovecot/dovecot-sql.conf.ext"
    "dovecot/dovecot-dict-last-login.conf.ext.tmpl:/etc/dovecot/dovecot-dict-last-login.conf.ext"
    "firewalld/load-countries.sh.tmpl:/usr/local/sbin/load-countries.sh"
    "web/mta-sts.txt.tmpl:/var/www/mta-sts/.well-known/mta-sts.txt"
)

# Rendered into an install-time variable path -- named so the gap is visible.
UNRESOLVABLE=(
    "web/apache-web.conf.tmpl (\$WEB_CONFD)"
    "web/landing.php.tmpl (\$WWW)"
    "web/postfixadmin-config.local.php.tmpl (\$dir)"
    "web/roundcube-*.tmpl (\$dir, one per plugin)"
)

# Placeholder defaults, used when MD_VAR_<KEY> is not in the environment.
# Only values that are stable for a standard install belong here; anything
# host-specific should be passed in rather than guessed.
declare -A VAR_DEFAULT=(
    [ILEXA_LIST_DIR]="/var/lib/quarantine-admin"
)

# Substitute @@KEY@@ the way lib/common.sh's render() does. Prints the rendered
# template on stdout; returns 1 (printing nothing) if any placeholder is
# unresolvable, so the caller reports rather than compares a half-rendered file.
placeholders() { grep -oE '@@[A-Z0-9_]+@@' "$1" | sort -u | sed 's/@@//g'; }

# Keys this host cannot fill, as a leading-space-separated list. Computed in
# the caller's shell rather than inside render_template: that one runs in a
# command substitution, and a variable it set there would never survive the
# subshell -- which is how this reported "unbound variable" on first run.
unresolved_keys() { # tmpl
    local key var
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        var="MD_VAR_${key}"
        [ -n "${!var+x}" ] && continue
        [ -n "${VAR_DEFAULT[$key]+x}" ] && continue
        printf ' %s' "$key"
    done < <(placeholders "$1")
}

# Substitute @@KEY@@ the way lib/common.sh's render() does. Keys with no value
# are left as-is; the caller only uses this output when unresolved_keys came
# back empty, so a half-substituted file is never compared.
render_template() { # tmpl
    local tmpl="$1" key var val
    local -a sedargs=()
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        var="MD_VAR_${key}"
        if [ -n "${!var+x}" ]; then
            val="${!var}"
        elif [ -n "${VAR_DEFAULT[$key]+x}" ]; then
            val="${VAR_DEFAULT[$key]}"
        else
            continue
        fi
        val=${val//\\/\\\\}; val=${val//&/\\&}; val=${val//\//\\/}
        sedargs+=(-e "s/@@${key}@@/${val}/g")
    done < <(placeholders "$tmpl")

    if [ ${#sedargs[@]} -eq 0 ]; then cat -- "$tmpl"; else sed "${sedargs[@]}" -- "$tmpl"; fi
}

# Functional lines only: drop comments and blanks, collapse indentation. What
# survives is what rspamd/Postfix actually act on.
functional() { sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'; }

# Top-level block names, e.g. `feed_dshield {` -> feed_dshield. Column-0 only,
# so nested/indented blocks are not mistaken for rules.
blocknames() { grep -oE '^[a-z_][a-z0-9_]*[[:space:]]*\{' | sed 's/[[:space:]]*{//' | sort -u; }

drift=0 clean=0 missing=0 unrenderable=0

for entry in "${MANIFEST[@]}"; do
    tmpl="templates/${entry%%:*}"
    dest="${entry#*:}"

    if [ ! -r "$tmpl" ]; then
        printf '  MANIFEST STALE: %s no longer exists in this repo\n' "$tmpl"
        drift=1
        continue
    fi

    if [ ! -f "$dest" ]; then
        # Not rendered here: an optional feature that was never enabled.
        missing=$((missing + 1))
        [ "$verbose" = 1 ] && printf '  not rendered here: %s -> %s\n' "$tmpl" "$dest"
        continue
    fi

    UNRESOLVED="$(unresolved_keys "$tmpl")"
    rendered="$(render_template "$tmpl")"

    # Block names come from the RAW template: placeholders appear in values,
    # never in a block name, so this check stays valid even when the file
    # cannot be fully rendered. That matters -- it is the check that catches
    # the destroyed-on-render shape, and skipping a file for an unrelated
    # missing password would blind exactly the case this tool exists for.
    only_live="" only_tmpl=""
    case "$dest" in
        /etc/rspamd/*.conf|/etc/rspamd/*.inc)
            only_live="$(comm -13 <(blocknames < "$tmpl") <(blocknames < "$dest") | tr '\n' ' ')"
            only_tmpl="$(comm -23 <(blocknames < "$tmpl") <(blocknames < "$dest") | tr '\n' ' ')"
            ;;
    esac

    # The functional line count needs a full render; without one it would count
    # every placeholder line as a difference. Degrade to "not compared" rather
    # than reporting a number that is mostly artefact.
    reordered=0
    if [ -z "${UNRESOLVED// }" ]; then
        diffcount="$(diff <(printf '%s\n' "$rendered" | functional) <(functional < "$dest") \
                     | grep -c '^[<>]')"
        # Same lines in a different order. UCL block order carries no meaning
        # (rspamd keys rules by name), so for a .conf/.inc target this is not
        # drift -- and reporting it as such would keep the check permanently
        # red over pure formatting, which is how a check stops being read. For
        # a SCRIPT, order is everything, so it stays drift there.
        if [ "$diffcount" != 0 ]; then
            sortedcount="$(diff <(printf '%s\n' "$rendered" | functional | sort) \
                                <(functional < "$dest" | sort) \
                           | grep -c '^[<>]')"
            if [ "$sortedcount" = 0 ]; then
                case "$dest" in
                    *.conf|*.inc) reordered="$diffcount"; diffcount=0 ;;
                esac
            fi
        fi
    else
        diffcount=""
        unrenderable=$((unrenderable + 1))
    fi

    if [ "$diffcount" = 0 ] && [ -z "${only_live// }" ] && [ -z "${only_tmpl// }" ]; then
        clean=$((clean + 1))
        if [ "$verbose" = 1 ]; then
            if [ "$reordered" != 0 ]; then
                printf '  ok: %s (%s line(s) in a different order -- same content)\n' "$dest" "$reordered"
            else
                printf '  ok: %s\n' "$dest"
            fi
        fi
        continue
    fi
    if [ -z "$diffcount" ] && [ -z "${only_live// }" ] && [ -z "${only_tmpl// }" ]; then
        [ "$verbose" = 1 ] && printf '  partial: %s -- blocks match; lines not compared (unresolved:%s)\n' \
                                     "$dest" "$UNRESOLVED"
        continue
    fi

    drift=1
    printf '  RENDER DRIFT: %s\n' "$dest"
    if [ -n "${only_live// }" ]; then
        printf '     LOST ON NEXT RENDER: block(s) present only in the live file: %s\n' "${only_live% }"
        printf '                          move them to a drop-in dir, or add them to %s\n' "$tmpl"
    fi
    if [ -n "${only_tmpl// }" ]; then
        printf '     never reached this host: block(s) only in the template: %s\n' "${only_tmpl% }"
    fi
    if [ -n "$diffcount" ] && [ "$diffcount" != 0 ]; then
        if [ "$dest" -nt "$tmpl" ]; then
            printf '     %s functional line(s) differ -- LIVE is newer (hand-edited here? port it back to %s)\n' \
                   "$diffcount" "$tmpl"
        else
            printf '     %s functional line(s) differ -- REPO is newer (a render would overwrite this host)\n' \
                   "$diffcount"
        fi
    elif [ -z "$diffcount" ]; then
        printf '     line-level comparison skipped (unresolved placeholder(s):%s)\n' "$UNRESOLVED"
    fi
done

if [ "$verbose" = 1 ]; then
    printf '  out of scope (destination is an install-time variable):\n'
    for u in "${UNRESOLVABLE[@]}"; do printf '    %s\n' "$u"; done
fi

summary="$clean fully match, $missing not rendered here, $unrenderable line-check skipped, ${#UNRESOLVABLE[@]} out of scope"
if [ "$drift" = 0 ]; then
    say "check-render-drift: $summary -- clean"
    exit 0
fi

echo "check-render-drift: drift found (see above); $summary" >&2
exit 1
