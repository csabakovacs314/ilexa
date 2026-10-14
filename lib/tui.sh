#!/usr/bin/env bash
# lib/tui.sh — whiptail wrappers for the interactive wizard.
# Every wrapper echoes the chosen value on stdout so callers can capture it:
#     FOO=$(tui_input "Prompt" "default")
# In non-interactive contexts these are not used (deploy.sh --answers path
# sources the answer file directly and skips collection).

# Both defaults below are generic on purpose: this file is sourced before
# deploy.sh has run os_detect, so the real OS isn't known yet at source
# time. main() overrides both (MD_TUI_BACKTITLE directly, MD_OS_LABEL via
# tui_welcome's caller) right after its own early os_detect call, so in
# practice these generic strings are only ever seen if that call was
# somehow skipped.
: "${MD_TUI_BACKTITLE:=mail-deploy - mail-server deployer   (Esc = quit)}"

# A calm, professional palette. whiptail's stock theme is the red/blue newt
# default -- reported from a live run as "ridiculous". NEWT_COLORS restyles
# every widget: slate-blue chrome, white on blue title bars, a black working
# area, and a single accent colour on the active button/selection so the eye
# knows where focus is. Exported once here so every whiptail call inherits it.
# Colour names are newt's 16-colour set (no truecolor); this stays readable on
# a plain 16-colour TTY as well as a modern terminal.
# The FOCUSED element is a DARK block (white on black); everything unfocused is
# a grey button. This is the second attempt and it was settled by the operator
# looking at a real terminal, not by theory: a light-grey block reads as
# "disabled" by long convention, so when focus WAS the grey one the wrong
# button appeared chosen -- moving right looked like the arrows going left, and
# Enter on what looked like Exit pressed Continue instead.
#
# Brightness could not resolve it: newt backgrounds are the eight base colours,
# where "white" and "lightgray" are the SAME value, so the focused block could
# not be made lighter than the grey it already was. Going dark is the only
# direction with contrast left, and black was in the requested palette.
#
# Measured before and after: the arrow keys and the Exit path were always
# correct (RIGHT moves right; the real md_abort exits cleanly) -- the defect was
# only ever which button LOOKED selected.
#
# compactbutton is deliberately ABSENT. whiptail draws yes/no buttons as
# COMPACT buttons, and that key has no active/inactive variant -- setting it
# painted the focused and unfocused button identically, which is exactly the
# "selector is still invisible" that was reported against the first attempt.
# Verified by decoding the terminal's own SGR state at each button: with the
# key set both were lightgray-on-blue; without it the focused one is
# black-on-lightgray, i.e. the grey selector block, against white-on-blue.
# Set NEWT_COLORS in the environment to override this entirely, e.g.
#   NEWT_COLORS='actbutton=black,red' bash deploy.sh
# so a palette can be tried on the real terminal without editing this file.
: "${NEWT_COLORS:=
root=,black
shadow=,black
window=,blue
border=white,blue
title=white,blue
textbox=white,blue
label=white,blue
emptyscale=,blue
fullscale=,lightgray
helpline=white,blue
roottext=lightgray,black
button=black,lightgray
compactbutton=lightgray,blue
actbutton=black,lightgray
entry=black,lightgray
disentry=gray,blue
checkbox=white,blue
actcheckbox=black,lightgray
listbox=white,blue
actlistbox=black,lightgray
sellistbox=black,lightgray
actsellistbox=black,lightgray
}"
export NEWT_COLORS

: "${MD_OS_LABEL:=this host}"

