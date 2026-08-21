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
: "${MD_TUI_BACKTITLE:=mail-deploy — mail-server deployer  (Exit: Ctrl+X)}"
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
  clear 2>/dev/null || true
  cat <<BANNER

  ============================================================
   mail-deploy — interactive mail-server deployer ($MD_OS_LABEL)
  ============================================================

$1

  ------------------------------------------------------------
   [ Press ENTER to begin   •   Ctrl+X to exit ]
  ------------------------------------------------------------

BANNER
  local key
  IFS= read -rsn1 key || return 0
  if [ "$key" = $'\x18' ]; then            # Ctrl+X
    clear 2>/dev/null || true
    printf 'Exited — no changes were made.\n'
    exit 0
  fi
  # Drain anything still buffered from that keypress: `read -n1` consumes
  # only one character, so the newline Enter produces (and any typeahead)
  # would otherwise be delivered to the first whiptail dialog and
  # auto-dismiss it. Cheap insurance, kept independently of the _tui_ok
  # fix above -- that was the real cause of the reported "no entry field",
  # this is a distinct, narrower hazard.
  while IFS= read -rs -t 0.05 -n 10000 _tui_leftover 2>/dev/null; do :; done
  return 0
}

tui_msg() { # title text
  if _tui_ok; then
    # Size the box to the text instead of clipping at a fixed 12 rows: long
    # explainers (the deployment-type screen is ~34 lines) otherwise render
    # scroll-mangled. Cap at the real terminal height; past the cap, add
    # --scrolltext — a msgbox has only the OK button, so focus stays on OK
    # either way and arrow keys scroll the text.
    local lines maxh h scroll=()
    lines=$(printf '%s\n' "$2" | wc -l)
    maxh=$(tput lines 2>/dev/null || echo 24); maxh=$((maxh - 2))
    h=$((lines + 6))
    if [ "$h" -gt "$maxh" ]; then h=$maxh; scroll=(--scrolltext); fi
    [ "$h" -lt 12 ] && h=12
    whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$1" "${scroll[@]}" --msgbox "$2" "$h" 74
  else printf '%s: %s\n' "$1" "$2" >&2; fi
}

tui_input() { # prompt default   (exit status 1/255 = user chose Exit/Esc)
  local prompt="$1" def="${2:-}"
  if _tui_ok; then
    whiptail --backtitle "$MD_TUI_BACKTITLE" --cancel-button "Exit" \
      --inputbox "$prompt" 10 74 "$def" 3>&1 1>&2 2>&3
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
  if _tui_ok; then whiptail --backtitle "$MD_TUI_BACKTITLE" --yesno "$prompt" 10 74
  else return 0; fi
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
