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
# compactbutton is deliberately ABSENT. whiptail draws yes/no buttons as
# COMPACT buttons, and that key has no active/inactive variant -- setting it
# painted the focused and unfocused button identically, which is exactly the
# "selector is still invisible" that was reported against the first attempt.
# Verified by decoding the terminal's own SGR state at each button: with the
# key set both were lightgray-on-blue; without it the focused one is
# black-on-lightgray, i.e. the grey selector block, against white-on-blue.
export NEWT_COLORS='
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
button=white,blue
actbutton=black,lightgray
entry=black,lightgray
disentry=gray,blue
checkbox=white,blue
actcheckbox=black,lightgray
listbox=white,blue
actlistbox=black,lightgray
sellistbox=black,lightgray
actsellistbox=black,lightgray
'

: "${MD_OS_LABEL:=this host}"
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
    local lines maxh h scroll=() text="$1

$MD_TUI_NAV_YESNO"
    lines=$(printf '%s\n' "$text" | wc -l)
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    h=$((lines + 8))
    if [ "$h" -gt "$maxh" ]; then
      h=$maxh; scroll=(--scrolltext)
      text="(more below - scroll with the DOWN arrow)

$text"
    fi
    [ "$h" -lt 12 ] && h=12
    whiptail --backtitle "$MD_TUI_BACKTITLE" \
      --title "mail-deploy - ${MD_OS_LABEL} mail-server deployer" \
      "${scroll[@]}" --yes-button "Begin" --no-button "Exit" \
      --yesno "$text" "$h" 74 && return 0
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
    # A two-button dialog, NOT a msgbox. A msgbox has a single OK, so newt has
    # nothing to contrast it against and it renders unhighlighted on the blue
    # field -- reported as "the OK button is not highlighted" on the host-check
    # screen. Two buttons also give every informational screen an explicit way
    # out, which is what "must be able to exit anytime" needs.
    local lines maxh h scroll=() text="$2"
    lines=$(printf '%s\n' "$text" | wc -l)
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    h=$((lines + 8))
    if [ "$h" -gt "$maxh" ]; then
      h=$maxh; scroll=(--scrolltext)
      text="(more below - scroll with the DOWN arrow)

$text"
    fi
    [ "$h" -lt 12 ] && h=12
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$1" "${scroll[@]}" \
      --yes-button "Continue" --no-button "Exit" \
      --yesno "$text

$MD_TUI_NAV_YESNO" "$h" 74 && return 0
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
# 1 and rely on the caller's `|| md_abort` -- present on all 16 call sites.

MD_TUI_NAV_MENU='Up/Down = choose   TAB = jump to the buttons   Enter = confirm   Esc = quit'
MD_TUI_NAV_ENTRY='TAB = jump to the buttons   Enter = confirm   Esc = quit'
MD_TUI_NAV_YESNO='Left/Right or TAB = switch buttons   Enter = confirm   Esc = quit'

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

tui_input() { # prompt default   (exit status 1/255 = user chose Exit/Esc)
  local prompt="$1" def="${2:-}"
  if _tui_ok; then
    local val
    {
      if val=$(whiptail --backtitle "$MD_TUI_BACKTITLE" --cancel-button "Exit" \
        --inputbox "$prompt

$MD_TUI_NAV_ENTRY" 12 74 "$def" 3>&1 1>&2 2>&3); then
        printf '%s' "$val"; return 0
      fi
      return 1        # Cancel/Exit/Esc -> caller runs md_abort
    }
  else printf '%s' "$def"; fi
}

tui_password() { # prompt   (exit status 1/255 = user chose Exit/Esc)
  local prompt="$1"
  if _tui_ok; then
    whiptail --backtitle "$MD_TUI_BACKTITLE" --cancel-button "Exit" \
      --passwordbox "$prompt" 10 74 3>&1 1>&2 2>&3
  else printf ''; fi
}

tui_yesno() { # prompt  -> returns 0 for yes, 1 for no
  local prompt="$1"
  if _tui_ok; then
    local lines h maxh
    lines=$(printf '%s\n' "$prompt" | wc -l); h=$((lines + 9))
    maxh=$(tput lines 2>/dev/null || echo 24)
    [ "$h" -gt $((maxh - 2)) ] && h=$((maxh - 2))
    [ "$h" -lt 12 ] && h=12
    local rc
    while true; do
      whiptail --backtitle "$MD_TUI_BACKTITLE" --yesno "$prompt

$MD_TUI_NAV_YESNO" "$h" 74
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
    local args=() ; while [ $# -ge 3 ]; do args+=("$1" "$2" "$3"); shift 3; done
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$title" --cancel-button "Exit" \
      --radiolist "Select with SPACE, confirm with ENTER" 20 74 12 \
      "${args[@]}" 3>&1 1>&2 2>&3 | tr -d '"'
  else
    # non-interactive: echo the one tag marked 'on'
    while [ $# -ge 3 ]; do [ "$3" = on ] && { printf '%s' "$1"; break; }; shift 3; done
  fi
}

# tui_checklist "title" tag1 "desc1" on|off  tag2 "desc2" on|off ...
# echoes space-separated selected tags.
tui_checklist() {
  local title="$1"; shift
  if _tui_ok; then
    local args=() ; while [ $# -ge 3 ]; do args+=("$1" "$2" "$3"); shift 3; done
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$title" --cancel-button "Exit" \
      --checklist "Select with SPACE, confirm with ENTER" 20 74 12 \
      "${args[@]}" 3>&1 1>&2 2>&3 | tr -d '"'
  else
    # non-interactive: echo the tags defaulted 'on'
    while [ $# -ge 3 ]; do [ "$3" = on ] && printf '%s ' "$1"; shift 3; done
  fi
}

# tui_review "text" -> show final confirmation; returns 0 to proceed
tui_review() {
  if _tui_ok; then
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "Review — apply these changes?" \
      --yesno "$1" 24 78 --yes-button "Apply" --no-button "Abort"
  else
    printf '%s\n' "$1" >&2; return 0
  fi
}