# ---- wizard step state --------------------------------------------------------
# Set by tui_wizard() (bottom of this file) while one of its numbered steps is
# on screen, and unset again before it returns. Nothing else sets them, so every
# dialog drawn OUTSIDE a step -- the welcome and host-check screens, and
# 75-tls-dns's DNS dialog in the middle of an install -- keeps exactly the
# title, buttons and return codes it always had.
#   MD_TUI_STEP        "Step 3 of 21" -- put in front of every dialog title
#   MD_TUI_STEP_LABEL  the step's name, used as the title of dialogs with none
#   MD_TUI_CANCEL      the cancel button: "Exit" on step 1, "Back" after it
#   MD_TUI_BACK_TO     what Back returns to, for the key hint
# Cleared here so a value inherited from the environment can never turn the
# Exit button of a non-wizard screen (host check, 75-tls-dns) into a status
# that the caller ignores.
unset MD_TUI_STEP MD_TUI_STEP_LABEL MD_TUI_CANCEL MD_TUI_BACK_TO
#
# Every value-returning wrapper below puts `--` after the box type: whiptail
# parses its positionals with popt, so a prefilled answer that starts with "-"
# ("-foo") is read as an unknown option and whiptail exits 1 -- the Back code --
# before drawing anything. The step would bounce straight back, every time.
_tui_title() { # own_title -> the title to draw ("" = none)
  local t="${1:-}"
  if [ -n "${MD_TUI_STEP:-}" ]; then
    t="${t:-${MD_TUI_STEP_LABEL:-}}"
    printf '%s%s' "$MD_TUI_STEP" "${t:+: $t}"
  else
    printf '%s' "$t"
  fi
}
_tui_cancel() { printf '%s' "${MD_TUI_CANCEL:-Exit}"; }
# The key hints below all end "Esc = quit."; on a step with a Back button they
# also say where Back goes. Esc itself never changes meaning.
_tui_nav() { # hint
  local s="$1"
  if [ "${MD_TUI_CANCEL:-}" = Back ]; then
    s="${s%Esc = quit.}Esc = quit, Back = ${MD_TUI_BACK_TO:-previous step}."
  fi
  printf '%s' "$s"
}
_tui_width() { # -> dialog width: terminal less a margin, 50..78
  local cols w
  cols=$(tput cols 2>/dev/null || echo 80)
  w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
  printf '%s' "$w"
}

# stdout is deliberately NOT required to be a terminal here. Every
# value-returning wrapper below is invoked as FOO=$(tui_input ...), and
# command substitution makes stdout a pipe by definition -- so a `[ -t 1 ]`
# test can NEVER be true inside them. It silently made _tui_ok false for
# every prompt, so the whole wizard fell through to its "non-interactive"
# branch and returned each default without ever drawing a dialog. That is
# why the FQDN prompt appeared to have no entry field and why the shipped
# mail.example.com placeholder kept being accepted; it was never
# Debian-specific and had been broken on every OS from the start (no
# end-to-end interactive run had ever happened until 2026-08-15).
#
# What actually has to be a terminal: stdin, plus the fd the UI is drawn
# on. whiptail draws its UI on stdout and returns the chosen value on
# stderr, which is why callers use the 3>&1 1>&2 2>&3 swap -- after that
# swap the UI lands on the caller's original stderr. So accept either
# stdout or stderr being a tty, which covers both the substituted calls
# (stderr is the terminal) and the direct ones like tui_msg/tui_yesno
# (stdout is).
_tui_ok() { command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && { [ -t 1 ] || [ -t 2 ]; }; }

