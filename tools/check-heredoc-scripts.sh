#!/usr/bin/env bash
# check-heredoc-scripts.sh -- lint the scripts this installer WRITES, not just
# the scripts it IS.
#
# Why this gate exists. lint-all reports "72 scripts checked -- 0 shellcheck
# warnings", and that was true and misleading at the same time: a module that
# writes a script with `write_file /usr/bin/foo.sh 755 <<'EOF' ... EOF` has that
# inner script treated as a STRING by both bash -n and shellcheck. Found on
# 2026-09-30 while reworking mail-backup.sh -- a privileged nightly root script
# that had never been shellcheck'd in its life. It had a real (if harmless)
# finding: a `# shellcheck source=/dev/null` directive that did nothing, because
# on a compound line the directive binds to the assignment rather than to the
# `.` that follows it.
#
# What it does: finds every `write_file <path> <mode> [owner] <<DELIM` whose
# target looks like a script or whose body starts with a shebang, extracts the
# body up to its own delimiter, and runs bash -n plus shellcheck over it.
#
# QUOTED vs UNQUOTED delimiters matter here:
#   <<'EOF'  the body is literal -- what the module writes is what you read, so
#            it can be checked exactly as it will land on disk.
#   <<EOF    the body is expanded by the shell first, so what lands on disk is
#            not this text. Those are reported and skipped rather than checked
#            against substitutions we cannot know statically -- counting them is
#            the point, so a new one cannot appear unnoticed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 2

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
checked=0; templated=0; syntax_fail=0; sc_fail=0

have_sc=0
command -v shellcheck >/dev/null 2>&1 && have_sc=1

# One record per heredoc opener: file:line:target:delim:quoted
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"

  # Target is the first argument after write_file.
  target="$(awk '{for(i=1;i<=NF;i++) if($i=="write_file"){print $(i+1); exit}}' <<<"$text")"

  # Delimiter: last field, minus the << / <<- and any quotes.
  raw="$(grep -oE '<<-?[A-Za-z_'"'"'"]+$' <<<"$text" | sed -E 's/^<<-?//')"
  [ -n "$raw" ] || continue
  case "$raw" in
    \'*\'|\"*\") quoted=1; delim="$(sed -E "s/^['\"]//; s/['\"]$//" <<<"$raw")" ;;
    *)           quoted=0; delim="$raw" ;;
  esac

  body="$tmp/$(basename "$target").$line"
  awk -v s="$line" -v d="$delim" 'NR>s { if ($0 == d || $0 == "\t"d) exit; print }' "$file" >"$body"
  [ -s "$body" ] || continue

  # Only script bodies: a shebang, or a target that names one.
  head -1 "$body" | grep -q '^#!' || case "$target" in *.sh|*.py|*.pl) ;; *) continue ;; esac

  if [ "$quoted" -eq 0 ]; then
    templated=$((templated + 1))
    echo "check-heredoc-scripts: $file:$line writes $target from an UNQUOTED heredoc (<<$delim) -- expanded at install time, not statically checkable"
    continue
  fi

  checked=$((checked + 1))
  if ! out="$(bash -n "$body" 2>&1)"; then
    echo "check-heredoc-scripts: SYNTAX ERROR in $target (from $file:$line)"
    sed 's/^/    /' <<<"$out" | sed "s#$body#$target#g"
    syntax_fail=$((syntax_fail + 1)); continue
  fi
  if [ "$have_sc" -eq 1 ]; then
    # -S warning, not style: this is a gate on real problems in generated code,
    # held at the same bar lint-all holds for the modules themselves.
    if ! out="$(shellcheck -S warning -f gcc "$body" 2>&1)"; then
      echo "check-heredoc-scripts: shellcheck findings in $target (from $file:$line)"
      sed "s#$body#$target#g" <<<"$out" | sed 's/^/    /'
      sc_fail=$((sc_fail + 1))
    fi
  fi
done < <(grep -rnE 'write_file [^ ]+ [0-9]+.*<<' modules/ lib/ 2>/dev/null)

[ "$have_sc" -eq 1 ] || echo "check-heredoc-scripts: shellcheck not installed -- bash -n only"

if [ "$syntax_fail" -gt 0 ] || [ "$sc_fail" -gt 0 ]; then
  echo "check-heredoc-scripts: $checked generated script(s) checked -- $syntax_fail syntax, $sc_fail shellcheck" >&2
  exit 1
fi
echo "check-heredoc-scripts: $checked generated script(s) checked, $templated templated (skipped) -- clean"