# Welcome / purpose screen. Plain-terminal (works with or without whiptail) so
# it can bind a REAL Ctrl+X (0x18) — whiptail cannot map Ctrl+X itself.
# ENTER (or any other key) proceeds; Ctrl+X exits cleanly with no changes.
tui_welcome() { # purpose_text
  [ -t 0 ] && [ -t 1 ] || return 0        # non-interactive: skip
  if _tui_ok; then
    # The SAME widget family as every screen that follows. This used to be a
    # raw `cat` banner with ASCII ==== rules and an invisible Ctrl+X
    # convention, so the first thing an operator saw looked nothing like the
    # rest of the wizard -- reported from a live run as not looking correct.
    # A yesno states the two real choices as labelled buttons instead.
    # The welcome screen needs the key help too -- it calls whiptail directly
    # rather than through tui_yesno, so it did not inherit the nav line and was
    # reported as giving no hint how to move from Begin to Exit.
    local cols w inner lines maxh h scroll=() text
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    inner=$((w - 6))
    text="$(printf '%s\n' "$1" | fold -s -w "$inner")

$MD_TUI_NAV_YESNO"
    lines=$(printf '%s\n' "$text" | wc -l)
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    h=$((lines + 7))
    if [ "$h" -gt "$maxh" ]; then
      h=$maxh; scroll=(--scrolltext)
      text="(more below - scroll with the DOWN arrow)

$text"
    fi
    [ "$h" -lt 12 ] && h=12
    whiptail --backtitle "$MD_TUI_BACKTITLE" \
      --title "mail-deploy - ${MD_OS_LABEL} mail-server deployer" \
      "${scroll[@]}" --yes-button "Begin" --no-button "Exit" \
      --yesno "$text" "$h" "$w" && return 0
    # No / Esc: the deliberate way out, and nothing has been changed yet.
    clear 2>/dev/null || true
    printf 'Exited - no changes were made.\n'
    exit 0
  fi
  # No whiptail (should not happen: ensure_tui installs it) -- plain fallback.
  cat <<BANNER

  mail-deploy - interactive mail-server deployer (${MD_OS_LABEL})

$1

  [ Press ENTER to begin   -   Ctrl+X to exit ]

BANNER
  local key
  IFS= read -rsn1 key || return 0
  if [ "$key" = $'\x18' ]; then
    clear 2>/dev/null || true
    printf 'Exited - no changes were made.\n'
    exit 0
  fi
  while IFS= read -rs -t 0.05 -n 10000 _tui_leftover 2>/dev/null; do :; done
  return 0
}

tui_msg() { # title text
  if _tui_ok; then
    # A two-button dialog, NOT a msgbox: a lone OK gives newt nothing to
    # contrast against, and two buttons also give every informational screen an
    # explicit way out.
    #
    # The text is re-wrapped to the box's INNER width before display. Screens
    # were authored hard-wrapped at ~78 columns while the box is narrower, so
    # whiptail re-wrapped them itself and every long line came out with a short
    # orphan under it -- reported as text overflowing the border with improper
    # line breaks. fold -s only touches lines that are too long, so deliberate
    # short lines and blank lines survive.
    local cols w inner lines maxh h scroll=() text nav
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    inner=$((w - 6))
    text=$(printf '%s\n' "$2" | fold -s -w "$inner")
    lines=$(printf '%s\n' "$text" | wc -l)
    # Geometry is deliberately unchanged by the wizard's longer "Back" hint:
    # the height comes from the message alone, as it always has, so no screen
    # that fitted a 24-line terminal starts scrolling (which would move focus
    # off the buttons) just because its hint grew.
    nav=$(_tui_nav "$MD_TUI_NAV_YESNO")
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    h=$((lines + 7))
    if [ "$h" -gt "$maxh" ]; then
      # Scrolling puts focus on the TEXT, not on a button, so no button looks
      # active until the reader tabs to one. Say so, rather than leaving them
      # wondering which control is live.
      h=$maxh; scroll=(--scrolltext)
      text="(text scrolls: UP/DOWN reads it, TAB moves to the buttons)

$text"
    fi
    [ "$h" -lt 12 ] && h=12
    local rc=0
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$(_tui_title "$1")" "${scroll[@]}" \
      --yes-button "Continue" --no-button "$(_tui_cancel)" \
      --yesno "$text

$nav" "$h" "$w" || rc=$?
    [ "$rc" = 0 ] && return 0
    # Inside a wizard step the engine decides what the button means (Exit on
    # step 1, Back after it) and Esc still quits -- so hand it the status.
    [ -n "${MD_TUI_STEP:-}" ] && return "$rc"
    md_abort            # Exit button or Esc: nothing has been changed yet
  else printf '%s: %s\n' "$1" "$2" >&2; fi
}

# Navigation hints, appended by the wrappers below. whiptail shows no key help
# of its own: reported from a live run as "no hint how to switch to the OK or
# Exit buttons". The backtitle also used to advertise Ctrl+X, which whiptail
# has NO binding for -- it only ever worked on the old raw-text banner, so it
# was a promise the wizard could not keep. These are the keys that work.
# ONE WAY OUT, ON EVERY SCREEN, AND IT IS IMMEDIATE. Esc quits; the Exit
# button quits; nothing is modified before the review screen, so leaving is
# always clean and needs no confirmation.
#
# The wizard's numbered steps (tui_wizard, below) relabel the cancel button
# "Back" from step 2 on -- whiptail returns 1 for that button and 255 for Esc,
# so the two stay distinct: Back goes to the previous step, Esc still quits on
# the spot. Neither needs a dialog of its own, so the problem below cannot
# come back through this door.
#
# There WAS a confirmation dialog here. It was worse than useless: whiptail
# draws its interface on STDOUT, and the value-returning wrappers run inside
# $( ), where stdout is a pipe -- so from a menu or an input prompt the
# confirmation was drawn into the pipe and never appeared on screen. The user
# was answering a dialog they could not see, which is exactly how "I pressed
# Esc and had to click Stay to exit" happens. Removing it removes the whole
# bug class.
#
# The value-returning wrappers still cannot call exit themselves (a subshell
# exit would leave the installer running with an empty value), so they return
# whiptail's own status -- 1 for the Exit/Back button, 255 for Esc -- and the
# caller decides: `|| md_abort` outside the wizard, the step engine inside it.

MD_TUI_NAV_LIST='Up/Down moves.  SPACE ticks an entry.  TAB to the buttons.  Enter presses the GREY button.  Esc = quit.'
MD_TUI_NAV_MENU='Up/Down chooses an item.  TAB jumps to the buttons, then Left/Right moves between them.  Enter presses the button with the GREY highlight.  Esc = quit.'
MD_TUI_NAV_ENTRY='Type the value, then TAB to the buttons (Left/Right moves between them).  Enter presses the button with the GREY highlight.  Esc = quit.'
MD_TUI_NAV_YESNO='Arrows/TAB move.  Enter presses the GREY button.  Esc = quit.'
# tui_choice's hint is deliberately short: its prompts carry real explanations
# and the box has to fit them on a 24-line terminal.
MD_TUI_NAV_CHOICE='Up/Down picks.  Enter confirms.  TAB, then Left/Right, reaches the buttons.  Esc = quit.'
MD_TUI_NAV_CHOICE_SHORT='Up/Down picks, Enter confirms.  Esc = quit.'

tui_menu() { # title prompt default_tag  tag1 desc1 [tag2 desc2 ...]
  # A real selection list where a choice exists -- reported from a live wizard
  # run: language and timezone were a bare yes/no and a free-text field, which
  # neither showed what could be chosen nor how. --default-item preselects the
  # sensible answer so plain Enter keeps it, matching every other prompt here.
  local title="$1" prompt="$2" def="$3"; shift 3
  if _tui_ok; then
    local n=$(( $# / 2 )); local h=$(( n + 12 )); [ "$h" -gt 22 ] && h=22
    local val
    {
      if val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$title" \
        --default-item "$def" --menu "$prompt

$MD_TUI_NAV_MENU" "$h" 74 "$n" "$@" 3>&1 1>&2 2>&3); then
        printf '%s' "$val"; return 0
      fi
      return 1        # Cancel/Exit/Esc -> caller runs md_abort
    }
  else printf '%s' "$def"; fi
}

# Prompt + key hint, folded to the 74-wide entry box, and the box height that
# shows all of it. A fixed 12 rows clipped the hint once it also named Back.
_tui_entry_text() { # prompt -> sets _TUI_TEXT and _TUI_H
  _TUI_TEXT=$(printf '%s\n\n%s\n' "$1" "$(_tui_nav "$MD_TUI_NAV_ENTRY")" | fold -s -w 68)
  _TUI_H=$(( $(printf '%s\n' "$_TUI_TEXT" | wc -l) + 7 ))
  [ "$_TUI_H" -lt 12 ] && _TUI_H=12
  return 0
}

tui_input() { # prompt default   (exit status 1 = Exit/Back button, 255 = Esc)
  local prompt="$1" def="${2:-}"
  if _tui_ok; then
    local val rc=0 t=() title
    title=$(_tui_title ""); [ -n "$title" ] && t=(--title "$title")
    _tui_entry_text "$prompt"
    val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" "${t[@]}" --cancel-button "$(_tui_cancel)" \
      --inputbox -- "$_TUI_TEXT" "$_TUI_H" 74 "$def" 3>&1 1>&2 2>&3) || rc=$?
    [ "$rc" = 0 ] || return "$rc"   # caller: md_abort, or the wizard's Back/quit
    printf '%s' "$val"; return 0
  else printf '%s' "$def"; fi
}

# No prefill parameter, on purpose: whiptail takes an initial value only as a
# command-line argument, and a password or API key on a command line is
# readable by every local user through /proc/<pid>/cmdline for as long as the
# dialog is open. A wizard step revisited with Back offers "keep the one
# entered before" as a separate choice instead (see _wz_secret in deploy.sh).
tui_password() { # prompt   (exit status 1 = Exit/Back button, 255 = Esc)
  local prompt="$1"
  if _tui_ok; then
    local t=() title
    title=$(_tui_title ""); [ -n "$title" ] && t=(--title "$title")
    _tui_entry_text "$prompt"
    whiptail --backtitle "$MD_TUI_BACKTITLE" "${t[@]}" --cancel-button "$(_tui_cancel)" \
      --passwordbox -- "$_TUI_TEXT" "$_TUI_H" 74 3>&1 1>&2 2>&3
  else printf ''; fi
}

# tui_choice "title" "prompt" default_tag  tag1 desc1 [tag2 desc2 ...]
# A question with a few fixed answers, drawn as a menu: echoes the chosen tag.
# The wizard asks its yes/no questions with this rather than tui_yesno because
# a yes/no box has exactly two buttons and both are answers -- there is no
# third button for Back. Unlike tui_menu, the height follows the prompt, so a
# question that carries a real explanation is not clipped; on a terminal too
# short for it the text scrolls, and the hint says how to reach the list.
tui_choice() {
  local title="$1" prompt="$2" def="$3"; shift 3
  if _tui_ok; then
    local w inner text lines n lh h maxh val rc=0 scroll=() t=() hint
    w=$(_tui_width); inner=$((w - 6))
    n=$(( $# / 2 )); lh=$n; [ "$lh" -gt 10 ] && lh=10
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    # Scrolling moves focus onto the text, where Enter does nothing -- so when
    # the full hint is what makes the box too tall, try the one-line hint
    # first, and only scroll if even that does not fit.
    for hint in "$MD_TUI_NAV_CHOICE" "$MD_TUI_NAV_CHOICE_SHORT"; do
      text=$(printf '%s\n\n%s\n' "$prompt" "$(_tui_nav "$hint")" | fold -s -w "$inner")
      lines=$(printf '%s\n' "$text" | wc -l)
      h=$((lines + lh + 7))
      [ "$h" -le "$maxh" ] && break
    done
    if [ "$h" -gt "$maxh" ]; then
      text=$(printf '%s\n\n%s\n' "$prompt" "$(_tui_nav "$MD_TUI_NAV_CHOICE")" | fold -s -w "$inner")
      h=$maxh; scroll=(--scrolltext)
      text="(text scrolls: UP/DOWN reads it, TAB moves to the answers)

$text"
    fi
    [ "$h" -lt $((lh + 9)) ] && h=$((lh + 9))
    title=$(_tui_title "$title"); [ -n "$title" ] && t=(--title "$title")
    val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" "${t[@]}" "${scroll[@]}" \
      --cancel-button "$(_tui_cancel)" --default-item "$def" \
      --menu -- "$text" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3) || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    printf '%s' "$val"; return 0
  else printf '%s' "$def"; fi
}

tui_yesno() { # prompt  -> returns 0 for yes, 1 for no
  local prompt="$1"
  if _tui_ok; then
    local cols w inner lines h maxh
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    inner=$((w - 6))
    prompt=$(printf '%s\n' "$prompt" | fold -s -w "$inner")
    lines=$(printf '%s\n' "$prompt" | wc -l); h=$((lines + 9))
    maxh=$(tput lines 2>/dev/null || echo 24)
    [ "$h" -gt $((maxh - 2)) ] && h=$((maxh - 2))
    [ "$h" -lt 12 ] && h=12
    local rc
    while true; do
      whiptail --backtitle "$MD_TUI_BACKTITLE" --yesno "$prompt

$MD_TUI_NAV_YESNO" "$h" "$w"
      rc=$?
      [ "$rc" = 0 ] && return 0          # Yes
      [ "$rc" = 1 ] && return 1          # a deliberate No -- NOT a quit
      md_abort                           # 255 = Esc
    done
  else return 0; fi
}

# tui_radiolist "title" tag1 "desc1" on|off  tag2 "desc2" on|off ...
# Single-select (exactly one tag marked 'on'); echoes that one tag. For a flat
# pick-one, chaining tui_yesno calls (TLS_MODE's precedent) reads badly and
# invites logic errors as the option count grows -- whiptail's own --radiolist
# is the right primitive here.
tui_radiolist() {
  local title="$1"; shift
  if _tui_ok; then
    local args=() val w cols
    while [ $# -ge 3 ]; do args+=("$1" "$2" "$3"); shift 3; done
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    # The old form piped whiptail into `tr`, so $? was TR's status: cancelling
    # or pressing Esc looked like SUCCESS with an empty answer, and the caller
    # carried on with an empty value. Capture first, check status, strip after.
    # Geometry from the ITEM COUNT, not fixed at 20x12: the fixed box left no
    # room under the list, so the navigation hint was cut off entirely --
    # reported as the password-expiry and hardening screens having no TAB hint.
    local n=$(( ${#args[@]} / 3 )) lh h
    lh=$n; [ "$lh" -gt 10 ] && lh=10
    h=$((lh + 12))
    local maxh; maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    [ "$h" -gt "$maxh" ] && { h=$maxh; lh=$((h - 12)); [ "$lh" -lt 3 ] && lh=3; }
    local rc=0
    val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$(_tui_title "$title")" \
      --cancel-button "$(_tui_cancel)" \
      --radiolist -- "Select with SPACE, confirm with ENTER

$(_tui_nav "$MD_TUI_NAV_LIST")" "$h" "$w" "$lh" "${args[@]}" 3>&1 1>&2 2>&3) || rc=$?
    [ "$rc" = 0 ] || return "$rc"   # 1 = Exit/Back button, 255 = Esc
    printf '%s' "${val//\"/}"; return 0
  else
    while [ $# -ge 3 ]; do [ "$3" = on ] && { printf '%s' "$1"; break; }; shift 3; done
  fi
}

# tui_checklist "title" tag1 "desc1" on|off  tag2 "desc2" on|off ...
# echoes space-separated selected tags.
tui_checklist() {
  local title="$1"; shift
  if _tui_ok; then
    local args=() val w cols
    while [ $# -ge 3 ]; do args+=("$1" "$2" "$3"); shift 3; done
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 6)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    # Geometry from the ITEM COUNT, not fixed at 20x12: the fixed box left no
    # room under the list, so the navigation hint was cut off entirely --
    # reported as the password-expiry and hardening screens having no TAB hint.
    local n=$(( ${#args[@]} / 3 )) lh h
    lh=$n; [ "$lh" -gt 10 ] && lh=10
    h=$((lh + 12))
    local maxh; maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    [ "$h" -gt "$maxh" ] && { h=$maxh; lh=$((h - 12)); [ "$lh" -lt 3 ] && lh=3; }
    local rc=0
    val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$(_tui_title "$title")" \
      --cancel-button "$(_tui_cancel)" \
      --checklist -- "Select with SPACE, confirm with ENTER

$(_tui_nav "$MD_TUI_NAV_LIST")" "$h" "$w" "$lh" "${args[@]}" 3>&1 1>&2 2>&3) || rc=$?
    [ "$rc" = 0 ] || return "$rc"   # 1 = Exit/Back button, 255 = Esc
    printf '%s' "${val//\"/}"; return 0
  else
    while [ $# -ge 3 ]; do [ "$3" = on ] && printf '%s ' "$1"; shift 3; done
  fi
}

# tui_review "text" -> echoes apply | change | abort (always exit status 0)
# The last screen before anything is changed. Three real answers, so a menu
# rather than a yes/no box: "Change..." is what spares an operator re-running
# all ~20 questions over one typo. The Abort button and Esc both mean abort.
# The old fixed 24x78 box also clipped its last lines (hardening, backups,
# dry-run) without any sign there was more; the height now follows the text,
# and a terminal too short for it scrolls the text instead.
# Without a usable terminal it prints the text and answers "apply", which is
# what the old yes/no version returned there too.
tui_review() {
  if _tui_ok; then
    local cols w inner text lines h maxh val rc=0 scroll=()
    cols=$(tput cols 2>/dev/null || echo 80)
    w=$((cols - 2)); [ "$w" -gt 78 ] && w=78; [ "$w" -lt 50 ] && w=50
    inner=$((w - 6))
    text=$(printf '%s\n\nNothing has been changed yet.  %s\n' "$1" "$MD_TUI_NAV_CHOICE" | fold -s -w "$inner")
    lines=$(printf '%s\n' "$text" | wc -l)
    h=$((lines + 3 + 7))
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    if [ "$h" -gt "$maxh" ]; then
      h=$maxh; scroll=(--scrolltext)
      text="(text scrolls: UP/DOWN reads it, TAB moves to the answers)

$text"
    fi
    [ "$h" -lt 12 ] && h=12
    val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" --title "Review — apply these changes?" \
      "${scroll[@]}" --cancel-button "Abort" --default-item apply \
      --menu -- "$text" "$h" "$w" 3 \
      apply  "Apply - install with these answers" \
      change "Change an answer..." \
      abort  "Abort - exit, nothing has been changed" 3>&1 1>&2 2>&3) || rc=$?
    [ "$rc" = 0 ] || val=abort
    case "$val" in apply|change) printf '%s' "$val" ;; *) printf 'abort' ;; esac
    return 0
  else
    printf '%s\n' "$1" >&2; printf 'apply'; return 0
  fi
}

# ---- the wizard engine -------------------------------------------------------
# tui_wizard REVIEW_FN [VALUE_FN [AFTER_CHANGE_FN]]
#   Steps come from the caller's array MD_WZ_STEPS=("function|Label" ...), in
#   order. A step function asks its question(s) and returns 0 (answered: go
#   on), 1 (its Back/Exit button) or anything else (quit). Prefilling a
#   revisited step with the earlier answer is the step's own job.
#   REVIEW_FN prints the review text; it is called afresh on every review.
#   VALUE_FN, given a step function's name, prints that answer briefly for the
#   Change... menu.
#   AFTER_CHANGE_FN runs after a step changed from the review was answered, so
#   the caller can carry the change on to answers derived from it.
# Walks the steps -- Back goes one step back, Exit on step 1 or Esc anywhere
# quits -- then loops on the review: Apply returns 0, Change... re-runs one
# chosen step and comes back to the review, Abort/Esc returns 255 (the caller
# runs md_abort). Every step dialog is titled "Step n of N: ..." where N is the
# number of entries in MD_WZ_STEPS, so a step the caller leaves out on this
# host is not counted.
#
# Without a usable terminal every wrapper returns its default immediately, so
# the walk runs straight through once; a non-zero step there quits rather than
# going Back, which could otherwise bounce between two steps forever.
tui_wizard() {
  local review_fn="$1" value_fn="${2:-}" after_fn="${3:-}" n=${#MD_WZ_STEPS[@]} i=0 rc act pick=1 p
  while [ "$i" -lt "$n" ]; do
    rc=0; _tui_wz_run "$i" "$n" walk || rc=$?
    if [ "$rc" = 0 ]; then
      i=$((i + 1))
    elif [ "$rc" = 1 ] && [ "$i" -gt 0 ] && _tui_ok; then
      i=$((i - 1))
    else
      _tui_wz_clear; return 255
    fi
  done
  while true; do
    _tui_wz_clear
    act=$(tui_review "$("$review_fn")")
    case "$act" in
      apply) return 0 ;;
      change)
        rc=0; p=$(_tui_wz_pick "$value_fn" "$pick") || rc=$?
        _tui_wz_clear
        [ "$rc" = 1 ] && continue                # Back: straight to the review
        [ "$rc" = 0 ] || return 255
        pick=$p
        rc=0; _tui_wz_run $((pick - 1)) "$n" change || rc=$?
        # 0 = changed, 1 = Back out of the step with its answer untouched;
        # either way the review comes next. Esc inside the step quits.
        [ "$rc" = 0 ] || [ "$rc" = 1 ] || { _tui_wz_clear; return 255; }
        if [ "$rc" = 0 ] && [ -n "$after_fn" ]; then "$after_fn"; fi
        ;;
      *) return 255 ;;
    esac
  done
}

_tui_wz_run() { # index total walk|change -> the step function's status
  local spec="${MD_WZ_STEPS[$1]}"
  MD_TUI_STEP="Step $(($1 + 1)) of $2"
  MD_TUI_STEP_LABEL="${spec#*|}"
  if [ "$3" = change ]; then
    MD_TUI_CANCEL=Back; MD_TUI_BACK_TO="the review"
  elif [ "$1" -eq 0 ]; then
    MD_TUI_CANCEL=Exit; MD_TUI_BACK_TO=""
  else
    MD_TUI_CANCEL=Back; MD_TUI_BACK_TO="previous step"
  fi
  "${spec%%|*}"
}

_tui_wz_clear() { unset MD_TUI_STEP MD_TUI_STEP_LABEL MD_TUI_CANCEL MD_TUI_BACK_TO; }

_tui_wz_pick() { # value_fn default_number -> echoes the 1-based step number
  local value_fn="$1" def="${2:-1}" i spec label v d args=()
  for i in "${!MD_WZ_STEPS[@]}"; do
    spec="${MD_WZ_STEPS[$i]}"; label="${spec#*|}"; v=""
    [ -n "$value_fn" ] && v=$("$value_fn" "${spec%%|*}" 2>/dev/null)
    d=$(printf '%-22s %s' "$label" "$v")
    [ "${#d}" -gt 56 ] && d="${d:0:53}..."
    args+=("$((i + 1))" "$d")
  done
  MD_TUI_CANCEL=Back; MD_TUI_BACK_TO="the review"
  tui_choice "Change an answer" \
    "Pick the answer to change. Its step opens with the current answer filled in; finishing it, or pressing Back there, returns to the review." \
    "$def" "${args[@]}"
}
